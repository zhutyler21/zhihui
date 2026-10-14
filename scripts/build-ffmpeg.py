#!/usr/bin/env python3
"""Build the pinned LGPL FFmpeg executable without Homebrew runtime dependencies."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'Resources/StandaloneRuntime.json').read_text())


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def validate_binary(binary):
    output = subprocess.check_output(['/usr/bin/otool', '-L', str(binary)]).decode()
    dependencies = [line.strip().split(' (compatibility version', 1)[0]
                    for line in output.splitlines() if ' (compatibility version' in line]
    if not dependencies or any(not value.startswith(('/usr/lib/', '/System/Library/')) for value in dependencies):
        raise RuntimeError('FFmpeg still has build-machine library dependencies.')
    license_text = subprocess.check_output([str(binary), '-L'], stderr=subprocess.STDOUT).decode()
    configuration = subprocess.check_output([str(binary), '-buildconf'], stderr=subprocess.STDOUT).decode()
    required = ('--disable-gpl', '--disable-nonfree', '--disable-network', '--disable-autodetect')
    if 'Lesser General Public License' not in license_text or not all(flag in configuration for flag in required):
        raise RuntimeError('FFmpeg LGPL / offline configuration was not preserved.')
    if '--enable-gpl' in configuration or '--enable-nonfree' in configuration:
        raise RuntimeError('Unexpected restricted FFmpeg configuration.')
    return '\n'.join(dependencies), license_text


def build(cache):
    cache = Path(cache).resolve()
    if ROOT / 'work' not in cache.parents:
        raise RuntimeError('FFmpeg build cache must be inside this repository work directory.')
    cache.mkdir(parents=True, exist_ok=True)
    version = CONFIG['ffmpeg_version']
    archive = cache / ('ffmpeg-' + version + '.tar.xz')
    if not archive.exists():
        partial = archive.with_suffix(archive.suffix + '.partial')
        with urllib.request.urlopen(CONFIG['ffmpeg_source_url'], timeout=60) as response, partial.open('wb') as out:
            shutil.copyfileobj(response, out, length=1024 * 1024)
        if sha(partial) != CONFIG['ffmpeg_source_sha256']:
            raise RuntimeError('FFmpeg source hash differs from the pinned release.')
        partial.replace(archive)
    if sha(archive) != CONFIG['ffmpeg_source_sha256']:
        raise RuntimeError('Cached FFmpeg source does not match the pinned release.')
    source = cache / ('ffmpeg-' + version)
    manifest = cache / 'manifest.json'
    binary = source / 'ffmpeg'
    if manifest.exists() and binary.is_file():
        saved = json.loads(manifest.read_text())
        if (saved.get('source_extraction') == 'fresh-pinned-archive-v1'
                and saved['source_sha256'] == CONFIG['ffmpeg_source_sha256']
                and saved['binary_sha256'] == sha(binary)):
            validate_binary(binary)
            return binary, archive, saved
        if saved.get('source_extraction') == 'fresh-pinned-archive-v1':
            raise RuntimeError('Cached FFmpeg binary changed; retain this cache and select a fresh one.')
        manifest.rename(cache / ('manifest-unverified-' + uuid.uuid4().hex + '.json'))
    if source.exists():
        source.rename(cache / ('source-unverified-' + uuid.uuid4().hex))
    if not source.exists():
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                if member.name.startswith('/') or '..' in Path(member.name).parts:
                    raise RuntimeError('Unsafe FFmpeg archive member.')
            tar.extractall(cache, filter='data')
    clang = subprocess.check_output(['xcrun', '--find', 'clang']).decode().strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).decode().strip()
    flags = ['--disable-autodetect', '--disable-network', '--disable-avdevice',
             '--disable-ffplay', '--disable-ffprobe', '--disable-doc', '--disable-debug',
             '--disable-shared', '--enable-static', '--disable-gpl', '--disable-nonfree',
             '--disable-version3', '--disable-videotoolbox', '--disable-audiotoolbox',
             '--cc=' + clang, '--host-cc=' + clang, '--sysroot=' + sdk,
             '--host-cflags=-isysroot ' + sdk + ' -mmacosx-version-min=14.0',
             '--host-ldflags=-isysroot ' + sdk + ' -mmacosx-version-min=14.0',
             '--extra-cflags=-isysroot ' + sdk + ' -mmacosx-version-min=14.0',
             '--extra-ldflags=-isysroot ' + sdk + ' -mmacosx-version-min=14.0']
    environment = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin')
    with (cache / 'configure.log').open('wb') as log:
        subprocess.run([str(source / 'configure'), *flags], cwd=source, env=environment,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    print('Compiling the pinned standalone audio converter…', flush=True)
    with (cache / 'make.log').open('wb') as log:
        subprocess.run(['/usr/bin/make', '-j8'], cwd=source, env=environment,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    dependencies, license_text = validate_binary(binary)
    saved = {'source_extraction': 'fresh-pinned-archive-v1', 'version': version, 'source_sha256': sha(archive), 'binary_sha256': sha(binary),
             'configure_flags': flags, 'libraries': dependencies, 'license_output': license_text}
    manifest.write_text(json.dumps(saved, indent=2) + '\n')
    return binary, archive, saved


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-dir', type=Path,
                        default=ROOT / 'work/standalone-release-v0.5.0/ffmpeg')
    args = parser.parse_args()
    binary, archive, metadata = build(args.cache_dir)
    print(json.dumps({'binary': str(binary), 'source_archive': str(archive),
                      'source_sha256': metadata['source_sha256']}))
