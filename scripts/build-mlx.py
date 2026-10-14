#!/usr/bin/env python3
"""Build the pinned, unmodified MLX wheels for macOS 14 without changing .venv."""
from contextlib import contextmanager
from pathlib import Path
import argparse
import base64
import csv
import email
import fcntl
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.32.3'
PYTHON_VERSION = '3.12.11'
TARGET = '14.0'
COMMIT = '64ea011cb65f14d9ce2737e60db9a4ae91ed7441'
SOURCE_URL = f'https://codeload.github.com/ml-explore/mlx/tar.gz/{COMMIT}'
SOURCE_SHA256 = '428070f9b74ab39b5f65ae90a0a409c14b1a7a75911d041864788bfbdb9f7ef0'
DEPENDENCY_NOTICES = ROOT / 'docs/licenses/mlx-source-build'
DEPENDENCY_MANIFEST_SHA256 = 'a81c9b43dfc0e6a5ad43e169cfe8f49ccdbc6f8647d90834b7fc8ef3504f2480'
CMAKE_ARGS = ('-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 '
              '-DMLX_BUILD_PYTHON_STUBS=OFF')
WHEEL_NAMES = [f'mlx-{VERSION}-cp312-cp312-macosx_14_0_arm64.whl',
               f'mlx_metal-{VERSION}-py3-none-macosx_14_0_arm64.whl']
EFFECTIVE_OPTIONS = {'MLX_BUILD_CPU': 'ON', 'MLX_BUILD_METAL': 'ON',
                     'MLX_BUILD_SAFETENSORS': 'ON', 'MLX_BUILD_GGUF': 'ON',
                     'MLX_METAL_JIT': 'OFF', 'MLX_BUILD_PYTHON_BINDINGS': 'ON',
                     'MLX_BUILD_PYTHON_STUBS': 'OFF', 'MLX_BUILD_TESTS': 'OFF',
                     'MLX_BUILD_EXAMPLES': 'OFF', 'MLX_BUILD_BENCHMARKS': 'OFF',
                     'CMAKE_OSX_DEPLOYMENT_TARGET': TARGET,
                     'CMAKE_OSX_ARCHITECTURES': 'arm64', 'MLX_VERSION': VERSION}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def owned_cache(value):
    path = Path(value).expanduser().absolute()
    work = ROOT / 'work'
    if not path.resolve().is_relative_to(work.resolve()) or path == work:
        raise RuntimeError('MLX build cache must be inside this repository work directory.')
    for component in (path, *path.parents):
        if component == ROOT:
            break
        if component.is_symlink():
            raise RuntimeError('MLX build cache cannot pass through symlinks.')
    path.mkdir(parents=True, exist_ok=True)
    return path.resolve()


@contextmanager
def cache_lock(cache):
    descriptor = os.open(cache / '.build.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(descriptor)


def prepare_source(cache):
    archive = cache / f'mlx-{VERSION}-source.tar.gz'
    if archive.is_symlink():
        raise RuntimeError('MLX source archive cannot be a symlink.')
    if not archive.exists():
        partial = archive.with_suffix('.gz.partial')
        if partial.is_symlink():
            raise RuntimeError('MLX source temporary file cannot be a symlink.')
        with urllib.request.urlopen(SOURCE_URL, timeout=60) as response, partial.open('wb') as out:
            shutil.copyfileobj(response, out, length=1024 * 1024)
        if sha(partial) != SOURCE_SHA256:
            raise RuntimeError('Official MLX source archive does not match the pinned hash.')
        partial.replace(archive)
    if sha(archive) != SOURCE_SHA256:
        raise RuntimeError('Cached MLX source archive does not match the pinned hash.')
    source_parent = cache / 'source'
    source = source_parent / ('mlx-' + COMMIT)
    if source_parent.is_symlink() or source.is_symlink():
        raise RuntimeError('MLX source directory cannot be a symlink.')
    with tarfile.open(archive) as tar:
        members = tar.getmembers()
        for member in members:
            parts = Path(member.name).parts
            if (not parts or parts[0] != source.name or member.name.startswith('/')
                    or '..' in parts or not (member.isfile() or member.isdir() or member.issym())):
                raise RuntimeError('Unexpected path or member type in the MLX source archive.')
            if member.issym():
                target = (source_parent / member.name).parent / member.linkname
                if member.linkname.startswith('/') or not target.resolve().is_relative_to(source):
                    raise RuntimeError('MLX source symlink escapes the pinned source tree.')
        if not source.exists():
            source_parent.mkdir(exist_ok=True)
            tar.extractall(source_parent, members=members, filter='data')
        # Extra build outputs are allowed; every official input must remain unchanged.
        for member in members:
            if member.issym():
                actual = source_parent / member.name
                if not actual.is_symlink() or os.readlink(actual) != member.linkname or not actual.resolve().is_relative_to(source):
                    raise RuntimeError('An official MLX source symlink was modified.')
                continue
            if not member.isfile():
                continue
            actual = source_parent / member.name
            if not actual.is_file() or actual.is_symlink() or not actual.resolve().is_relative_to(source):
                raise RuntimeError('An official MLX source input is missing or redirected.')
            with tar.extractfile(member) as stream:
                expected = hashlib.file_digest(stream, 'sha256').hexdigest()
            if sha(actual) != expected:
                raise RuntimeError('An official MLX source input was modified: ' + member.name)
    return source, archive


def audit_wheels(wheels, cache):
    binaries, licenses, metallibs = [], [], []
    with tempfile.TemporaryDirectory(prefix='.wheel-audit-', dir=cache) as temp:
        stage = Path(temp)
        for wheel in wheels:
            if wheel.name not in WHEEL_NAMES or wheel.is_symlink():
                raise RuntimeError('Unexpected MLX wheel name or path.')
            with zipfile.ZipFile(wheel) as archive:
                names = archive.namelist()
                if len(names) != len(set(names)):
                    raise RuntimeError('Duplicate MLX wheel member.')
                for name in names:
                    if name.startswith('/') or '..' in Path(name).parts or '\\' in name:
                        raise RuntimeError('Unsafe MLX wheel member.')
                    mode = archive.getinfo(name).external_attr >> 16
                    if mode & 0o170000 == 0o120000:
                        raise RuntimeError('MLX wheel cannot contain redirected files.')
                metadata_name = next(name for name in names if name.endswith('.dist-info/METADATA'))
                if email.message_from_bytes(archive.read(metadata_name))['Version'] != VERSION:
                    raise RuntimeError('MLX wheel version does not match the fixed dependency.')
                record_name = next(name for name in names if name.endswith('.dist-info/RECORD'))
                records = list(csv.reader(io.StringIO(archive.read(record_name).decode())))
                if {row[0] for row in records} != {name for name in names if not name.endswith('/')}:
                    raise RuntimeError('MLX wheel RECORD does not match its contents.')
                for name, digest, size in records:
                    if name == record_name:
                        continue
                    data = archive.read(name)
                    expected = 'sha256=' + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip('=')
                    if digest != expected or size != str(len(data)):
                        raise RuntimeError('MLX wheel content differs from RECORD: ' + name)
                archive.extractall(stage)
        for path in stage.rglob('*'):
            if not path.is_file():
                continue
            relative = str(path.relative_to(stage))
            if path.name == 'LICENSE':
                licenses.append({'path': relative, 'sha256': sha(path)})
            if path.suffix == '.metallib':
                metallibs.append({'path': relative, 'size': path.stat().st_size, 'sha256': sha(path)})
            with path.open('rb') as stream:
                magic = stream.read(4)
            if magic != bytes.fromhex('cffaedfe'):
                continue
            commands = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
            rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path ([^\n]+)', commands)
            if any(not value.startswith(('@loader_path/', '@executable_path/')) for value in rpaths):
                raise RuntimeError('MLX wheel retains a machine-specific library search path.')
            minima = re.findall(r'\bminos\s+([0-9.]+)', commands)
            if minima != [TARGET]:
                raise RuntimeError('MLX native binary has an unexpected actual deployment target: ' + relative)
            if subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).strip() != 'arm64':
                raise RuntimeError('MLX binary architecture differs from the release target.')
            lines = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True).splitlines()[1:]
            libraries = [line.strip().split(' (', 1)[0] for line in lines]
            for dependency in libraries:
                if dependency.startswith(('/System/Library/', '/usr/lib/')):
                    continue
                if dependency.startswith('@rpath/') and (stage / 'mlx/lib' / dependency.removeprefix('@rpath/')).is_file():
                    continue
                raise RuntimeError('MLX binary has an external or unresolved runtime dependency: ' + dependency)
            binaries.append({'path': relative, 'sha256': sha(path), 'minimum_macos': TARGET, 'libraries': libraries})
        if len(binaries) != 3 or len(metallibs) != 1 or not metallibs[0]['size'] or len(licenses) != 2:
            raise RuntimeError('MLX wheels are missing native components, precompiled Metal, or licenses.')
    return {'native_binaries': binaries, 'metallibs': metallibs, 'licenses': licenses,
            'native_minimum_macos': TARGET, 'omitted_components': []}


def additional_dependencies(source):
    """Verify the exact clean build checkouts and notices for embedded C++ code."""
    manifest = DEPENDENCY_NOTICES / 'DEPENDENCIES.json'
    if manifest.is_symlink() or sha(manifest) != DEPENDENCY_MANIFEST_SHA256:
        raise RuntimeError('Embedded MLX dependency notice manifest differs from its fixed inputs.')
    expected = json.loads(manifest.read_text())
    if expected.get('mlx_version') != VERSION or expected.get('mlx_source_commit') != COMMIT:
        raise RuntimeError('Embedded MLX dependency notices refer to a different upstream version.')
    candidates = list((source / 'build').glob('temp.*/mlx.core/_deps'))
    if len(candidates) != 1:
        raise RuntimeError('The verified MLX build dependency directory is missing or ambiguous.')
    deps = candidates[0]
    locations = {'fmt': deps / 'fmt-src', 'nanobind': deps / 'nanobind-src',
                 'robin-map': deps / 'nanobind-src/ext/robin_map'}
    for item in expected['dependencies']:
        directory = locations[item['name']]
        if directory.is_symlink() or not directory.resolve().is_relative_to(source):
            raise RuntimeError('Embedded MLX dependency checkout escapes the owned source tree.')

        def git(*arguments):
            return subprocess.check_output(['git', '-C', str(directory), *arguments], text=True).strip()

        if (git('rev-parse', 'HEAD') != item['commit']
                or git('rev-parse', item['tag'] + '^{commit}') != item['commit']
                or git('remote', 'get-url', 'origin') != item['repository']
                or git('status', '--porcelain')):
            raise RuntimeError('Embedded MLX dependency commit, tag, origin or clean state changed: ' + item['name'])
        notice = DEPENDENCY_NOTICES / item['license_file']
        license_source = directory / 'LICENSE'
        if (notice.is_symlink() or license_source.is_symlink()
                or not license_source.resolve().is_relative_to(directory)
                or sha(notice) != item['license_sha256'] or sha(license_source) != item['license_sha256']):
            raise RuntimeError('Embedded MLX dependency license differs from the pinned source: ' + item['name'])
        if item.get('parent_dependency'):
            parent = locations[item['parent_dependency']]
            parent_commit = subprocess.check_output(['git', '-C', str(parent), 'rev-parse', 'HEAD'], text=True).strip()
            submodule = subprocess.check_output(['git', '-C', str(parent), 'ls-tree', 'HEAD', item['submodule_path']], text=True).strip()
            if parent_commit != item['parent_commit'] or submodule != '160000 commit ' + item['commit'] + '\t' + item['submodule_path']:
                raise RuntimeError('Embedded MLX dependency submodule does not match its fixed parent commit.')
    return expected['dependencies']


def build(cache=None):
    cache = owned_cache(cache or ROOT / 'work/standalone-mlx')
    with cache_lock(cache):
        source, archive = prepare_source(cache)
        manifest_path = cache / 'manifest.json'
        wheels_dir = cache / 'wheels'
        wheels = [wheels_dir / name for name in WHEEL_NAMES]
        if manifest_path.is_symlink() or wheels_dir.is_symlink() or (cache / 'build-env').is_symlink():
            raise RuntimeError('MLX cached inputs cannot use redirected directories or manifests.')
        if manifest_path.exists():
            metadata = json.loads(manifest_path.read_text())
            if (metadata.get('source_sha256') != SOURCE_SHA256 or metadata.get('source_commit') != COMMIT
                    or metadata.get('version') != VERSION or metadata.get('python_version') != PYTHON_VERSION
                    or metadata.get('cmake_args') != CMAKE_ARGS or metadata.get('effective_options') != EFFECTIVE_OPTIONS
                    or metadata.get('deployment_target') != TARGET or metadata.get('source_modified') is not False
                    or metadata.get('source_license_sha256') != sha(source / 'LICENSE')):
                raise RuntimeError('Cached MLX build inputs differ; retain the old cache and use a fresh owned directory.')
            if metadata.get('wheels') != [{'filename': wheel.name, 'size': wheel.stat().st_size, 'sha256': sha(wheel)} for wheel in wheels]:
                raise RuntimeError('Cached MLX wheels changed; retain evidence and use a fresh owned directory.')
            current = audit_wheels(wheels, cache)
            if metadata.get('audit') != current:
                raise RuntimeError('Cached MLX native audit no longer matches the verified build.')
            dependencies = additional_dependencies(source)
            if metadata.get('additional_dependencies') is None:
                # Upgrade only metadata after checking the existing exact source,
                # wheel hashes, native audit and actual dependency checkouts.
                backup = cache / 'manifest-before-dependency-notices.json'
                if backup.is_symlink():
                    raise RuntimeError('The previous MLX cache manifest backup cannot be redirected.')
                if not backup.exists():
                    shutil.copy2(manifest_path, backup)
                metadata['additional_dependencies'] = dependencies
                manifest_path.write_text(json.dumps(metadata, indent=2) + '\n')
            elif metadata['additional_dependencies'] != dependencies:
                raise RuntimeError('Cached embedded MLX dependency provenance changed.')
            return wheels, archive, metadata
        if wheels_dir.exists():
            raise RuntimeError('Unverified MLX wheels already exist; retain them and use a fresh owned cache.')
        python_env = cache / 'build-env'
        if python_env.exists():
            raise RuntimeError('Unverified MLX build environment exists; retain it and use a fresh owned cache.')
        uv = shutil.which('uv')
        if not uv:
            raise RuntimeError('Install uv to build the pinned managed MLX runtime.')
        cmake = shutil.which('cmake')
        if not cmake:
            raise RuntimeError('Install CMake >= 3.25 as a development build tool.')
        cmake_version = subprocess.check_output([cmake, '--version'], text=True).splitlines()[0]
        match = re.search(r'\b(\d+)\.(\d+)\.(\d+)\b', cmake_version)
        if not match or tuple(map(int, match.groups())) < (3, 25, 0):
            raise RuntimeError('The MLX source build requires CMake >= 3.25.')
        subprocess.run([uv, 'venv', '--python', PYTHON_VERSION, '--managed-python', str(python_env)], check=True)
        python = python_env / 'bin/python'
        subprocess.run([uv, 'pip', 'install', '--python', str(python), 'setuptools==84.0.0',
                        'wheel==0.48.0', 'typing_extensions==4.16.0'], check=True)
        toolchain = {'python_version': subprocess.check_output([str(python), '-I', '-B', '-c',
                      'import platform;print(platform.python_version())'], text=True).strip(),
                     'sdk': subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(),
                     'clang': subprocess.check_output(['xcrun', 'clang', '--version'], text=True).splitlines()[0],
                     'cmake': cmake_version}
        if toolchain['python_version'] != PYTHON_VERSION:
            raise RuntimeError('MLX builder interpreter is not the pinned managed Python.')
        environment = dict(os.environ, PYPI_RELEASE='1', MACOSX_DEPLOYMENT_TARGET=TARGET,
                           CMAKE_BUILD_PARALLEL_LEVEL='8', CMAKE_ARGS=CMAKE_ARGS, PYTHONDONTWRITEBYTECODE='1',
                           PATH=str(python_env / 'bin') + os.pathsep + os.environ.get('PATH', ''))
        commands = []
        for frontend in (True, False):
            mode = 'frontend' if frontend else 'metal'
            environment.update(MLX_BUILD_FRONTEND_PACKAGE='1' if frontend else '0',
                               MLX_BUILD_BACKEND_PACKAGE='0' if frontend else '1')
            command = [str(python), '-B', 'setup.py', 'bdist_wheel', '--plat-name', 'macosx_14_0_arm64']
            if not frontend:
                command += ['--python-tag', 'py3']
            print('Building pinned MLX ' + mode + ' for macOS ' + TARGET + '…', flush=True)
            with (cache / (mode + '-build.log')).open('wb') as log:
                subprocess.run(command, cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
            commands.append({'mode': mode, 'arguments': ['python3', *command[1:]],
                             'environment': {key: environment[key] for key in ['PYPI_RELEASE', 'MACOSX_DEPLOYMENT_TARGET',
                                 'CMAKE_ARGS', 'CMAKE_BUILD_PARALLEL_LEVEL', 'MLX_BUILD_FRONTEND_PACKAGE', 'MLX_BUILD_BACKEND_PACKAGE']}})
        cmake_cache = next((source / 'build').glob('temp.*/mlx.core/CMakeCache.txt')).read_text()
        for key, expected in EFFECTIVE_OPTIONS.items():
            if not re.search(r'^' + re.escape(key) + r':[^=]+=' + re.escape(expected) + r'$', cmake_cache, re.M):
                raise RuntimeError('Effective MLX option differs from the pinned build: ' + key)
        dependencies = additional_dependencies(source)
        wheels_dir.mkdir()
        for wheel in wheels:
            shutil.copy2(source / 'dist' / wheel.name, wheel)
        metadata = {'version': VERSION, 'python_version': PYTHON_VERSION, 'deployment_target': TARGET,
                    'source_commit': COMMIT, 'source_url': SOURCE_URL, 'source_sha256': SOURCE_SHA256,
                    'source_modified': False, 'cmake_args': CMAKE_ARGS, 'effective_options': EFFECTIVE_OPTIONS,
                    'toolchain': toolchain, 'commands': commands,
                    'additional_dependencies': dependencies,
                    'wheels': [{'filename': wheel.name, 'size': wheel.stat().st_size, 'sha256': sha(wheel)} for wheel in wheels],
                    'source_license_sha256': sha(source / 'LICENSE'), 'audit': audit_wheels(wheels, cache)}
        manifest_path.write_text(json.dumps(metadata, indent=2) + '\n')
        return wheels, archive, metadata


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-dir', type=Path)
    arguments = parser.parse_args()
    wheels, source_archive, metadata = build(arguments.cache_dir)
    print(json.dumps({'wheels': [str(path) for path in wheels], 'source_archive': str(source_archive),
                      'native_minimum_macos': metadata['audit']['native_minimum_macos']}))
