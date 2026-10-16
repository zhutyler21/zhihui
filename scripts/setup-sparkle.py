#!/usr/bin/env python3
"""Fetch the pinned Sparkle distribution and embed/sign its nested bundles."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'Resources/Updates.json').read_text())


def distribution():
    cache = ROOT / 'work/dependencies'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / ('Sparkle-' + CONFIG['framework_version'] + '.tar.xz')
    expected = CONFIG['framework_sha256']
    if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        fd, filename = tempfile.mkstemp(dir=cache, suffix='.download')
        try:
            with os.fdopen(fd, 'wb') as target, urllib.request.urlopen(CONFIG['framework_url'], timeout=60) as source:
                shutil.copyfileobj(source, target)
            if hashlib.sha256(Path(filename).read_bytes()).hexdigest() != expected:
                raise RuntimeError('Sparkle archive checksum mismatch')
            os.replace(filename, archive)
        finally:
            Path(filename).unlink(missing_ok=True)
    # Extract a fresh verified copy; never trust an old mutable framework cache.
    target = Path(tempfile.mkdtemp(prefix='sparkle-', dir=cache))
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or member.isdev():
                raise RuntimeError('Unsafe path in Sparkle archive')
            if member.issym() or member.islnk():
                link = PurePosixPath(member.linkname)
                combined = path.parent / link if member.issym() else link
                depth = 0
                for part in combined.parts:
                    depth += -1 if part == '..' else 0 if part == '.' else 1
                    if depth < 0 or link.is_absolute():
                        raise RuntimeError('Escaping link in Sparkle archive')
        if hasattr(tarfile, 'data_filter'):
            package.extractall(target, filter='data')
        else:
            package.extractall(target)
    return target


def sign_framework(app, identity):
    framework = Path(app) / 'Contents/Frameworks/Sparkle.framework'
    base = framework / 'Versions/B'
    for name in ['XPCServices/Installer.xpc', 'XPCServices/Downloader.xpc',
                 'Autoupdate', 'Updater.app', None]:
        path = base / name if name else framework
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity,
                        '--preserve-metadata=entitlements', str(path)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(framework)], check=True)


def embed(source, app, identity):
    contents = Path(app) / 'Contents'
    frameworks = contents / 'Frameworks'
    frameworks.mkdir(parents=True, exist_ok=True)
    destination = frameworks / 'Sparkle.framework'
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(Path(source) / 'Sparkle.framework', destination, symlinks=True)
    license_dir = contents / 'Resources/ThirdPartyLicenses'
    license_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(Path(source) / 'LICENSE', license_dir / 'Sparkle.txt')
    sign_framework(app, identity)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--embed', type=Path)
    parser.add_argument('--distribution', type=Path)
    parser.add_argument('--sign', default='-')
    args = parser.parse_args()
    source = args.distribution or distribution()
    if args.embed:
        embed(source, args.embed, args.sign)
    else:
        print(source)


if __name__ == '__main__':
    main()
