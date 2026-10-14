import tempfile
import unittest
from pathlib import Path

from backend.engines import LocalModels

FIXTURES = Path(__file__).resolve().parents[1] / 'work' / 'engine-unit-fixtures'
FIXTURES.mkdir(parents=True, exist_ok=True)


class OfflineEngineContract(unittest.TestCase):
    def test_missing_models_are_visible_and_do_not_download(self):
        with tempfile.TemporaryDirectory(dir=FIXTURES) as temp:
            model = LocalModels(Path(temp))
            status = model.status()
            for name in ('asr', 'embedding', 'llm'):
                self.assertFalse(status[name]['ready'])
                self.assertFalse(status[name]['loaded'])
            with self.assertRaisesRegex(RuntimeError, '检索模型'):
                model.embed(['预算'])
            with self.assertRaisesRegex(RuntimeError, '语言模型'):
                model.generate('你好', '请用中文回答')

    def test_cancel_before_model_loading(self):
        import threading
        with tempfile.TemporaryDirectory(dir=FIXTURES) as temp:
            event = threading.Event()
            event.set()
            with self.assertRaisesRegex(RuntimeError, '取消'):
                LocalModels(Path(temp)).generate('你好', '中文', cancel_event=event)

    def test_cancel_while_acquiring_does_not_leak_lock(self):
        import threading
        event = threading.Event()
        class Lock:
            released = False
            def acquire(self, timeout):
                event.set()
                return True
            def release(self):
                self.released = True
        lock = Lock()
        with self.assertRaisesRegex(RuntimeError, '取消'):
            LocalModels._wait_lock(lock, event)
        self.assertTrue(lock.released)


if __name__ == '__main__':
    unittest.main()
