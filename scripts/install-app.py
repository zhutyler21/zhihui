#!/usr/bin/env python3
"""Install the owned standalone app atomically and preserve existing meeting data."""
from pathlib import Path, PurePosixPath
import argparse
import ctypes
import datetime
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import uuid
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'dist/知会.app'
TARGET = Path.home() / 'Applications/知会.app'
MODEL_TARGET = Path.home() / 'Library/Application Support/知会/models'
IDENTIFIER = 'io.local.zhihui.meetings'
VERSION = '0.5.0'
BUILD = '16'


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def reject_symlink_components(path):
    path = Path(path).absolute()
    for component in [*reversed(path.parents), path]:
        if component.is_symlink():
            raise RuntimeError('不会使用符号链接路径：' + str(component))
    return path


def ensure_directory(path):
    path = reject_symlink_components(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    reject_symlink_components(path)
    if not path.is_dir():
        raise RuntimeError('目标不是目录：' + str(path))
    return path


def metadata(app):
    app = reject_symlink_components(app)
    path = app / 'Contents/Info.plist'
    reject_symlink_components(path)
    if not path.is_file():
        raise RuntimeError('找不到有效应用信息：' + str(app))
    return plistlib.loads(path.read_bytes())


def owned_target(app):
    app = reject_symlink_components(app)
    if not os.path.lexists(app):
        return
    info = metadata(app)
    if info.get('CFBundleIdentifier') != IDENTIFIER:
        raise RuntimeError('同名应用不属于本项目，本脚本不会覆盖它。')
    if info.get('ZhihuiRuntimeLayout') == 'bundled-v1':
        if 'ZhihuiProjectRoot' in info:
            raise RuntimeError('已有应用的独立版信息不一致。')
    elif info.get('ZhihuiProjectRoot') != str(ROOT):
        raise RuntimeError('已有应用不属于本项目的开发版或独立版。')
    if any(key in info for key in ('ZhihuiDataDirectory', 'ZhihuiPort')):
        raise RuntimeError('已有同名应用属于隔离验收配置，不会覆盖它。')


def configuration():
    value = json.loads((ROOT / 'Resources/StandaloneRuntime.json').read_text())
    if value.get('schema_version') != 1:
        raise RuntimeError('独立运行环境清单版本不受支持。')
    return value


def load_auditor():
    path = ROOT / 'scripts/audit-standalone.py'
    spec = importlib.util.spec_from_file_location('zhihui_install_audit', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_audit(app):
    app = reject_symlink_components(app)
    info = metadata(app)
    if (info.get('CFBundleIdentifier') != IDENTIFIER or info.get('ZhihuiRuntimeLayout') != 'bundled-v1'
            or info.get('CFBundleShortVersionString') != VERSION or str(info.get('CFBundleVersion')) != BUILD
            or 'ZhihuiProjectRoot' in info or any(key in info for key in ('ZhihuiDataDirectory', 'ZhihuiPort'))):
        raise RuntimeError('待安装应用不是本项目正式的独立版 ' + VERSION + '（' + BUILD + '）。')
    config = configuration()
    resources = app / 'Contents/Resources'
    for path in (resources / 'RuntimeManifest.json', resources / 'LICENSE', resources / 'Runtime/Resources/ModelCatalog.json'):
        reject_symlink_components(path)
    manifest = json.loads((resources / 'RuntimeManifest.json').read_text())
    for key in ('python_version', 'requirements_sha256', 'model_catalog_sha256', 'ffmpeg_version', 'ffmpeg_source_sha256'):
        if manifest.get(key) != config.get(key):
            raise RuntimeError('应用运行环境清单与本项目不一致：' + key)
    if manifest.get('layout') != 'bundled-v1':
        raise RuntimeError('应用运行环境布局不一致。')
    if sha256(resources / 'Runtime/Resources/ModelCatalog.json') != config['model_catalog_sha256']:
        raise RuntimeError('应用模型清单与固定版本不一致。')
    if sha256(resources / 'LICENSE') != sha256(ROOT / 'LICENSE'):
        raise RuntimeError('应用许可证与项目不一致。')
    result = load_auditor().audit(app, verify_signature=True)
    if not result.get('pass') or result.get('signature_checked') is not True:
        raise RuntimeError('独立应用校验失败：\n' + '\n'.join(result.get('failures', [])))
    return result


def bundle_snapshot(app):
    result = {}
    app = Path(app)
    for path in sorted(app.rglob('*')):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            result[relative] = {'symlink': os.readlink(path)}
        elif path.is_file():
            result[relative] = {'size': path.stat().st_size, 'sha256': sha256(path)}
        elif path.is_dir():
            result[relative] = {'directory': True}
    return result


def catalog_files():
    path = ROOT / 'Resources/ModelCatalog.json'
    if sha256(path) != configuration()['model_catalog_sha256']:
        raise RuntimeError('项目模型清单校验失败。')
    catalog = json.loads(path.read_text())
    if catalog.get('schemaVersion') != 1 or {model.get('id') for model in catalog['models']} != {'asr', 'embedding', 'llm'}:
        raise RuntimeError('项目模型清单格式不一致。')
    items = [item for model in catalog['models'] for item in model['files']]
    if len(items) != 23 or len({item['path'] for item in items}) != 23:
        raise RuntimeError('本版迁移只接受固定清单中的 23 个模型文件。')
    for item in items:
        validate_catalog_item(item)
    return items


def validate_catalog_item(item):
    relative = PurePosixPath(item['path'])
    if (relative.is_absolute() or not relative.parts or any(part in ('..', '.') for part in relative.parts)
            or str(relative) != item['path'] or item['size'] <= 0
            or not re.fullmatch(r'[0-9a-f]{64}', item['sha256'])):
        raise RuntimeError('模型清单含无效文件路径或校验信息。')


def verified_file(path, item):
    try:
        reject_symlink_components(path)
        attributes = path.stat()
        return stat.S_ISREG(attributes.st_mode) and attributes.st_size == item['size'] and sha256(path) == item['sha256']
    except (OSError, RuntimeError):
        return False


def migrate_models(source, destination, items):
    """Copy only verified catalog bytes; publish each file without replacing any existing path."""
    source, destination = Path(source), Path(destination)
    reject_symlink_components(source)
    reject_symlink_components(destination)
    report = {key: [] for key in ('copied', 'already_present', 'conflicts', 'source_missing', 'source_invalid')}
    for item in items:
        validate_catalog_item(item)
        incoming, outgoing = source / item['path'], destination / item['path']
        if os.path.lexists(outgoing):
            report['already_present' if verified_file(outgoing, item) else 'conflicts'].append(item['path'])
            continue
        if not os.path.lexists(incoming):
            report['source_missing'].append(item['path'])
            continue
        if not verified_file(incoming, item):
            report['source_invalid'].append(item['path'])
            continue
        ensure_directory(outgoing.parent)
        handle, temporary_name = tempfile.mkstemp(prefix='.zhihui-model-', suffix='.partial', dir=outgoing.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(handle, 'wb') as writer, incoming.open('rb') as reader:
                shutil.copyfileobj(reader, writer, length=1024 * 1024)
                writer.flush()
                os.fsync(writer.fileno())
            if not verified_file(temporary, item):
                report['source_invalid'].append(item['path'])
                continue
            reject_symlink_components(outgoing.parent)
            try:
                # A link from a fully verified new temporary inode publishes atomically;
                # it never links to the source and fails if any destination already exists.
                os.link(temporary, outgoing, follow_symlinks=False)
            except FileExistsError:
                report['already_present' if verified_file(outgoing, item) else 'conflicts'].append(item['path'])
                continue
            if not verified_file(outgoing, item):
                raise RuntimeError('迁移文件发布后校验失败：' + item['path'])
            report['copied'].append(item['path'])
        finally:
            temporary.unlink(missing_ok=True)
    return report


def exclusive_rename(source, destination):
    """Darwin atomic rename with RENAME_EXCL and no symlink path traversal."""
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # Values verified against Apple's SDK sys/stdio.h.
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004 | 0x00000010):
        value = ctypes.get_errno()
        raise OSError(value, os.strerror(value), str(destination))


def commit_stage(stage, target, backup_directory, rename=exclusive_rename):
    stage, target, backup_directory = Path(stage), Path(target), Path(backup_directory)
    reject_symlink_components(stage)
    owned_target(target)
    backup = None
    if os.path.lexists(target):
        ensure_directory(backup_directory)
        if target.parent.stat().st_dev != backup_directory.stat().st_dev:
            raise RuntimeError('应用与备份目录不在同一文件系统，无法安全原子更新。')
        stamp = datetime.datetime.now(ZoneInfo('Asia/Singapore')).strftime('%Y%m%d-%H%M%S')
        backup = backup_directory / ('知会-' + stamp + '-' + uuid.uuid4().hex + '.app')
        rename(target, backup)
    try:
        rename(stage, target)
    except BaseException:
        if backup and not os.path.lexists(target):
            rename(backup, target)
        raise
    return backup


def stage_and_install(source, target, backup_directory, verifier=source_audit):
    source, target = Path(source), Path(target)
    reject_symlink_components(source)
    owned_target(target)
    verifier(source)
    original = bundle_snapshot(source)
    ensure_directory(target.parent)
    stage = target.parent / ('.知会-install-' + uuid.uuid4().hex + '.app')
    try:
        shutil.copytree(source, stage, symlinks=True)
        verifier(stage)
        if bundle_snapshot(stage) != original or bundle_snapshot(source) != original:
            raise RuntimeError('待安装应用在复制或验证期间发生变化。')
        assert_not_running(target)
        backup = commit_stage(stage, target, backup_directory)
        return {'installed': str(target), 'backup': str(backup) if backup else None,
                'bundle_files': len(original)}
    finally:
        if os.path.lexists(stage):
            reject_symlink_components(stage)
            shutil.rmtree(stage)


def assert_not_running(target):
    output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
    prefix = str(Path(target).absolute()) + '/'
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[1].startswith(prefix):
            raise RuntimeError('知会仍在运行，请先正常退出应用再安装；不会强制结束进程。')


def self_test():
    """Synthetic own fixtures only; never uses ~/Applications or real application data."""
    fixture = ensure_directory(ROOT / 'work/install-app-self-test' / uuid.uuid4().hex)
    if ROOT / 'work' not in fixture.resolve().parents:
        raise RuntimeError('自测目录不在项目 work 中。')
    source, target = fixture / 'source/知会.app', fixture / 'Applications/知会.app'
    for app, kind in [(source, 'bundled'), (target, 'legacy')]:
        ensure_directory(app / 'Contents')
        info = {'CFBundleIdentifier': IDENTIFIER, 'CFBundleShortVersionString': VERSION, 'CFBundleVersion': BUILD}
        info.update({'ZhihuiRuntimeLayout': 'bundled-v1'} if kind == 'bundled' else {'ZhihuiProjectRoot': str(ROOT)})
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'Contents/payload').write_text(kind)
    data = ensure_directory(fixture / 'User Support/知会')
    (data / 'meetings.sqlite').write_bytes(b'synthetic untouched meeting data')
    old_data_hash = sha256(data / 'meetings.sqlite')
    old_app = bundle_snapshot(target)
    result = stage_and_install(source, target, fixture / 'backups', verifier=lambda _: None)
    assert bundle_snapshot(target) == bundle_snapshot(source)
    assert bundle_snapshot(Path(result['backup'])) == old_app
    owned_target(target)
    foreign = fixture / 'foreign.app'
    ensure_directory(foreign / 'Contents')
    (foreign / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'io.unrelated.app'}))
    try:
        owned_target(foreign)
        raise AssertionError('foreign app accepted')
    except RuntimeError:
        pass
    model_source, model_target = ensure_directory(fixture / 'models'), data / 'models'
    contents = {'a/good.bin': b'verified model', 'b/conflict.bin': b'valid incoming', 'c/bad.bin': b'valid expected', 'd/link.bin': b'verified model', 'e/missing.bin': b'missing'}
    items = [{'path': name, 'size': len(value), 'sha256': hashlib.sha256(value).hexdigest()} for name, value in contents.items()]
    for name, value in contents.items():
        if name == 'e/missing.bin':
            continue
        ensure_directory((model_source / name).parent)
        (model_source / name).write_bytes(b'invalid source' if name == 'c/bad.bin' else value)
    (model_source / 'd/link.bin').unlink()
    (model_source / 'd/link.bin').symlink_to(model_source / 'a/good.bin')
    (model_source / 'extra.bin').write_bytes(b'not in catalog')
    ensure_directory(model_target / 'b')
    (model_target / 'b/conflict.bin').write_bytes(b'keep existing bytes')
    migrated = migrate_models(model_source, model_target, items)
    assert migrated['copied'] == ['a/good.bin'] and migrated['conflicts'] == ['b/conflict.bin']
    assert set(migrated['source_invalid']) == {'c/bad.bin', 'd/link.bin'} and migrated['source_missing'] == ['e/missing.bin']
    assert (model_target / 'b/conflict.bin').read_bytes() == b'keep existing bytes'
    assert not (model_target / 'extra.bin').exists() and not (model_target / 'a/good.bin').is_symlink()
    assert (model_source / 'a/good.bin').stat().st_ino != (model_target / 'a/good.bin').stat().st_ino
    assert sha256(data / 'meetings.sqlite') == old_data_hash
    retry = migrate_models(model_source, model_target, items)
    assert retry['copied'] == [] and retry['already_present'] == ['a/good.bin']
    rollback_stage = fixture / 'rollback-stage.app'
    shutil.copytree(source, rollback_stage)
    before_rollback = bundle_snapshot(target)
    def fail_new_rename(incoming, outgoing):
        if Path(incoming) == rollback_stage:
            raise OSError('synthetic stage rename failure')
        exclusive_rename(incoming, outgoing)
    try:
        commit_stage(rollback_stage, target, fixture / 'backups', rename=fail_new_rename)
        raise AssertionError('synthetic failure was ignored')
    except OSError:
        pass
    assert bundle_snapshot(target) == before_rollback and rollback_stage.exists()
    link_root = fixture / 'linked-models'
    link_root.symlink_to(model_source, target_is_directory=True)
    try:
        migrate_models(link_root, model_target, items)
        raise AssertionError('model source symlink accepted')
    except RuntimeError:
        pass
    receipt = {'pass': True, 'fixture': str(fixture), 'checks': ['legacy and bundled owned target accepted', 'foreign target rejected', 'atomic staging and old-app backup', 'rollback restores previous bytes', 'size and SHA verified catalog copies only', 'source preserved and independent destination inode', 'existing conflict untouched', 'missing invalid and symlink files skipped', 'uncatalogued source omitted', 'meeting database untouched', 'idempotent migration'],
               'migration': migrated, 'script_sha256': sha256(__file__)}
    (fixture / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(receipt, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-only', action='store_true', help='只验证正式安装源与目标身份，不修改应用或资料')
    parser.add_argument('--self-test', action='store_true', help='只运行项目 work 下的合成夹具')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    reject_symlink_components(ROOT / 'dist')
    source = source_audit(SOURCE)
    owned_target(TARGET)
    items = catalog_files()
    if args.check_only:
        print(json.dumps({'pass': True, 'source': str(SOURCE), 'target': str(TARGET), 'version': source['version'],
                          'build': source['build'], 'model_directory': str(MODEL_TARGET), 'catalog_files': len(items), 'installed': False}, ensure_ascii=False))
        return
    assert_not_running(TARGET)
    result = stage_and_install(SOURCE, TARGET, ROOT / 'work/installed-app-backups')
    try:
        result['models'] = migrate_models(ROOT / 'models', MODEL_TARGET, items)
    except (OSError, RuntimeError) as error:
        result['models'] = {'migration_error': str(error), 'note': '应用已安装；已有资料保留，模型仍可在首次启动时下载。'}
    report_root = ensure_directory(ROOT / 'work/install-app-receipts')
    receipt = report_root / (datetime.datetime.now(ZoneInfo('Asia/Singapore')).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex + '.json')
    result['version'] = source['version']
    result['build'] = source['build']
    result['receipt'] = str(receipt)
    result['script_sha256'] = sha256(__file__)
    receipt.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
