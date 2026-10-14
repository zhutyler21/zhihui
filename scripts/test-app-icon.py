"""Exercise the actual icon generator without starting an application or GUI."""
from pathlib import Path
import hashlib
import json
import struct
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = Path('/Users/zhutyler21/我的项目仓库/知会本地会议').resolve()
assert ROOT.resolve() == EXPECTED, 'wrong project root'
OUTPUT = ROOT / 'work' / 'ui-upgrade-qa' / ('icon-check-' + uuid.uuid4().hex)
OUTPUT.mkdir(parents=True, mode=0o700)
SOURCE = ROOT / 'scripts' / 'AppIcon.swift'
ICONSET = OUTPUT / 'AppIcon.iconset'
run = subprocess.run(['xcrun', 'swift', str(SOURCE), str(ICONSET)], capture_output=True, text=True)
(OUTPUT / 'generator.log').write_text(run.stdout + run.stderr)
assert run.returncode == 0, run.stderr
expected = {
    'icon_16x16.png': 16, 'icon_16x16@2x.png': 32,
    'icon_32x32.png': 32, 'icon_32x32@2x.png': 64,
    'icon_128x128.png': 128, 'icon_128x128@2x.png': 256,
    'icon_256x256.png': 256, 'icon_256x256@2x.png': 512,
    'icon_512x512.png': 512, 'icon_512x512@2x.png': 1024,
}
assert {p.name for p in ICONSET.glob('*.png')} == set(expected)
results = {}
for name, size in expected.items():
    raw = (ICONSET / name).read_bytes()
    assert raw[:8] == b'\x89PNG\r\n\x1a\n' and raw[12:16] == b'IHDR', name
    width, height = struct.unpack('>II', raw[16:24])
    assert (width, height) == (size, size), (name, width, height, size)
    assert raw[25] == 6, (name, 'RGBA PNG expected')
    results[name] = {'width': width, 'height': height, 'sha256': hashlib.sha256(raw).hexdigest()}
receipt = {'pass': True, 'source_sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(), 'icons': results}
(OUTPUT / 'receipt.json').write_text(json.dumps(receipt, indent=2))
print('PASS: all 10 generated RGBA icons have exact physical pixel dimensions; ' + str(OUTPUT))
