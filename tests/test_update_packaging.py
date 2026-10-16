"""Release trust boundary checks with synthetic metadata, never meeting data."""
from pathlib import Path
import base64
import importlib.util
import json
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('update_packaging', ROOT / 'scripts/build-update.py')
UPDATE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(UPDATE)


class UpdatePackagingTests(unittest.TestCase):
    def setUp(self):
        work = ROOT / 'work/update-packaging-tests'
        work.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=work)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / 'Synthetic.app'
        (self.app / 'Contents').mkdir(parents=True)
        self.info = {'CFBundleIdentifier': 'io.local.zhihui.meetings',
                     'ZhihuiRuntimeLayout': 'bundled-v1', 'CFBundleShortVersionString': '0.8.0', 'CFBundleVersion': '21',
                     'SUPublicEDKey': UPDATE.CONFIG['public_key'], 'SUFeedURL': UPDATE.CONFIG['feed_url'],
                     'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True}
        self.key = self.root / 'synthetic-key'
        self.key.write_bytes(base64.b64encode(bytes(range(32))))
        self.output = self.root / 'output'

    def rejected(self, reason):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        with self.assertRaisesRegex(RuntimeError, reason):
            UPDATE.prepare(self.app, self.key, self.output)
        self.assertFalse(self.output.exists())

    def test_development_package_rejected(self):
        self.info.pop('ZhihuiRuntimeLayout')
        self.rejected('Only standalone')

    def test_qa_data_configuration_rejected(self):
        self.info['ZhihuiDataDirectory'] = str(self.root / 'qa-data')
        self.rejected('QA configuration')

    def test_unsigned_feed_policy_rejected(self):
        self.info['SURequireSignedFeed'] = False
        self.rejected('Signed feeds')

    def test_different_feed_rejected(self):
        self.info['SUFeedURL'] = 'https://example.invalid/feed.xml'
        self.rejected('does not match')

    def test_wrong_private_key_rejected_before_packaging(self):
        self.rejected('Signing key does not match')

    def test_existing_output_preserved(self):
        self.output.mkdir()
        (self.output / 'sentinel').write_bytes(b'preserve')
        with self.assertRaisesRegex(RuntimeError, 'never overwritten'):
            UPDATE.prepare(self.app, self.key, self.output)
        self.assertEqual((self.output / 'sentinel').read_bytes(), b'preserve')


if __name__ == '__main__':
    unittest.main()
