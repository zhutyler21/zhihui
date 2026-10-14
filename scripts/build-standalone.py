#!/usr/bin/env python3
"""Build a movable macOS app containing its complete on-device runtime."""
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'Resources/StandaloneRuntime.json').read_text())
WORK = ROOT / 'work/standalone-release-v0.5.0'
APP = ROOT / 'dist/知会.app'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ignore_python(directory, names):
    return [name for name in names if name == '__pycache__' or name.endswith('.pyc')
            or name in ('_virtualenv.py', '_virtualenv.pth')]


def inspect_environment():
    python = ROOT / '.venv/bin/python3'
    data = subprocess.check_output([str(python), '-I', '-B', '-c',
        'import sys,platform,json,importlib.metadata as m; '
        'print(json.dumps({"base":sys.base_prefix,"version":platform.python_version(),'
        '"machine":platform.machine(),"packages":{d.metadata["Name"].lower().replace("_","-"):d.version for d in m.distributions()}}))'])
    environment = json.loads(data)
    if environment['version'] != CONFIG['python_version'] or environment['machine'] != 'arm64':
        raise RuntimeError('Build with the pinned managed arm64 CPython ' + CONFIG['python_version'])
    for line in (ROOT / 'requirements.lock').read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        name, version = line.split('==', 1)
        if environment['packages'].get(name.lower().replace('_', '-')) != version:
            raise RuntimeError('Installed dependency does not match requirements.lock: ' + name)
    for filename, key in [('requirements.lock', 'requirements_sha256'),
                          ('Resources/ModelCatalog.json', 'model_catalog_sha256')]:
        if sha(ROOT / filename) != CONFIG[key]:
            raise RuntimeError('Pinned runtime input changed: ' + filename)
    return environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python-stage', type=Path,
                        help='Reuse a previously copied runtime after verifying imports and pinned packages')
    args = parser.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    if ROOT not in WORK.resolve().parents or ROOT not in APP.resolve().parents:
        raise RuntimeError('Build directories escape the repository.')
    environment = inspect_environment()
    ffmpeg, archive, ffmpeg_metadata = load_script('build-ffmpeg').build(WORK / 'ffmpeg')
    mlx_wheels, mlx_archive, mlx_metadata = load_script('build-mlx').build()
    if APP.exists():
        old = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
        if old.get('CFBundleIdentifier') != 'io.local.zhihui.meetings':
            raise RuntimeError('Refusing to replace an unrelated build artifact.')
        backups = WORK / 'build-backups'
        backups.mkdir(exist_ok=True)
        APP.rename(backups / ('知会-' + uuid.uuid4().hex + '.app'))
    subprocess.run(['bash', str(ROOT / 'scripts/build-app.sh')], cwd=ROOT, check=True)
    runtime = APP / 'Contents/Resources/Runtime'
    runtime.mkdir()
    destination = runtime / 'python'
    if args.python_stage:
        stage = args.python_stage.resolve()
        if ROOT / 'work' not in stage.parents or not (stage / 'bin/python3').is_file():
            raise RuntimeError('Runtime stage must be a complete repository-owned Python copy.')
        shutil.copytree(stage, destination, symlinks=True, ignore=ignore_python)
    else:
        shutil.copytree(Path(environment['base']).resolve(), destination, symlinks=True, ignore=ignore_python)
        shutil.copytree(ROOT / '.venv/lib/python3.12/site-packages',
                        destination / 'lib/python3.12/site-packages', symlinks=True,
                        dirs_exist_ok=True, ignore=ignore_python)
    # Replace the host-targeted PyPI MLX wheels only inside the newly copied runtime.
    # These same-version source-built wheels retain precompiled Metal kernels at macOS 14.
    packages = destination / 'lib/python3.12/site-packages'
    for name in ['mlx', 'mlx-0.32.3.dist-info', 'mlx_metal-0.32.3.dist-info']:
        path = packages / name
        if path.is_symlink():
            raise RuntimeError('Unexpected MLX symlink in new runtime copy.')
        if path.exists():
            shutil.rmtree(path)
    subprocess.run([str(destination / 'bin/python3'), '-I', '-B', '-m', 'pip', 'install',
                    '--no-index', '--no-deps', '--no-compile', '--disable-pip-version-check',
                    '--target', str(packages), *map(str, mlx_wheels)], check=True,
                   env=dict(os.environ, PIP_CONFIG_FILE=os.devnull, PYTHONNOUSERSITE='1'))
    for name in ['mlx-0.32.3.dist-info', 'mlx_metal-0.32.3.dist-info']:
        (packages / name / 'direct_url.json').unlink(missing_ok=True)
    copied = json.loads(subprocess.check_output([str(destination / 'bin/python3'), '-I', '-B', '-c',
        'import sys,platform,json,importlib.metadata as m; '
        'print(json.dumps({"prefix":sys.prefix,"version":platform.python_version(),'
        '"packages":{d.metadata["Name"].lower().replace("_","-"):d.version for d in m.distributions()}}))']))
    if Path(copied['prefix']).resolve() != destination.resolve() or copied['version'] != CONFIG['python_version']:
        raise RuntimeError('Copied Python is not the pinned movable runtime.')
    for line in (ROOT / 'requirements.lock').read_text().splitlines():
        if line and not line.startswith('#'):
            name, version = line.split('==', 1)
            if copied['packages'].get(name.lower().replace('_', '-')) != version:
                raise RuntimeError('Copied package does not match requirements.lock: ' + name)
    for path in destination.rglob('*'):
        if path.is_symlink() and destination not in path.resolve().parents:
            raise RuntimeError('Python copy has an external symlink: ' + str(path.relative_to(destination)))
    for path in destination.rglob('*.pth'):
        if any(value in path.read_text() for value in ('/Users/', '/opt/homebrew/', '/usr/local/')):
            raise RuntimeError('Python copy has an external search path: ' + str(path.relative_to(destination)))
    shutil.copytree(ROOT / 'backend', runtime / 'backend', ignore=ignore_python)
    (runtime / 'scripts').mkdir()
    for name in ['setup-models.py', 'run-backend.py']:
        shutil.copy2(ROOT / 'scripts' / name, runtime / 'scripts' / name)
    (runtime / 'Resources').mkdir()
    shutil.copy2(ROOT / 'Resources/ModelCatalog.json', runtime / 'Resources/ModelCatalog.json')
    (runtime / 'bin').mkdir()
    shutil.copy2(ffmpeg, runtime / 'bin/ffmpeg')
    resources = APP / 'Contents/Resources'
    shutil.copy2(ROOT / 'LICENSE', resources / 'LICENSE')
    shutil.copytree(ROOT / 'docs/licenses', resources / 'ThirdPartyLicenses')
    shutil.copy2(destination / 'lib/python3.12/LICENSE.txt', resources / 'ThirdPartyLicenses/Python-PSF.txt')
    shutil.copy2(archive.parent / ('ffmpeg-' + CONFIG['ffmpeg_version']) / 'COPYING.LGPLv2.1',
                 resources / 'ThirdPartyLicenses/FFmpeg-LGPLv2.1.txt')
    source_directory = resources / 'ThirdPartySources'
    source_directory.mkdir()
    shutil.copy2(archive, source_directory / archive.name)
    shutil.copy2(mlx_archive, source_directory / mlx_archive.name)
    (source_directory / 'MLX-BUILD.json').write_text(json.dumps(mlx_metadata, indent=2) + '\n')
    (source_directory / 'FFmpeg-BUILD.json').write_text(json.dumps(ffmpeg_metadata, indent=2) + '\n')
    manifest = {'layout': 'bundled-v1', 'python_version': CONFIG['python_version'],
                'python_packages': environment['packages'], 'requirements_sha256': CONFIG['requirements_sha256'],
                'model_catalog_sha256': CONFIG['model_catalog_sha256'],
                'ffmpeg_version': CONFIG['ffmpeg_version'], 'ffmpeg_source_sha256': CONFIG['ffmpeg_source_sha256'],
                'mlx_build': mlx_metadata}
    (resources / 'RuntimeManifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (resources / 'ThirdPartyNotices.txt').write_text(
        '知会项目代码与文档采用 MIT License。第三方运行环境、依赖与模型保留各自许可。\n'
        'Python 来自 Python Build Standalone / CPython，许可见 ThirdPartyLicenses/Python-PSF.txt。\n'
        'Python 包保留各自许可与元数据；补充全文位于 ThirdPartyLicenses/python-packages。\n'
        'MLX 0.32.3 使用未修改的官方源码，以 macOS 14 为目标构建，包含预编译 Metal 内核；源码与配置见 ThirdPartySources。\n'
        'MLX 编译依赖 fmt、nanobind、robin-map 的版权声明、许可与固定来源见 ThirdPartyLicenses/mlx-source-build。\n'
        '本软件调用 FFmpeg 音频转换程序（LGPL-2.1-or-later）；未开启 GPL、nonfree 或网络功能。\n'
        'FFmpeg 完整对应源码与构建配置位于 ThirdPartySources，可自行重新构建该可执行文件。\n'
        '模型仅在用户开始准备时下载，存储在用户资料目录，不包含在应用包中。\n')
    info_path = APP / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.pop('ZhihuiProjectRoot', None)
    info['ZhihuiRuntimeLayout'] = 'bundled-v1'
    info['NSHumanReadableCopyright'] = '© 2026 zhutyler21 · MIT。含 Python 与 FFmpeg 等第三方组件，各自许可见应用包内说明。'
    info_path.write_bytes(plistlib.dumps(info))
    auditor = load_script('audit-standalone')
    # uv may rewrite a dylib's install ID to its managed installation path.
    # Restore relative IDs only in the new copy, before signing it.
    for path in APP.rglob('*'):
        if not auditor.macho(path):
            continue
        ids = subprocess.check_output(['/usr/bin/otool', '-D', str(path)]).decode().splitlines()
        if any(line.strip().startswith('/')
               and not line.endswith(':') for line in ids[1:]):
            subprocess.run(['/usr/bin/install_name_tool', '-id', '@rpath/' + path.name, str(path)], check=True)
    preliminary = auditor.audit(APP, verify_signature=False)
    portability_failures = [value for value in preliminary['failures']
                            if value != 'Info.plist OS floor is below bundled native dependency floor']
    if portability_failures:
        raise RuntimeError('\n'.join(portability_failures))
    info['LSMinimumSystemVersion'] = preliminary['native_minimum_macos']
    info_path.write_bytes(plistlib.dumps(info))
    print('Signing embedded runtime components…', flush=True)
    for path in APP.rglob('*'):
        if auditor.macho(path) and path != APP / 'Contents/MacOS/知会':
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(path)],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--entitlements',
                    str(ROOT / 'work/native-build/entitlements.plist'), str(APP)], check=True)
    result = auditor.audit(APP)
    result['date'] = datetime.now(ZoneInfo('Asia/Singapore')).isoformat()
    (WORK / 'bundle-audit.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    if not result['pass']:
        raise RuntimeError('\n'.join(result['failures']))
    print(json.dumps({'app': str(APP), 'version': result['version'], 'build': result['build'],
                      'native_binaries': len(result['native_binaries']),
                      'minimum_macos': result['native_minimum_macos'], 'pass': True}, ensure_ascii=False))


if __name__ == '__main__':
    main()
