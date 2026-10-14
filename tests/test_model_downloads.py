"""Real tiny HTTP fixtures for the pinned model preparation entry point."""
import contextlib
import io
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_ROOT = Path('/Users/zhutyler21/我的项目仓库/知会本地会议')
if ROOT.resolve() != EXPECTED_ROOT.resolve():
    raise RuntimeError('Wrong canonical project root for model download tests')
SOURCE = ROOT / 'scripts/setup-models.py'
if not SOURCE.is_file():
    raise RuntimeError('Required model setup source missing')
SPEC = importlib.util.spec_from_file_location('model_setup', SOURCE)
setup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup)


def catalog_for(data, url='https://huggingface.co/pinned/model/resolve/' + '1' * 40 + '/weights.bin'):
    return {'schemaVersion': 1, 'models': [
        {'id': ident, 'name': name, 'folder': ident, 'files': [
            {'path': ident + '/weights.bin', 'size': len(data),
             'sha256': hashlib.sha256(data).hexdigest(), 'url': url}]}
        for ident, name in [('asr', '语音转写'), ('embedding', '知识检索'), ('llm', '中文问答')]
    ]}


@contextlib.contextmanager
def http_fixture(data, *, ignore_range=False, bad_range=False, slow=False):
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requested = self.headers.get('Range')
            requests.append(requested)
            start = int(requested[6:-1]) if requested and not ignore_range else 0
            self.send_response(206 if requested and not ignore_range else 200)
            if requested and not ignore_range:
                self.send_header('Content-Range', f'bytes {start + int(bad_range)}-{len(data) - 1}/{len(data)}')
            self.send_header('Content-Length', str(len(data) - start))
            self.end_headers()
            try:
                for offset in range(start, len(data), 8192):
                    self.wfile.write(data[offset:offset + 8192])
                    self.wfile.flush()
                    if slow:
                        time.sleep(.015)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}/weights.bin', requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


class ModelDownloads(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='model-download-', dir=ROOT / 'work/model-setup-v2')
        self.addCleanup(self.temp.cleanup)
        self.model_root = Path(self.temp.name) / 'models'
        self.data = bytes(range(256)) * 1025
        self.events = []

    def engine(self, catalog=None, **kwargs):
        return setup.ModelDownloader(catalog or catalog_for(self.data), self.model_root,
                                     emit=self.events.append, **kwargs)

    def assert_snapshot(self, event):
        self.assertEqual(['asr', 'embedding', 'llm'], [m['id'] for m in event['models']])
        for model in event['models']:
            self.assertLessEqual(model['completedBytes'], model['totalBytes'])
            self.assertGreaterEqual(model['completedBytes'], 0)
            self.assertEqual(model['ready'], model['phase'] == 'ready')

    def test_actual_bytes_progress_and_atomic_publish(self):
        with http_fixture(self.data) as (url, requests):
            self.engine(catalog_for(self.data, url)).run(download=True)
        self.assertEqual(3, len(requests))
        for ident in ['asr', 'embedding', 'llm']:
            self.assertEqual(self.data, (self.model_root / ident / 'weights.bin').read_bytes())
            self.assertFalse((self.model_root / ident / 'weights.bin.partial').exists())
        intermediate = [m['completedBytes'] for e in self.events for m in e['models']
                        if m['phase'] == 'downloading' and 0 < m['completedBytes'] < len(self.data)]
        self.assertTrue(intermediate)
        for event in self.events:
            self.assert_snapshot(event)
        self.assertEqual('complete', self.events[-1]['type'])
        self.assertTrue(all(m['ready'] for m in self.events[-1]['models']))

    def test_http_range_resume_downloads_only_remaining_bytes(self):
        destination = self.model_root / 'asr'
        destination.mkdir(parents=True)
        prefix = 73123
        (destination / 'weights.bin.partial').write_bytes(self.data[:prefix])
        with http_fixture(self.data) as (url, requests):
            self.engine(catalog_for(self.data, url)).run(download=True)
        self.assertEqual(f'bytes={prefix}-', requests[0])
        self.assertEqual(self.data, (destination / 'weights.bin').read_bytes())

    def test_no_range_support_restarts_without_concatenating(self):
        destination = self.model_root / 'asr'
        destination.mkdir(parents=True)
        (destination / 'weights.bin.partial').write_bytes(b'wrong-prefix')
        with http_fixture(self.data, ignore_range=True) as (url, requests):
            self.engine(catalog_for(self.data, url)).run(download=True)
        self.assertEqual('bytes=12-', requests[0])
        self.assertEqual(self.data, (destination / 'weights.bin').read_bytes())
        self.assertTrue(any(e['models'][0]['phase'] == 'downloading' and
                            e['models'][0]['completedBytes'] == 0 for e in self.events))

    def test_invalid_content_range_keeps_partial_and_never_publishes(self):
        destination = self.model_root / 'asr'
        destination.mkdir(parents=True)
        prefix = self.data[:100]
        (destination / 'weights.bin.partial').write_bytes(prefix)
        with http_fixture(self.data, bad_range=True) as (url, _):
            with self.assertRaises(setup.DownloadError):
                self.engine(catalog_for(self.data, url)).run(download=True)
        self.assertEqual(prefix, (destination / 'weights.bin.partial').read_bytes())
        self.assertFalse((destination / 'weights.bin').exists())

    def test_hash_mismatch_is_not_published(self):
        corrupted = b'x' * len(self.data)
        with http_fixture(corrupted) as (url, _):
            with self.assertRaisesRegex(setup.DownloadError, '校验'):
                self.engine(catalog_for(self.data, url)).run(download=True)
        self.assertFalse((self.model_root / 'asr/weights.bin').exists())
        self.assertEqual(corrupted, (self.model_root / 'asr/weights.bin.partial').read_bytes())
        self.assertFalse(any(m['ready'] for e in self.events for m in e['models']))
        # A later retry of a full invalid partial must restart and produce only verified bytes.
        with http_fixture(self.data) as (url, requests):
            self.engine(catalog_for(self.data, url)).run(download=True)
        self.assertIsNone(requests[0])
        self.assertEqual(self.data, (self.model_root / 'asr/weights.bin').read_bytes())

    def test_cancellation_keeps_partial_without_publish(self):
        token = setup.CancellationToken()

        def on_event(event):
            self.events.append(event)
            if event['models'][0]['phase'] == 'downloading' and event['models'][0]['completedBytes'] > 0:
                token.cancel()

        with http_fixture(self.data) as (url, _):
            engine = setup.ModelDownloader(catalog_for(self.data, url), self.model_root,
                                           emit=on_event, cancellation=token)
            with self.assertRaises(setup.DownloadCancelled):
                engine.run(download=True)
        partial = self.model_root / 'asr/weights.bin.partial'
        self.assertTrue(0 < partial.stat().st_size < len(self.data))
        self.assertFalse((self.model_root / 'asr/weights.bin').exists())

    def test_complete_models_offline_skip_all_network(self):
        for ident in ['asr', 'embedding', 'llm']:
            path = self.model_root / ident / 'weights.bin'
            path.parent.mkdir(parents=True)
            path.write_bytes(self.data)
        with mock.patch.object(urllib.request, 'urlopen', side_effect=AssertionError('Network forbidden')):
            self.engine(opener=urllib.request.urlopen).run(download=True)
        self.assertTrue(all(m['ready'] for m in self.events[-1]['models']))

    def test_status_is_readonly_and_detects_same_size_corruption(self):
        path = self.model_root / 'asr/weights.bin'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'x' * len(self.data))
        before = {str(p): p.read_bytes() for p in self.model_root.rglob('*') if p.is_file()}
        with mock.patch.object(urllib.request, 'urlopen', side_effect=AssertionError('Network forbidden')):
            self.engine(opener=urllib.request.urlopen).run(download=False)
        self.assertFalse(any(m['ready'] for m in self.events[-1]['models']))
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.model_root.rglob('*') if p.is_file()})
        self.assertFalse((self.model_root / '.download.lock').exists())

    def test_missing_status_does_not_create_model_directory(self):
        with mock.patch.object(urllib.request, 'urlopen', side_effect=AssertionError('Network forbidden')):
            self.engine(opener=urllib.request.urlopen).run(download=False)
        self.assertFalse(self.model_root.exists())
        self.assertTrue(all(m['phase'] == 'waiting' and m['completedBytes'] == 0
                            for m in self.events[-1]['models']))

    def test_valid_full_partial_is_verified_then_published_without_network(self):
        for ident in ['asr', 'embedding', 'llm']:
            path = self.model_root / ident / ('weights.bin.partial' if ident == 'asr' else 'weights.bin')
            path.parent.mkdir(parents=True)
            path.write_bytes(self.data)
        with mock.patch.object(urllib.request, 'urlopen', side_effect=AssertionError('Network forbidden')):
            self.engine(opener=urllib.request.urlopen).run(download=True)
        self.assertEqual(self.data, (self.model_root / 'asr/weights.bin').read_bytes())
        self.assertFalse((self.model_root / 'asr/weights.bin.partial').exists())
        self.assertTrue(all(m['ready'] for m in self.events[-1]['models']))

    def test_second_downloader_cannot_enter_existing_lock(self):
        self.model_root.mkdir(parents=True)
        with setup.download_lock(self.model_root):
            with self.assertRaisesRegex(setup.DownloadError, '正在'):
                self.engine().run(download=True)

    def test_catalog_rejects_traversal_duplicate_and_symlink(self):
        for path in ['../escape', '/absolute', 'asr/../../escape', 'embedding/weights.bin']:
            catalog = catalog_for(self.data)
            catalog['models'][0]['files'][0]['path'] = path
            with self.subTest(path=path), self.assertRaises(setup.DownloadError):
                self.engine(catalog)
        catalog = catalog_for(self.data)
        catalog['models'][0]['files'].append(catalog['models'][0]['files'][0].copy())
        with self.assertRaises(setup.DownloadError):
            self.engine(catalog)
        outside = Path(self.temp.name) / 'outside'
        outside.mkdir()
        self.model_root.mkdir()
        (self.model_root / 'asr').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(setup.DownloadError):
            self.engine().run(download=True)
        self.assertEqual([], list(outside.iterdir()))

    def child(self, catalog, url, *, mode='--progress-json'):
        fixture = Path(self.temp.name) / 'catalog.json'
        fixture.write_text(json.dumps(catalog))
        # Explicit fixture injection at the library boundary; production CLI has no URL/root override.
        program = '''import importlib.util,json,sys,urllib.request
from pathlib import Path
spec=importlib.util.spec_from_file_location("fixture_setup",sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
root=Path(sys.argv[2]); catalog=json.loads(Path(sys.argv[3]).read_text()); fixture_url=sys.argv[4]
def opener(request,timeout=15):
    return urllib.request.urlopen(urllib.request.Request(fixture_url,headers=dict(request.header_items())),timeout=timeout)
sys.exit(module.main([sys.argv[5]],catalog=catalog,model_root=root,opener=opener))
'''
        return subprocess.Popen([sys.executable, '-u', '-c', program, str(SOURCE), str(self.model_root),
                                 str(fixture), url, mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_real_process_json_success_and_hash_failure_exit(self):
        with http_fixture(self.data) as (url, _):
            child = self.child(catalog_for(self.data), url)
            stdout, stderr = child.communicate(timeout=10)
        self.assertEqual(0, child.returncode, stderr)
        events = [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual('complete', events[-1]['type'])
        for event in events:
            self.assert_snapshot(event)
        # Fresh root, same real entry point, corrupt actual HTTP body.
        self.model_root = Path(self.temp.name) / 'failed-models'
        with http_fixture(b'x' * len(self.data)) as (url, _):
            child = self.child(catalog_for(self.data), url)
            stdout, stderr = child.communicate(timeout=10)
        self.assertNotEqual(0, child.returncode)
        events = [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual('error', events[-1]['type'])
        self.assertIn('校验', events[-1]['message'])
        self.assertFalse((self.model_root / 'asr/weights.bin').exists())
        self.assertEqual('', stderr)

    def test_real_sigterm_emits_cancelled_exit130_retains_partial(self):
        data = self.data * 4
        with http_fixture(data, slow=True) as (url, _):
            child = self.child(catalog_for(data), url)
            seen = []
            while True:
                line = child.stdout.readline()
                self.assertTrue(line, 'Child ended before first received bytes')
                event = json.loads(line)
                seen.append(event)
                if event['models'][0]['phase'] == 'downloading' and event['models'][0]['completedBytes'] > 0:
                    break
            child.send_signal(signal.SIGTERM)
            stdout, stderr = child.communicate(timeout=5)
        self.assertEqual(130, child.returncode, stderr)
        events = seen + [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual('cancelled', events[-1]['type'])
        partial = self.model_root / 'asr/weights.bin.partial'
        self.assertTrue(0 < partial.stat().st_size < len(data))
        self.assertFalse((self.model_root / 'asr/weights.bin').exists())

    def test_invalid_catalog_json_error_contains_all_models(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = setup.main(['--status-json'], catalog={'schemaVersion': 2}, model_root=self.model_root)
        self.assertEqual(1, code)
        event = json.loads(output.getvalue())
        self.assertEqual('error', event['type'])
        self.assert_snapshot(event)
        self.assertFalse(self.model_root.exists())

    def test_no_arguments_preserve_legacy_installer_entry(self):
        # Keep this isolated from the real model directory and its original network installer.
        with mock.patch.object(setup, 'MODEL_ROOT', self.model_root), mock.patch.object(setup, 'legacy_main') as legacy:
            self.assertEqual(0, setup.main([]))
        legacy.assert_called_once_with()

    def test_legacy_sensevoice_verified_files_still_reuse_offline(self):
        directory = Path(self.temp.name) / 'legacy'
        directory.mkdir()
        expected = {name: (len(self.data), hashlib.sha256(self.data).hexdigest()) for name in setup.ASR_FILES}
        for name in expected:
            (directory / name).write_bytes(self.data)
        with mock.patch.object(setup, 'ASR_FILES', expected), mock.patch.object(urllib.request, 'urlopen', side_effect=AssertionError('Network forbidden')):
            setup.ensure_sensevoice(directory)


if __name__ == '__main__':
    unittest.main()
