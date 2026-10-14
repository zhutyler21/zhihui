#!/usr/bin/env python3
"""Package the audited standalone app as a verified read-only drag-to-install DMG."""
from pathlib import Path
import argparse
import datetime
import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import time
import uuid
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
NAME = 'Zhihui-v0.5.0-macOS-arm64.dmg'
OUTPUT = ROOT / 'dist' / NAME
OWNER = 'io.local.zhihui.meetings'


def installer_module():
    spec = importlib.util.spec_from_file_location('zhihui_dmg_install_helpers', ROOT / 'scripts/install-app.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HELPERS = installer_module()


def attachment_device(info, image, mountpoint):
    """Bind cleanup to this exact image and dedicated mountpoint, never arbitrary disks."""
    matches = []
    for value in info.get('images', []):
        filename = value.get('image-path')
        if filename and Path(filename).resolve() == Path(image).resolve():
            matches.append(value)
    if len(matches) != 1:
        return None
    entities = matches[0].get('system-entities', [])
    mounted = [value for value in entities if value.get('mount-point')]
    if mounted:
        if len(mounted) != 1 or Path(mounted[0]['mount-point']).resolve() != Path(mountpoint).resolve():
            return None
        match = re.fullmatch(r'(/dev/disk\d+)(?:s\d+)*', mounted[0].get('dev-entry', ''))
        return match.group(1) if match else None
    # An attach failure may have allocated this image's device without mounting it.
    devices = [value['dev-entry'] for value in entities
               if re.fullmatch(r'/dev/disk\d+', value.get('dev-entry', ''))]
    return devices[0] if len(devices) == 1 else None


def recover_owned_attachment(image, mountpoint):
    for attempt in range(10):
        data = subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist'], timeout=15)
        device = attachment_device(plistlib.loads(data), image, mountpoint)
        if device:
            return device
        if attempt < 9:
            time.sleep(0.2)
    return None


def owned_image(path, receipt):
    HELPERS.reject_symlink_components(path)
    HELPERS.reject_symlink_components(receipt)
    if not os.path.lexists(path):
        if receipt.exists():
            value = json.loads(receipt.read_text())
            if value.get('owner') != OWNER or value.get('filename') != path.name:
                raise RuntimeError('已有发行凭据不属于本项目。')
        return None
    if not path.is_file() or not receipt.is_file():
        raise RuntimeError('同名 DMG 没有本项目的校验凭据，不会覆盖它。')
    value = json.loads(receipt.read_text())
    if (value.get('owner') != OWNER or value.get('artifact_type') != 'standalone-dmg'
            or value.get('filename') != path.name or value.get('sha256') != HELPERS.sha256(path)):
        raise RuntimeError('同名 DMG 与本项目发行凭据不一致，不会覆盖它。')
    return value


def owned_work_path(path):
    path = HELPERS.reject_symlink_components(path)
    if ROOT / 'work' not in path.resolve().parents:
        raise RuntimeError('DMG 临时文件和挂载目录必须位于本项目 work 中。')
    return path


def create_and_verify_image(stage, image, mountpoint, verify_contents):
    """Create UDZO, attach this image read-only, verify, and detach only its own device."""
    stage, image, mountpoint = map(owned_work_path, (stage, image, mountpoint))
    if os.path.lexists(image) or os.path.lexists(mountpoint):
        raise RuntimeError('DMG 临时文件或挂载目录已存在。')
    if not stage.is_dir():
        raise RuntimeError('DMG 源目录不存在。')
    subprocess.run(['/usr/bin/hdiutil', 'create', '-srcfolder', str(stage), '-volname', '知会',
                    '-fs', 'HFS+', '-format', 'UDZO', str(image)], check=True, timeout=1200)
    subprocess.run(['/usr/bin/hdiutil', 'verify', str(image)], check=True, timeout=600)
    mountpoint.mkdir(mode=0o700)
    device = None
    detached = False
    result = {}
    try:
        attached = subprocess.run(['/usr/bin/hdiutil', 'attach', str(image), '-readonly', '-nobrowse',
                                   '-noautoopen', '-verify', '-mountpoint', str(mountpoint), '-plist'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=180)
        entities = plistlib.loads(attached.stdout).get('system-entities', [])
        mounted = [entity for entity in entities if entity.get('mount-point')]
        if len(mounted) != 1:
            raise RuntimeError('DMG 挂载结果不是单一安装卷。')
        entry = mounted[0]
        match = re.fullmatch(r'(/dev/disk\d+)(?:s\d+)*', entry.get('dev-entry', ''))
        if not match:
            raise RuntimeError('DMG 未返回可核对的设备标识。')
        device = match.group(1)
        if Path(entry['mount-point']).resolve() != mountpoint.resolve():
            raise RuntimeError('DMG 没有挂载到本次专属目录。')
        if not os.statvfs(mountpoint).f_flag & os.ST_RDONLY:
            raise RuntimeError('DMG 验证卷不是只读挂载。')
        disk = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', str(mountpoint)], timeout=60))
        if disk.get('DeviceNode') != entry['dev-entry'] or Path(disk.get('MountPoint', '')).resolve() != mountpoint.resolve():
            raise RuntimeError('只读安装卷的设备或挂载点不一致。')
        result = verify_contents(mountpoint)
        result.update({'readonly': True, 'device': device, 'mounted_device': entry['dev-entry'],
                       'volume_name': disk.get('VolumeName'), 'image_sha256': HELPERS.sha256(image)})
    finally:
        if device is None:
            # hdiutil can finish mounting before reporting an error, timing out,
            # or returning an unreadable plist. Read back only this owned image.
            device = recover_owned_attachment(image, mountpoint)
        if device is not None:
            subprocess.run(['/usr/bin/hdiutil', 'detach', device], check=True, timeout=120)
            detached = True
        # hdiutil removes the dedicated mountpoint on detach on some macOS versions.
        if detached and mountpoint.exists():
            mountpoint.rmdir()
    if not detached:
        raise RuntimeError('DMG 未取得并清理可核对的本次挂载。')
    result['owned_mount_detached'] = True
    return result


def publish_owned_image(image, destination, receipt_path, receipt):
    image, destination, receipt_path = map(Path, (image, destination, receipt_path))
    previous = owned_image(destination, receipt_path)
    HELPERS.ensure_directory(destination.parent)
    HELPERS.ensure_directory(receipt_path.parent)
    backup = None
    if previous:
        backup = image.parent / ('previous-' + uuid.uuid4().hex + '.dmg')
        HELPERS.exclusive_rename(destination, backup)
        if HELPERS.sha256(backup) != previous['sha256']:
            if not os.path.lexists(destination):
                HELPERS.exclusive_rename(backup, destination)
            raise RuntimeError('旧 DMG 在更新期间发生变化，已保留它。')
    try:
        HELPERS.exclusive_rename(image, destination)
    except BaseException:
        if backup and not os.path.lexists(destination):
            HELPERS.exclusive_rename(backup, destination)
        raise
    receipt.update({'owner': OWNER, 'artifact_type': 'standalone-dmg', 'filename': destination.name,
                    'sha256': HELPERS.sha256(destination), 'bytes': destination.stat().st_size,
                    'previous_dmg_backup': str(backup) if backup else None})
    temporary_receipt = receipt_path.parent / ('.' + receipt_path.name + '-' + uuid.uuid4().hex)
    temporary_receipt.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    os.replace(temporary_receipt, receipt_path)


def stage_installation(source, stage, audit):
    snapshot = HELPERS.bundle_snapshot(source)
    stage.mkdir(mode=0o700)
    shutil.copytree(source, stage / '知会.app', symlinks=True)
    if HELPERS.bundle_snapshot(stage / '知会.app') != snapshot or HELPERS.bundle_snapshot(source) != snapshot:
        raise RuntimeError('DMG 应用副本与已验证来源不一致。')
    (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
    shutil.copy2(ROOT / 'LICENSE', stage / 'LICENSE')
    model_bytes = sum(item['size'] for item in HELPERS.catalog_files())
    instructions = (
        '知会 · 本地中文会议助手\n\n'
        '安装\n'
        '1. 将“知会.app”拖到旁边的“Applications（应用程序）”。\n'
        '2. 从应用程序中打开知会。\n'
        '3. 按欢迎页提示准备麦克风与系统声音权限，再点击下载所需模型。\n'
        '4. 三个模型与声音权限均准备完成后，即可进入主界面。\n\n'
        '本安装包适用于 Apple Silicon Mac，最低系统版本为 macOS ' + audit['native_minimum_macos'] + '。\n'
        '运行环境已经包含在应用内，无需另行安装 Python 或 ffmpeg，也无需保留源码目录。\n'
        '模型另行下载，合计约 ' + format(model_bytes / 1_000_000_000, '.2f') + ' GB。首次准备需联网，准备完成后本地推理可离线使用。\n'
        '模型存储：~/Library/Application Support/知会/models\n'
        '会议资料存储：~/Library/Application Support/知会\n'
        '请在访达完成应用复制后推出安装卷。\n\n'
        '签名与许可\n'
        '本版本为本机临时签名，尚未经过 Apple 公证；macOS 可能在首次打开时要求你确认。\n'
        '知会项目代码与文档采用 MIT 许可，完整条款见本安装卷中的 LICENSE。\n'
        '第三方运行环境、依赖和模型保留各自许可，不随项目统一变为 MIT。\n'
        '第三方说明与许可证位于知会.app/Contents/Resources/ThirdPartyNotices.txt 和 ThirdPartyLicenses。\n\n'
        '项目与更新：https://github.com/zhutyler21/zhihui\n'
    )
    (stage / '安装说明.txt').write_text(instructions, encoding='utf-8')
    return snapshot


def build():
    source = ROOT / 'dist/知会.app'
    receipt_path = ROOT / 'work/dmg-artifacts' / (NAME + '.json')
    owned_image(OUTPUT, receipt_path)
    audit = HELPERS.source_audit(source)
    job = HELPERS.ensure_directory(ROOT / 'work/dmg-builds' / uuid.uuid4().hex)
    stage, image, mountpoint = job / 'staging', job / NAME, job / 'mount'
    snapshot = stage_installation(source, stage, audit)
    notices = {name: HELPERS.sha256(stage / name) for name in ('安装说明.txt', 'LICENSE')}
    def verify_mounted(mount):
        expected = {'知会.app', 'Applications', '安装说明.txt', 'LICENSE'}
        actual = {path.name for path in mount.iterdir() if not path.name.startswith('.')}
        if actual != expected:
            raise RuntimeError('DMG 安装内容不一致。')
        link = mount / 'Applications'
        if not link.is_symlink() or os.readlink(link) != '/Applications':
            raise RuntimeError('DMG 的应用程序入口不正确。')
        for name, digest in notices.items():
            if HELPERS.sha256(mount / name) != digest:
                raise RuntimeError('DMG 说明或许可证与来源不一致。')
        mounted_app = mount / '知会.app'
        mounted_audit = HELPERS.source_audit(mounted_app)
        if HELPERS.bundle_snapshot(mounted_app) != snapshot or HELPERS.bundle_snapshot(source) != snapshot:
            raise RuntimeError('只读 DMG 内的应用与已验证来源不一致。')
        return {'mounted_app_deep_signature_verified': True, 'mounted_app_hashes_match': True,
                'app_files': len(snapshot), 'version': mounted_audit['version'], 'build': mounted_audit['build']}
    verification = create_and_verify_image(stage, image, mountpoint, verify_mounted)
    receipt = {'pass': True, 'date': datetime.datetime.now(ZoneInfo('Asia/Singapore')).isoformat(),
               'version': HELPERS.VERSION, 'build': HELPERS.BUILD, 'format': 'UDZO',
               'verification': verification, 'source_app': str(source),
               'source_audit': {'native_minimum_macos': audit['native_minimum_macos'], 'signature_checked': audit['signature_checked']},
               'script_sha256': HELPERS.sha256(__file__), 'install_helper_sha256': HELPERS.sha256(ROOT / 'scripts/install-app.py')}
    publish_owned_image(image, OUTPUT, receipt_path, receipt)
    (job / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'dmg': str(OUTPUT), 'sha256': receipt['sha256'], 'bytes': receipt['bytes'],
                      'readonly_verified': True, 'mounted_signature_verified': True, 'owned_mount_detached': True,
                      'receipt': str(receipt_path)}, ensure_ascii=False))


def self_test():
    """Small owned HFS+/UDZO fixture; does not package, install or launch an application."""
    job = HELPERS.ensure_directory(ROOT / 'work/dmg-self-test' / uuid.uuid4().hex)
    stage, image, mountpoint = job / 'staging', job / 'tiny-owned.dmg', job / 'mount'
    stage.mkdir()
    payload = stage / 'fixture.txt'
    payload.write_text('合成只读安装卷夹具；没有用户资料。\n', encoding='utf-8')
    (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
    expected_hash = HELPERS.sha256(payload)
    def verify(mount):
        assert HELPERS.sha256(mount / 'fixture.txt') == expected_hash
        assert (mount / 'Applications').is_symlink() and os.readlink(mount / 'Applications') == '/Applications'
        return {'fixture_bytes_match': True, 'applications_link_match': True}
    result = create_and_verify_image(stage, image, mountpoint, verify)
    # Counterexample: the OS mounts successfully but attach reports failure before
    # the caller can assign its device. Cleanup must recover the exact image binding.
    from unittest.mock import patch
    real_run = subprocess.run
    interrupted_image, interrupted_mount = job / 'interrupted-attach.dmg', job / 'interrupted-mount'
    def reported_failure(command, *arguments, **keywords):
        outcome = real_run(command, *arguments, **keywords)
        if command[:2] == ['/usr/bin/hdiutil', 'attach']:
            raise subprocess.CalledProcessError(7, command, output=outcome.stdout, stderr=outcome.stderr)
        return outcome
    try:
        with patch.object(subprocess, 'run', side_effect=reported_failure):
            create_and_verify_image(stage, interrupted_image, interrupted_mount, verify)
        raise AssertionError('synthetic attach failure was ignored')
    except subprocess.CalledProcessError:
        pass
    inventory = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
    assert attachment_device(inventory, interrupted_image, interrupted_mount) is None
    assert not interrupted_mount.exists()
    unrelated = {'images': [{'image-path': str(interrupted_image), 'system-entities': [
        {'dev-entry': '/dev/disk999s1', 'mount-point': str(job / 'foreign-mount')}]}]}
    assert attachment_device(unrelated, interrupted_image, interrupted_mount) is None
    result['failed_attach_owned_mount_detached'] = True
    result['unrelated_mount_not_selected_for_cleanup'] = True
    foreign = job / 'foreign.dmg'
    foreign.write_bytes(b'foreign existing artifact must remain')
    foreign_hash = HELPERS.sha256(foreign)
    try:
        owned_image(foreign, job / 'foreign.json')
        raise AssertionError('foreign existing image accepted')
    except RuntimeError:
        pass
    assert HELPERS.sha256(foreign) == foreign_hash
    destination, receipt_path = job / 'published.dmg', job / 'published.json'
    receipt = {'pass': True, 'format': 'UDZO', 'verification': result}
    publish_owned_image(image, destination, receipt_path, receipt)
    assert owned_image(destination, receipt_path)['sha256'] == HELPERS.sha256(destination)
    assert not mountpoint.exists()
    receipt.update({'self_test': True, 'fixture': str(job), 'foreign_artifact_preserved': True,
                    'script_sha256': HELPERS.sha256(__file__)})
    (job / 'self-test-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(receipt, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true', help='只创建并验证项目 work 下的小型合成安装卷')
    parser.add_argument('--check-only', action='store_true', help='只验证正式来源及同名 DMG 的归属，不创建安装卷')
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.check_only:
        owned_image(OUTPUT, ROOT / 'work/dmg-artifacts' / (NAME + '.json'))
        audit = HELPERS.source_audit(ROOT / 'dist/知会.app')
        print(json.dumps({'pass': True, 'version': audit['version'], 'build': audit['build'], 'dmg': str(OUTPUT), 'created': False}, ensure_ascii=False))
    else:
        build()


if __name__ == '__main__':
    main()
