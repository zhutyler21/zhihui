"""Guarded path contracts: real HTTP bytes and processes, without model inference."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
import urllib.request
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = Path('/Users/zhutyler21/我的项目仓库/知会本地会议')
if ROOT.resolve() != EXPECTED.resolve() or not (ROOT / 'backend/server.py').is_file():
    raise RuntimeError('Wrong canonical project root for standalone runtime tests')
WORK = ROOT / 'work/standalone-python/fixtures'
if not WORK.resolve().is_relative_to(ROOT / 'work') or any(path.is_symlink() for path in [WORK, WORK.parent, WORK.parent.parent]):
    raise RuntimeError('Standalone fixtures must stay inside the owned work directory')
WORK.mkdir(parents=True, exist_ok=True)

# Product and fixture imports happen only after checking the isolated test root.
from backend.engines import LocalModels
from test_model_downloads import catalog_for, http_fixture


def tree_receipt(root):
    return {str(path.relative_to(root)): (path.stat().st_mode & 0o777,
            hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
            for path in root.rglob('*')}


def protect_tree(root, *, readonly):
    for path in sorted(root.rglob('*'), key=lambda path: len(path.parts), reverse=True):
        path.chmod((0o555 if path.is_dir() else 0o444) if readonly else (0o755 if path.is_dir() else 0o644))
    root.chmod(0o555 if readonly else 0o755)


class StandalonePaths(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='独立 运行-', dir=WORK)
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.code_root = self.path / '只读 程序.app/Contents/Resources/Runtime'
        self.code_root.mkdir(parents=True)
        self.models = self.path / '用户 资料/模型'
        environment_patch = mock.patch.dict(os.environ, {})
        environment_patch.start()
        self.addCleanup(environment_patch.stop)

    def readonly_code(self):
        protect_tree(self.code_root, readonly=True)
        self.addCleanup(protect_tree, self.code_root, readonly=False)
        self.assertEqual(0, self.code_root.stat().st_mode & 0o222)
        return tree_receipt(self.code_root)

    def helper_runtime(self):
        (self.code_root / 'scripts').mkdir()
        (self.code_root / 'Resources').mkdir()
        shutil.copyfile(ROOT / 'scripts/setup-models.py', self.code_root / 'scripts/setup-models.py')
        shutil.copyfile(ROOT / 'Resources/ModelCatalog.json', self.code_root / 'Resources/ModelCatalog.json')
        return self.code_root / 'scripts/setup-models.py'

    def ready_model_paths(self):
        for relative in ['sensevoice/model.int8.onnx', 'sensevoice/tokens.txt', 'sensevoice/silero_vad.onnx',
                         'bge-small-zh/model_optimized.onnx', 'qwen3-4b/model.safetensors']:
            path = self.models / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'path-contract fixture; not model weights')

    def fixture_ffmpeg(self):
        tool = self.path / '内置 音频工具/ffmpeg'
        tool.parent.mkdir()
        tool.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ZH_FIXTURE_TOOL_RECEIPT"\n')
        tool.chmod(0o755)
        return tool

    def test_default_development_model_root_is_preserved(self):
        models = LocalModels(self.path)
        self.assertEqual(self.path / 'models', models.models)
        self.assertEqual(str(self.path / 'models/.hf-cache'), os.environ['HF_HOME'])
        self.assertFalse(models.models.exists())

    def test_bundled_models_cannot_default_or_redirect_inside_signed_app(self):
        helper = self.helper_runtime()
        before = self.readonly_code()
        bundled_models = self.code_root.parent / 'models'
        for selected in [None, bundled_models]:
            with self.subTest(root=selected), self.assertRaisesRegex(RuntimeError, '应用之外'):
                LocalModels(self.code_root, model_root=selected)
        with mock.patch('backend.engines.shutil.which', side_effect=AssertionError('Bundled app cannot use PATH')):
            with self.assertRaisesRegex(RuntimeError, '音频工具未配置'):
                LocalModels(self.code_root, model_root=self.models)
        for args in [[], ['--model-dir', str(bundled_models)]]:
            with self.subTest(args=args):
                result = subprocess.run([sys.executable, '-B', str(helper), '--progress-json', *args],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(1, result.returncode, result.stderr)
                event = json.loads(result.stdout)
                self.assertEqual('error', event['type'])
                self.assertIn('应用之外', event['message'])
        self.assertFalse(bundled_models.exists())
        self.assertEqual(before, tree_receipt(self.code_root))

    def test_all_loaders_and_caches_use_external_root(self):
        self.ready_model_paths()
        tool = self.fixture_ffmpeg()
        before = self.readonly_code()
        captured = {}

        def embedding_factory(**kwargs):
            captured['embedding'] = kwargs
            cache = Path(kwargs['cache_dir'])
            cache.mkdir()
            (cache / 'fixture').write_bytes(b'external cache')
            return types.SimpleNamespace(embed=lambda texts, **options: [types.SimpleNamespace(tolist=lambda: [1.0, 0.0])])

        tokenizer = types.SimpleNamespace(apply_chat_template=lambda *args, **kwargs: 'fixture prompt', encode=lambda text: [1])

        def load_llm(path):
            captured['llm'] = path
            return object(), tokenizer

        def generated(*args, **kwargs):
            yield types.SimpleNamespace(text='合成路径测试')

        mlx = types.ModuleType('mlx')
        mlx.__path__ = []
        core = types.ModuleType('mlx.core')
        core.clear_cache = lambda: None
        mlx.core = core
        mlx_lm = types.ModuleType('mlx_lm')
        mlx_lm.__path__ = []
        mlx_lm.load, mlx_lm.stream_generate = load_llm, generated
        sampler = types.ModuleType('mlx_lm.sample_utils')
        sampler.make_sampler = lambda **kwargs: None
        with mock.patch.dict(sys.modules, {'fastembed': types.SimpleNamespace(TextEmbedding=embedding_factory),
                                         'mlx': mlx, 'mlx.core': core, 'mlx_lm': mlx_lm,
                                         'mlx_lm.sample_utils': sampler}):
            models = LocalModels(self.code_root, model_root=self.models, ffmpeg=tool)
            self.assertTrue(all(item['ready'] for item in models.status().values()))
            self.assertEqual([[1.0, 0.0]], models.embed(['合成资料']))
            self.assertEqual('合成路径测试', models.generate('合成问题', '合成系统'))
        self.assertEqual(str(self.models / 'bge-small-zh'), captured['embedding']['specific_model_path'])
        self.assertEqual(str(self.models / '.embedding-cache'), captured['embedding']['cache_dir'])
        self.assertTrue(captured['embedding']['local_files_only'])
        self.assertEqual(str(self.models / 'qwen3-4b'), captured['llm'])
        self.assertEqual(str(self.models / '.hf-cache'), os.environ['HF_HOME'])
        self.assertEqual('1', os.environ['HF_HUB_OFFLINE'])
        self.assertEqual('1', os.environ['TRANSFORMERS_OFFLINE'])
        self.assertEqual(before, tree_receipt(self.code_root))

    def test_explicit_ffmpeg_executes_selected_tool_and_external_asr_paths(self):
        self.ready_model_paths()
        tool = self.fixture_ffmpeg()
        receipt = self.path / 'selected-tool.txt'
        audio = self.path / '合成 声音.wav'
        audio.write_bytes(b'fixture; selected tool emits zero samples')
        before = self.readonly_code()
        captured = {}

        def recognizer(**kwargs):
            captured['asr'] = kwargs
            return object()

        def config():
            value = types.SimpleNamespace(silero_vad=types.SimpleNamespace(window_size=512))
            captured['vad_config'] = value
            return value

        sherpa = types.SimpleNamespace(OfflineRecognizer=types.SimpleNamespace(from_sense_voice=recognizer),
                                      VadModelConfig=config,
                                      VoiceActivityDetector=lambda *args, **kwargs: types.SimpleNamespace(empty=lambda: True, flush=lambda: None))
        with mock.patch.dict(os.environ, {'ZH_FIXTURE_TOOL_RECEIPT': str(receipt)}), \
                mock.patch.dict(sys.modules, {'sherpa_onnx': sherpa}), \
                mock.patch('backend.engines.shutil.which', side_effect=AssertionError('Explicit tool cannot use PATH')):
            models = LocalModels(self.code_root, model_root=self.models, ffmpeg=tool)
            result = models.transcribe(str(audio))
        self.assertEqual('', result['text'])
        self.assertEqual(0, result['duration_seconds'])
        self.assertIn(str(audio), receipt.read_text().splitlines())
        self.assertEqual(str(tool), models.ffmpeg_path)
        self.assertEqual(str(self.models / 'sensevoice/model.int8.onnx'), captured['asr']['model'])
        self.assertEqual(str(self.models / 'sensevoice/tokens.txt'), captured['asr']['tokens'])
        self.assertEqual(str(self.models / 'sensevoice/silero_vad.onnx'), captured['vad_config'].silero_vad.model)
        self.assertEqual(before, tree_receipt(self.code_root))

    def test_stale_or_nonexecutable_explicit_tool_never_falls_back(self):
        self.ready_model_paths()
        fallback = self.fixture_ffmpeg()
        audio = self.path / 'fixture.wav'
        audio.write_bytes(b'fixture')
        disabled = self.path / 'nonexecutable-ffmpeg'
        disabled.write_text('not executable')
        for supplied in [self.path / 'old-app/ffmpeg', disabled]:
            with self.subTest(path=str(supplied)), mock.patch('backend.engines.shutil.which', return_value=str(fallback)) as which, \
                    mock.patch('backend.engines.subprocess.Popen', side_effect=AssertionError('Invalid tool must not execute')):
                model = LocalModels(self.code_root, model_root=self.models, ffmpeg=supplied)
                with self.assertRaisesRegex(RuntimeError, '音频转换工具'):
                    model.transcribe(str(audio))
                which.assert_not_called()

    def test_production_helper_status_uses_readonly_catalog_and_external_models(self):
        helper = self.helper_runtime()
        before = self.readonly_code()
        result = subprocess.run([sys.executable, '-B', str(helper), '--status-json', '--model-dir', str(self.models)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual('complete', events[-1]['type'])
        self.assertEqual(['asr', 'embedding', 'llm'], [item['id'] for item in events[-1]['models']])
        self.assertFalse(any(item['ready'] for item in events[-1]['models']))
        self.assertFalse(self.models.exists())
        self.assertEqual(before, tree_receipt(self.code_root))

    def test_helper_cli_external_model_directory_http_resume_hash_and_readonly_root(self):
        helper = self.helper_runtime()
        before = self.readonly_code()
        data = bytes(range(256)) * 1025
        prefix = 79123
        partial = self.models / 'asr/weights.bin.partial'
        partial.parent.mkdir(parents=True)
        partial.write_bytes(data[:prefix])
        fixture = self.path / 'catalog-fixture.json'
        # Only this library test injects tiny weights and local URLs. The production
        # CLI retains its bundled pinned catalog and allows no URL/catalog override.
        program = '''import importlib.util,json,os,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("fixture_setup",sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
code=module.main(["--progress-json","--model-dir",sys.argv[2]],catalog=json.loads(Path(sys.argv[3]).read_text()))
Path(sys.argv[4]).write_text(os.environ["HF_HOME"])
sys.exit(code)
'''
        cache_receipt = self.path / 'cache-root.txt'
        with http_fixture(data) as (url, requests):
            fixture.write_text(json.dumps(catalog_for(data, url)))
            result = subprocess.run([sys.executable, '-B', '-c', program, str(helper), str(self.models), str(fixture), str(cache_receipt)],
                                    capture_output=True, text=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual('complete', events[-1]['type'])
        self.assertTrue(all(item['ready'] for item in events[-1]['models']))
        self.assertEqual(f'bytes={prefix}-', requests[0])
        self.assertEqual(3, len(requests))
        for ident in ('asr', 'embedding', 'llm'):
            self.assertEqual(data, (self.models / ident / 'weights.bin').read_bytes())
        self.assertTrue(any(0 < item['completedBytes'] < item['totalBytes']
                            for event in events for item in event['models'] if item['phase'] == 'downloading'))
        self.assertEqual(str(self.models / '.hf-cache'), cache_receipt.read_text())
        self.assertEqual(before, tree_receipt(self.code_root))

    def test_backend_cli_health_binds_code_models_data_and_tool(self):
        shutil.copytree(ROOT / 'backend', self.code_root / 'backend', ignore=shutil.ignore_patterns('__pycache__'))
        before = self.readonly_code()
        tool = self.fixture_ffmpeg()
        data = self.path / '用户 资料/会议'
        token = data / 'api-token'
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', HOME=str(self.path / '隔离 用户'))
        child = subprocess.Popen([sys.executable, '-B', '-u', '-m', 'backend.server', '--port', '0', '--data-dir', str(data),
                                  '--token-file', str(token), '--models-dir', str(self.models), '--ffmpeg', str(tool)],
                                 cwd=self.code_root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(timeout=10), 'Backend failed to announce its isolated port')
                line = child.stdout.readline().strip()
            self.assertIn('127.0.0.1:', line)
            port = int(line.rsplit(':', 1)[1])
            request = urllib.request.Request(f'http://127.0.0.1:{port}/api/health',
                                             headers={'Authorization': 'Bearer ' + token.read_text().strip()})
            with urllib.request.urlopen(request, timeout=5) as response:
                health = json.load(response)
            self.assertEqual(str(self.code_root), health['project_root'])
            self.assertEqual(str(self.models), health['models_dir'])
            self.assertEqual(str(data), health['data_dir'])
            self.assertEqual(str(tool), health['ffmpeg_path'])
            self.assertFalse(any(item['ready'] for item in health['models'].values()))
            self.assertFalse(self.models.exists())
            self.assertTrue((data / 'database.sqlite').is_file())
            self.assertEqual(before, tree_receipt(self.code_root))
        finally:
            if child.poll() is None:
                child.terminate()
            stdout, stderr = child.communicate(timeout=10)
        self.assertEqual(0, child.returncode, stderr)


if __name__ == '__main__':
    unittest.main()
