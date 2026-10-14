#!/usr/bin/env python3
"""Prepare pinned public models locally. This is the only model-download entry point."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import re
import signal
import stat
import sys
import shutil
import tarfile
import tempfile
import threading
import urllib.request
from urllib.parse import urlsplit
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL_ROOT = ROOT / 'models'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
os.environ['DO_NOT_TRACK'] = '1'
os.environ['HF_HUB_DISABLE_XET'] = '1'

MODELS = [
    ('mlx-community/Qwen3-4B-Instruct-2507-4bit', '50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b', 'qwen3-4b',
     ['*.json', '*.safetensors', '*.txt', '*.jinja', 'README.md']),
    ('Qdrant/bge-small-zh-v1.5', '46fbe35fd4374a00fee7de77dfddaeb6dd6a2c59', 'bge-small-zh',
     ['*.json', '*.onnx', '*.txt', 'README.md']),
]

ASR_FILES = {
    'model.int8.onnx': (239233841, 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51'),
    'tokens.txt': (315894, 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc'),
    'silero_vad.onnx': (643854, '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6'),
}


def valid_model(path, name):
    size, digest = ASR_FILES[name]
    if not path.is_file() or path.stat().st_size != size:
        return False
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() == digest


def ensure_sensevoice(destination, source=None):
    """Reuse verified own models; a previous shim checkout is only an optional fast source."""
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    if source:
        source = Path(source)
        for name in ASR_FILES:
            current = destination / name
            if valid_model(current, name):
                continue
            candidate = source / name if name == 'silero_vad.onnx' else source / 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17' / name
            if valid_model(candidate, name):
                temporary = destination / (name + '.preparing')
                shutil.copyfile(candidate, temporary)
                if not valid_model(temporary, name):
                    raise RuntimeError('复制模型时校验失败：' + name)
                temporary.replace(current)
    missing = [name for name in ASR_FILES if not valid_model(destination / name, name)]
    if not missing:
        return
    if any(name != 'silero_vad.onnx' for name in missing):
        url = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2'
        print('从官方发布下载并验证 SenseVoice。', flush=True)
        with tempfile.TemporaryDirectory(prefix='.asr-download-', dir=destination) as temp:
            archive = Path(temp) / 'sensevoice.tar.bz2'
            with urllib.request.urlopen(url, timeout=60) as response, archive.open('wb') as out:
                shutil.copyfileobj(response, out, length=1024 * 1024)
            # Never extract arbitrary archive paths, only the two explicitly named files.
            with tarfile.open(archive) as tar:
                for name in ('model.int8.onnx', 'tokens.txt'):
                    if valid_model(destination / name, name):
                        continue
                    member_name = 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/' + name
                    member = tar.getmember(member_name)
                    if not member.isfile() or member.size != ASR_FILES[name][0]:
                        raise RuntimeError('官方模型包中的文件不符合预期：' + name)
                    temporary = destination / (name + '.preparing')
                    with tar.extractfile(member) as original, temporary.open('wb') as out:
                        shutil.copyfileobj(original, out, length=1024 * 1024)
                    if not valid_model(temporary, name):
                        temporary.unlink(missing_ok=True)
                        raise RuntimeError('模型 SHA-256 不符：' + name)
                    temporary.replace(destination / name)
    if not valid_model(destination / 'silero_vad.onnx', 'silero_vad.onnx'):
        url = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx'
        temporary = destination / 'silero_vad.onnx.preparing'
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open('wb') as out:
            shutil.copyfileobj(response, out, length=1024 * 1024)
        if not valid_model(temporary, 'silero_vad.onnx'):
            temporary.unlink(missing_ok=True)
            raise RuntimeError('VAD 模型 SHA-256 不符，请核查官方发布。')
        temporary.replace(destination / 'silero_vad.onnx')


def legacy_main(model_root=None):
    """Retain the existing full command-line installer and license collection."""
    from huggingface_hub import snapshot_download
    destination_root = Path(model_root) if model_root is not None else MODEL_ROOT
    destination_root.mkdir(parents=True, exist_ok=True)
    manifest = []
    for repo, revision, folder, patterns in MODELS:
        destination = destination_root / folder
        print(f'下载 {repo} 到 {destination}', flush=True)
        snapshot_download(repo, revision=revision, local_dir=destination,
                          allow_patterns=patterns, max_workers=3, token=False)
        manifest.append({'repo': repo, 'revision': revision, 'folder': folder})
    source = Path.home() / '我的项目仓库/Foresight中文支持/models/sensevoice'
    voice = destination_root / 'sensevoice'
    ensure_sensevoice(voice, source)
    manifest.append({'repo': 'k2-fsa/sherpa-onnx asr-models', 'folder': 'sensevoice',
                     'package': 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17',
                     'source': 'https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models',
                     'weights_license': 'FunASR MODEL_LICENSE',
                     'weights_license_url': 'https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE'})
    notices = {
        'Qwen-APACHE-2.0.txt': 'https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507/resolve/main/LICENSE',
        'BGE-MIT.txt': 'https://raw.githubusercontent.com/FlagOpen/FlagEmbedding/master/LICENSE',
        'SenseVoice-MODEL_LICENSE.txt': 'https://raw.githubusercontent.com/modelscope/FunASR/main/MODEL_LICENSE',
        'Sherpa-APACHE-2.0.txt': 'https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/LICENSE',
        'Silero-MIT.txt': 'https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE',
    }
    licenses = destination_root / 'licenses' if model_root is not None else ROOT / 'docs/licenses'
    licenses.mkdir(parents=True, exist_ok=True)
    for name, url in notices.items():
        try:
            data = urllib.request.urlopen(url, timeout=30).read()
            (licenses / name).write_bytes(data)
        except Exception as error:
            print(f'许可文本获取失败 {url}: {error}', flush=True)
    for item in manifest:
        item['files'] = [
            {'path': str(path.relative_to(destination_root)), 'size': path.stat().st_size,
             'sha256': hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()}
            for path in sorted((destination_root / item['folder']).rglob('*'))
            if path.is_file() and '.cache' not in path.parts
        ]
    (destination_root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    print('模型准备完成。应用推理只读取这些本地文件。', flush=True)


class DownloadError(Exception):
    """A concise, user-readable preparation failure."""


class DownloadCancelled(Exception):
    pass


class CancellationToken:
    def __init__(self):
        self._cancelled = threading.Event()

    def cancel(self):
        self._cancelled.set()

    def check(self):
        if self._cancelled.is_set():
            raise DownloadCancelled()


def safe_path(root, relative=''):
    """Never read/publish a model through symlinks outside the owned directory."""
    root = Path(root)
    if root.is_symlink():
        raise DownloadError('模型目录不能使用符号链接。')
    current = root
    for part in Path(relative).parts:
        current = current / part
        if current.is_symlink():
            raise DownloadError('模型文件路径不能使用符号链接。')
    return current


@contextmanager
def download_lock(root):
    root = safe_path(root)
    root.mkdir(parents=True, exist_ok=True)
    path = safe_path(root, '.download.lock')
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise DownloadError('另一项模型下载正在进行，请等待完成。') from error
        yield
    finally:
        # Keep the inode: unlinking a lock file permits a third process to bypass a waiter.
        os.close(descriptor)


def load_catalog():
    try:
        catalog = json.loads((ROOT / 'Resources/ModelCatalog.json').read_text())
    except (OSError, ValueError) as error:
        raise DownloadError('模型清单无法读取，请重新安装知会。') from error
    # Production never accepts an arbitrary repository, URL, or local path from the CLI.
    for model in catalog.get('models', []):
        for file in model.get('files', []):
            url = urlsplit(file.get('url', ''))
            if url.scheme != 'https' or url.hostname not in {'huggingface.co', 'github.com'} or url.username or url.password:
                raise DownloadError('模型清单中的下载来源无效。')
    return catalog


def validate_model_directory(model_root):
    """A bundled launcher must select writable storage outside its signed app."""
    selected = Path(model_root).resolve()
    for location in (ROOT, *ROOT.parents):
        if location.suffix.lower() == '.app':
            if selected.is_relative_to(location):
                raise DownloadError('模型目录必须位于应用之外，请重新安装知会。')
            break


class ModelDownloader:
    """Offline verified status plus cancellable, byte-counted pinned downloads.

    Catalog/opener injection exists only for library fixture tests. The CLI may choose
    its writable model directory but cannot alter the pinned production downloads.
    """
    CHUNK_SIZE = 64 * 1024
    IDS = ('asr', 'embedding', 'llm')

    def __init__(self, catalog, model_root, *, emit=None, opener=None, cancellation=None):
        self.root = Path(model_root).expanduser().absolute()
        self.emit = emit or (lambda event: None)
        self.opener = opener or urllib.request.urlopen
        self.cancellation = cancellation or CancellationToken()
        self.models = self._validate_catalog(catalog)
        self.valid_files = set()
        self.file_bytes = {}
        self.states = {model['id']: {'id': model['id'], 'name': model['name'], 'ready': False,
                                    'completedBytes': 0,
                                    'totalBytes': sum(file['size'] for file in model['files']),
                                    'phase': 'waiting'} for model in self.models}
        self.active_model = None

    @classmethod
    def _validate_catalog(cls, catalog):
        if not isinstance(catalog, dict) or catalog.get('schemaVersion') != 1:
            raise DownloadError('模型清单格式无效。')
        models = catalog.get('models')
        if not isinstance(models, list) or len(models) != 3 or {model.get('id') for model in models if isinstance(model, dict)} != set(cls.IDS):
            raise DownloadError('模型清单必须包含语音、检索和问答三个模型。')
        used = set()
        for model in models:
            folder = model.get('folder', '')
            if not isinstance(model.get('name'), str) or not model['name'] or not isinstance(folder, str) or not re.fullmatch(r'[a-zA-Z0-9_-]+', folder):
                raise DownloadError('模型清单中的名称或目录无效。')
            files = model.get('files')
            if not isinstance(files, list) or not files:
                raise DownloadError('模型清单缺少必要文件。')
            for file in files:
                if not isinstance(file, dict):
                    raise DownloadError('模型清单中的文件无效。')
                relative = file.get('path', '')
                if not isinstance(relative, str) or '\\' in relative:
                    raise DownloadError('模型清单中的文件路径无效。')
                parts = relative.split('/')
                if len(parts) < 2 or parts[0] != folder or any(part in ('', '.', '..') for part in parts) or relative in used:
                    raise DownloadError('模型清单中的文件路径无效或重复。')
                size = file.get('size')
                digest = file.get('sha256', '')
                url = file.get('url', '')
                if type(size) is not int or size <= 0 or not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
                    raise DownloadError('模型清单中的大小或校验值无效。')
                if not isinstance(url, str) or urlsplit(url).scheme not in ('https', 'http'):
                    raise DownloadError('模型清单中的下载来源无效。')
                used.add(relative)
        return sorted(models, key=lambda model: cls.IDS.index(model['id']))

    def snapshot(self, event_type, message=None):
        event = {'type': event_type, 'models': [self.states[ident].copy() for ident in self.IDS]}
        if self.active_model:
            event['activeModel'] = self.active_model
        if message:
            event['message'] = message
        self.emit(event)
        return event

    def _valid_file(self, file, *, partial=False):
        relative = file['path'] + ('.partial' if partial else '')
        path = safe_path(self.root, relative)
        if not path.is_file():
            return False
        if path.stat().st_size != file['size']:
            return False
        digest, total = hashlib.sha256(), 0
        with path.open('rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise DownloadError('模型路径必须是普通文件。')
            while True:
                self.cancellation.check()
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                digest.update(chunk)
        return total == file['size'] and digest.hexdigest() == file['sha256']

    def _update_completed(self, model):
        self.states[model['id']]['completedBytes'] = sum(self.file_bytes.get(file['path'], 0) for file in model['files'])

    def scan(self):
        self.snapshot('status')
        for model in self.models:
            self.active_model = model['id']
            state = self.states[model['id']]
            state.update(phase='checking', ready=False)
            self.snapshot('status')
            for file in model['files']:
                self.cancellation.check()
                if self._valid_file(file):
                    self.valid_files.add(file['path'])
                    self.file_bytes[file['path']] = file['size']
                else:
                    partial = safe_path(self.root, file['path'] + '.partial')
                    self.file_bytes[file['path']] = min(partial.stat().st_size, file['size']) if partial.is_file() else 0
                self._update_completed(model)
            ready = all(file['path'] in self.valid_files for file in model['files'])
            state.update(ready=ready, phase='ready' if ready else 'waiting')
            self.snapshot('status')
        self.active_model = None

    def _download_file(self, model, file):
        destination = safe_path(self.root, file['path'])
        destination.parent.mkdir(parents=True, exist_ok=True)
        partial = safe_path(self.root, file['path'] + '.partial')
        state = self.states[model['id']]
        state.update(ready=False, phase='checking')
        self.snapshot('progress')
        if self._valid_file(file, partial=True):
            os.replace(partial, destination)
            self.valid_files.add(file['path'])
            self.file_bytes[file['path']] = file['size']
            self._update_completed(model)
            return
        offset = partial.stat().st_size if partial.is_file() else 0
        # A full but invalid file cannot be resumed; retry from zero while preserving failure bytes until this retry.
        if offset >= file['size']:
            offset = 0
        headers = {'User-Agent': 'Zhihui-Model-Setup/1', 'Accept-Encoding': 'identity'}
        if offset:
            headers['Range'] = f'bytes={offset}-'
        self.cancellation.check()
        request = urllib.request.Request(file['url'], headers=headers)
        with self.opener(request, timeout=15) as response:
            status_code = response.getcode()
            if status_code == 206:
                match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
                if not match or int(match[1]) != offset or int(match[2]) != file['size'] - 1 or int(match[3]) != file['size']:
                    raise DownloadError('服务器的续传响应无效，请重试。')
            elif status_code == 200:
                # Server ignored Range: use its complete body, not append it to the partial.
                offset = 0
            else:
                raise DownloadError('下载服务器响应异常，请稍后重试。')
            expected_length = file['size'] - offset
            content_length = response.headers.get('Content-Length')
            if content_length is not None and (not content_length.isdecimal() or int(content_length) != expected_length):
                raise DownloadError('下载文件大小与模型清单不符。')
            descriptor = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, 'wb', buffering=0) as out:
                out.truncate(offset)
                out.seek(offset)
                state['phase'] = 'downloading'
                self.file_bytes[file['path']] = offset
                self._update_completed(model)
                self.snapshot('progress')
                while True:
                    self.cancellation.check()
                    chunk = response.read(self.CHUNK_SIZE)
                    if not chunk:
                        break
                    if offset + len(chunk) > file['size']:
                        raise DownloadError('下载文件超过预期大小，未启用该文件。')
                    written = 0
                    while written < len(chunk):
                        self.cancellation.check()
                        count = out.write(chunk[written:])
                        if not count:
                            raise DownloadError('模型文件写入失败，请检查可用空间。')
                        written += count
                    offset += written
                    self.file_bytes[file['path']] = offset
                    self._update_completed(model)
                    self.snapshot('progress')
                out.flush()
                os.fsync(out.fileno())
        self.cancellation.check()
        state['phase'] = 'checking'
        self.snapshot('progress')
        if not self._valid_file(file, partial=True):
            raise DownloadError('模型文件校验失败，请重试下载。')
        self.cancellation.check()
        os.replace(partial, destination)
        self.valid_files.add(file['path'])

    def run(self, *, download):
        if not download:
            self.scan()
            return self.snapshot('complete')
        with download_lock(self.root):
            self.scan()
            for model in self.models:
                if self.states[model['id']]['ready']:
                    continue
                self.active_model = model['id']
                for file in model['files']:
                    if file['path'] not in self.valid_files:
                        self._download_file(model, file)
                self.states[model['id']].update(ready=True, phase='ready')
                self._update_completed(model)
                self.snapshot('progress')
            self.active_model = None
            return self.snapshot('complete', '本地模型已准备完成。')


def fallback_snapshot(event_type, message):
    return {'type': event_type, 'models': [
        {'id': ident, 'name': name, 'ready': False, 'completedBytes': 0,
         'totalBytes': 0, 'phase': 'waiting'}
        for ident, name in [('asr', 'SenseVoice · 中文语音转写'),
                            ('embedding', 'BGE · 文件与会议检索'),
                            ('llm', 'Qwen3 · 中文纪要与问答')]
    ], 'message': message}


def main(argv=None, *, catalog=None, model_root=None, opener=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--status-json', action='store_true', help='离线校验模型；只输出 NDJSON 状态')
    mode.add_argument('--progress-json', action='store_true', help='下载缺失模型；输出真实字节 NDJSON 进度')
    parser.add_argument('--model-dir', type=Path, help='可写的模型与下载缓存目录；默认使用项目 models 目录')
    args = parser.parse_args(argv)
    selected_root = (Path(model_root) if model_root is not None else args.model_dir or MODEL_ROOT).expanduser().absolute()
    os.environ['HF_HOME'] = str(selected_root / '.hf-cache')
    if not args.status_json and not args.progress_json:
        validate_model_directory(selected_root)
        with download_lock(selected_root):
            if model_root is not None or args.model_dir is not None:
                legacy_main(selected_root)
            else:
                legacy_main()
        return 0

    def emit(event):
        print(json.dumps(event, ensure_ascii=False, separators=(',', ':')), flush=True)

    engine = None
    token = CancellationToken()
    previous_handlers = {}

    def cancel_signal(_signum, _frame):
        token.cancel()
        # Interrupt blocking HTTPS reads too; context managers retain the existing partial.
        raise DownloadCancelled()

    try:
        validate_model_directory(selected_root)
        for number in (signal.SIGTERM, signal.SIGINT):
            previous_handlers[number] = signal.signal(number, cancel_signal)
        engine = ModelDownloader(catalog if catalog is not None else load_catalog(),
                                 selected_root,
                                 emit=emit, opener=opener, cancellation=token)
        engine.run(download=args.progress_json)
        return 0
    except DownloadCancelled:
        if engine is not None:
            engine.snapshot('cancelled', '下载已暂停，已接收的文件保留，可继续下载。')
        else:
            emit(fallback_snapshot('cancelled', '模型检查已暂停。'))
        return 130
    except Exception as error:
        message = str(error) if isinstance(error, DownloadError) else '模型准备失败，请检查网络和可用空间后重试。'
        if engine is not None:
            engine.snapshot('error', message)
        else:
            emit(fallback_snapshot('error', message))
        return 1
    finally:
        for number, previous in previous_handlers.items():
            signal.signal(number, previous)


if __name__ == '__main__':
    sys.exit(main())
