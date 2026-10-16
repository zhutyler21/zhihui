#!/usr/bin/env python3
"""Prepare a signed GitHub Release update archive/feed locally; never upload."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'Resources/Updates.json').read_text())
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(app, key_file, output):
    app, key_file, output = app.resolve(), key_file.resolve(), output.resolve()
    if ROOT / 'dist' not in app.parents and ROOT / 'work' not in app.parents:
        raise RuntimeError('Update source must be a project-owned build.')
    if ROOT / 'dist' not in output.parents and ROOT / 'work' not in output.parents:
        raise RuntimeError('Update output must stay under dist/ or work/.')
    if output.exists():
        raise RuntimeError('Use a new output directory; existing releases are never overwritten.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('ZhihuiRuntimeLayout') != 'bundled-v1' or info.get('CFBundleIdentifier') != 'io.local.zhihui.meetings':
        raise RuntimeError('Only standalone Zhihui builds can be released.')
    if info.get('SUPublicEDKey') != CONFIG['public_key'] or info.get('SUFeedURL') != CONFIG['feed_url']:
        raise RuntimeError('Application update configuration does not match Resources/Updates.json.')
    if not info.get('SURequireSignedFeed') or not info.get('SUVerifyUpdateBeforeExtraction'):
        raise RuntimeError('Signed feeds and verification before extraction are required.')
    if any(key in info for key in ('ZhihuiProjectRoot', 'ZhihuiDataDirectory', 'ZhihuiPort')):
        raise RuntimeError('Release contains development/QA configuration.')
    public_key = subprocess.check_output(['xcrun', 'swift', str(ROOT / 'scripts/setup-update-key.swift'),
                                          '--public-key', str(key_file)], text=True).strip()
    if public_key != CONFIG['public_key']:
        raise RuntimeError('Signing key does not match the public key shipped in the application.')
    audit = load('audit-standalone').audit(app)
    if not audit['pass']:
        raise RuntimeError('Standalone audit failed: ' + '\n'.join(audit['failures']))
    snapshot_bundle = load('install-app').bundle_snapshot
    snapshot = snapshot_bundle(app)
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'\d+(?:\.\d+){1,2}', version) or not re.fullmatch(r'\d+', build):
        raise RuntimeError('Release version/build is invalid.')
    distribution = load('setup-sparkle').distribution()
    output.parent.mkdir(parents=True, exist_ok=True)
    # Only expose complete output after archive, feed and signatures are verified.
    with tempfile.TemporaryDirectory(prefix='update-', dir=output.parent) as temporary:
        stage = Path(temporary) / output.name
        stage.mkdir()
        archive = stage / ('Zhihui-v' + version + '-macOS-arm64.zip')
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
        if snapshot_bundle(app) != snapshot:
            raise RuntimeError('Application changed during update packaging; output was not published.')
        # Secret is passed on stdin, never via command arguments or output.
        private_key = key_file.read_bytes()
        tool = distribution / 'bin/generate_appcast'
        subprocess.run([str(tool), '--ed-key-file', '-', '--maximum-deltas', '0', '--maximum-versions', '1',
                        '--download-url-prefix', 'https://github.com/zhutyler21/zhihui/releases/download/v' + version + '/',
                        '--link', 'https://github.com/zhutyler21/zhihui/releases/tag/v' + version,
                        str(stage)], input=private_key, check=True)
        feed = stage / 'appcast.xml'
        item = ET.parse(feed).find('./channel/item')
        if item is None or item.findtext(SPARKLE + 'version') != build:
            raise RuntimeError('Generated feed does not match the application build.')
        enclosure = item.find('enclosure')
        if enclosure is None or int(enclosure.get('length', '0')) != archive.stat().st_size:
            raise RuntimeError('Archive length is missing or incorrect in the feed.')
        signature = enclosure.get(SPARKLE + 'edSignature', '')
        subprocess.run(['xcrun', 'swift', str(ROOT / 'scripts/setup-update-key.swift'), '--verify',
                        public_key, str(archive), signature], check=True)
        subprocess.run([str(distribution / 'bin/sign_update'), '--verify', '--ed-key-file', '-', str(feed)],
                       input=private_key, check=True)
        receipt = {'version': version, 'build': build, 'feed_url': CONFIG['feed_url'],
                   'archive': archive.name, 'public_key': public_key, 'audit_pass': audit['pass'],
                   'sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (archive, feed)}}
        (stage / 'update-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        (stage / 'SHA256SUMS.txt').write_text(''.join(value + '  ' + name + '\n' for name, value in receipt['sha256'].items()))
        stage.rename(output)
    print('Signed update prepared: ' + str(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/知会.app')
    parser.add_argument('--key-file', type=Path, default=ROOT / 'work/update-signing/ed25519.private-key')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.app, args.key_file, args.output)


if __name__ == '__main__':
    main()
