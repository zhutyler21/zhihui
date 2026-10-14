#!/usr/bin/env python3
"""Audit the actual relocated app, executable dependencies and signed resources."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import subprocess

MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe',
         b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}


def macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in MAGIC


def audit(app, *, verify_signature=True):
    app = Path(app).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    failures = []
    if info.get('CFBundleIdentifier') != 'io.local.zhihui.meetings':
        failures.append('wrong application identity')
    if info.get('ZhihuiRuntimeLayout') != 'bundled-v1':
        failures.append('standalone runtime marker missing')
    if 'ZhihuiProjectRoot' in info:
        failures.append('release still contains a build-machine project path')
    runtime = app / 'Contents/Resources/Runtime'
    if not (app / 'Contents/MacOS/知会').is_file():
        failures.append('missing native app executable')
    required = ['python/bin/python3', 'scripts/run-backend.py', 'scripts/setup-models.py',
                'backend/server.py', 'Resources/ModelCatalog.json', 'bin/ffmpeg',
                'python/lib/python3.12/site-packages/certifi/cacert.pem']
    failures += ['missing ' + name for name in required if not (runtime / name).is_file()]
    if (runtime / 'models').exists():
        failures.append('model storage is inside the read-only app')
    if any(key in info for key in ('ZhihuiDataDirectory', 'ZhihuiPort')):
        failures.append('release contains QA configuration')
    files = [path for path in app.rglob('*') if path.is_file()]
    binaries = [path for path in files if macho(path)]
    libraries = []
    executables = [runtime / 'python/bin/python3', runtime / 'bin/ffmpeg', app / 'Contents/MacOS/知会']
    def executable_for(image):
        return (runtime / 'python/bin/python3' if image.is_relative_to(runtime / 'python')
                else runtime / 'bin/ffmpeg' if image.is_relative_to(runtime / 'bin')
                else app / 'Contents/MacOS/知会')
    executable_rpaths = {}
    for executable in executables:
        commands = (subprocess.check_output(['/usr/bin/otool', '-l', str(executable)]).decode()
                    if executable.is_file() else '')
        executable_rpaths[executable] = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)', commands)
    # dyld carries a run-path stack from importing images into their dependencies.
    # Propagate only across imports that actually resolve to a bundled image.
    rpath_directories = {}
    imported_libraries = {}
    for image in binaries:
        load_commands = subprocess.check_output(['/usr/bin/otool', '-l', str(image)]).decode()
        searches = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)', load_commands)
        directories = set()
        executable = executable_for(image)
        for search, loader in [(value, image.parent) for value in searches] + [(value, executable.parent) for value in executable_rpaths[executable]]:
            expanded = search.replace('@loader_path', str(loader)).replace('@executable_path', str(executable.parent))
            if expanded.startswith('/'):
                directory = Path(expanded).resolve()
                if directory == app or app in directory.parents:
                    directories.add(directory)
        rpath_directories[image] = directories
        imported_libraries[image] = re.findall(r'^\s+(@[^ ]+) \(compatibility version',
            subprocess.check_output(['/usr/bin/otool', '-L', str(image)]).decode(), re.M)
    for _ in range(len(binaries)):
        changed = False
        for image, imports in imported_libraries.items():
            for dependency in imports:
                targets = []
                if dependency.startswith('@rpath/'):
                    targets = [directory / dependency.removeprefix('@rpath/') for directory in rpath_directories[image]]
                elif dependency.startswith('@loader_path/'):
                    targets = [image.parent / dependency.removeprefix('@loader_path/')]
                for candidate in targets:
                    target = candidate.resolve()
                    if target in rpath_directories:
                        added = rpath_directories[image] - rpath_directories[target]
                        if added:
                            rpath_directories[target].update(added)
                            changed = True
        if not changed:
            break
    minimum = (14, 0, 0)
    for path in binaries:
        relative = path.relative_to(app).as_posix()
        deps = subprocess.check_output(['/usr/bin/otool', '-L', str(path)]).decode()
        arches = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)]).decode().split()
        if 'arm64' not in arches:
            failures.append('no Apple Silicon architecture: ' + relative)
        commands = subprocess.check_output(['/usr/bin/otool', '-l', str(path)]).decode()
        versions = re.findall(r'\bminos\s+(\d+\.\d+(?:\.\d+)?)', commands)
        versions += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+\.\d+(?:\.\d+)?)', commands)
        for value in versions:
            parts = tuple(map(int, value.split('.')))
            minimum = max(minimum, parts + (0,) * (3 - len(parts)))
        install_ids = {line.strip() for line in subprocess.check_output(
            ['/usr/bin/otool', '-D', str(path)]).decode().splitlines()
            if line.strip() and not line.rstrip().endswith(':')}
        dependencies = []
        for line in deps.splitlines()[1:]:
            if ' (compatibility version' not in line:
                continue
            dependency = line.strip().split(' (compatibility version', 1)[0]
            if dependency in install_ids:
                continue  # LC_ID_DYLIB is this image's name, not an imported library.
            dependencies.append(dependency)
            if dependency.startswith(('/System/Library/', '/usr/lib/')):
                continue
            if dependency.startswith('@loader_path/'):
                target = (path.parent / dependency.removeprefix('@loader_path/')).resolve()
                if not target.is_file() or app not in target.parents:
                    failures.append('escaping/missing loader dependency: ' + relative + ': ' + dependency)
            elif dependency.startswith('@executable_path/'):
                suffix = dependency.removeprefix('@executable_path/')
                targets = [(executable_for(path).parent / suffix).resolve()]
                if not any(p.is_file() and app in p.parents for p in targets):
                    failures.append('missing executable dependency: ' + relative + ': ' + dependency)
            elif dependency.startswith('@rpath/'):
                targets = [(directory / dependency.removeprefix('@rpath/')).resolve()
                           for directory in rpath_directories[path]]
                if not any(target.is_file() and app in target.parents for target in targets):
                    failures.append('unreachable rpath dependency: ' + relative + ': ' + dependency)
            else:
                failures.append('external dependency: ' + relative + ': ' + dependency)
        libraries.append({'file': relative, 'architectures': arches, 'dependencies': dependencies})
    for path in app.rglob('*'):
        if path.is_symlink() and app not in path.resolve().parents:
            failures.append('escaping symlink: ' + path.relative_to(app).as_posix())
    if verify_signature:
        signature = subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if signature.returncode:
            failures.append('strict signature invalid: ' + signature.stderr.decode())
    else:
        signature = None
    plist_min = tuple(map(int, info.get('LSMinimumSystemVersion', '0').split('.')))
    plist_min += (0,) * (3 - len(plist_min))
    if plist_min < minimum:
        failures.append('Info.plist OS floor is below bundled native dependency floor')
    return {'app': str(app), 'version': info.get('CFBundleShortVersionString'),
            'build': info.get('CFBundleVersion'), 'pass': not failures, 'failures': failures,
            'native_minimum_macos': '.'.join(map(str, minimum)), 'native_binaries': libraries,
            'files_sha256': {p.relative_to(app).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in files}, 'signature_checked': verify_signature}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    result = audit(args.app)
    if args.receipt:
        root = Path(__file__).resolve().parents[1]
        target = args.receipt.resolve()
        if root / 'work' not in target.parents:
            raise SystemExit('Audit receipts must stay in this project work directory.')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in
                      ['version', 'build', 'pass', 'failures', 'native_minimum_macos']}, ensure_ascii=False))
    raise SystemExit(0 if result['pass'] else 1)


if __name__ == '__main__':
    main()
