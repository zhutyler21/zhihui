"""Independent on-device inference. No Foresight code or network AI calls."""
from __future__ import annotations

import os
import logging
import re
import selectors
import shutil
import subprocess
import threading
import time
from pathlib import Path


class LocalModels:
    def __init__(self, root: Path, model_root: Path | None = None, ffmpeg: Path | str | None = None):
        self.root = Path(root).resolve()
        self.models = self.model_directory(self.root, model_root)
        self.ffmpeg_path = self.ffmpeg_executable(ffmpeg, root=self.root)
        os.environ['HF_HOME'] = str(self.models / '.hf-cache')
        os.environ['HF_HUB_OFFLINE'] = '1'
        os.environ['TRANSFORMERS_OFFLINE'] = '1'
        os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
        os.environ['DO_NOT_TRACK'] = '1'
        os.environ['TOKENIZERS_PARALLELISM'] = 'false'
        self._asr = None
        self._embedding = None
        self._llm = None
        self._tokenizer = None
        self._asr_lock = threading.Lock()
        self._embed_lock = threading.Lock()
        self._llm_lock = threading.Lock()

    @staticmethod
    def app_bundle(root: Path) -> Path | None:
        root = Path(root).resolve()
        return next((location for location in (root, *root.parents) if location.suffix.lower() == '.app'), None)

    @staticmethod
    def model_directory(root: Path, explicit: Path | None = None) -> Path:
        root = Path(root).resolve()
        selected = Path(explicit).expanduser().resolve() if explicit is not None else root / 'models'
        bundle = LocalModels.app_bundle(root)
        if bundle is not None and selected.is_relative_to(bundle):
            raise RuntimeError('模型目录必须位于应用之外，请重新安装知会。')
        return selected

    @staticmethod
    def ffmpeg_executable(explicit: Path | str | None = None, *, root: Path | None = None) -> str:
        # A supplied bundle executable must never fall back to a different system install.
        if explicit is None and root is not None:
            if LocalModels.app_bundle(root) is not None:
                raise RuntimeError('应用内音频工具未配置，请重新安装知会。')
        selected = explicit if explicit is not None else shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
        return str(Path(selected).expanduser().resolve())

    def status(self) -> dict:
        return {
            'asr': {'name': 'SenseVoice 中文转写',
                    'ready': all((self.models / 'sensevoice' / name).is_file()
                                 for name in ('model.int8.onnx', 'tokens.txt', 'silero_vad.onnx')),
                    'loaded': self._asr is not None},
            'embedding': {'name': 'BGE 中文语义检索',
                          'ready': (self.models / 'bge-small-zh/model_optimized.onnx').is_file(),
                          'loaded': self._embedding is not None},
            'llm': {'name': '千问 Qwen3 4B · 本地',
                    'ready': (self.models / 'qwen3-4b/model.safetensors').is_file(),
                    'loaded': self._llm is not None},
        }

    @staticmethod
    def _check_cancel(cancel_event):
        if cancel_event is not None and cancel_event.is_set():
            raise RuntimeError('操作已取消')

    @staticmethod
    def _wait_lock(lock, cancel_event=None):
        while not lock.acquire(timeout=0.2):
            LocalModels._check_cancel(cancel_event)
        try:
            LocalModels._check_cancel(cancel_event)
        except Exception:
            lock.release()
            raise

    def embed(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        if not self.status()['embedding']['ready']:
            raise RuntimeError('本地检索模型未准备，请运行项目的模型安装脚本。')
        with self._embed_lock:
            if self._embedding is None:
                from fastembed import TextEmbedding
                self._embedding = TextEmbedding(
                    model_name='BAAI/bge-small-zh-v1.5',
                    specific_model_path=str(self.models / 'bge-small-zh'),
                    cache_dir=str(self.models / '.embedding-cache'),
                    local_files_only=True, threads=3,
                    providers=['CPUExecutionProvider'],
                )
            return [vector.tolist() for vector in self._embedding.embed(texts, batch_size=24)]

    def transcribe(self, path: str, cancel_event=None) -> dict:
        self._check_cancel(cancel_event)
        audio = Path(path).expanduser().resolve()
        if not audio.is_file():
            raise RuntimeError('找不到音频文件。')
        if not self.status()['asr']['ready']:
            raise RuntimeError('本地转写模型未准备，请运行项目的模型安装脚本。')
        ffmpeg = self.ffmpeg_path
        if not Path(ffmpeg).is_file() or not os.access(ffmpeg, os.X_OK):
            if self.app_bundle(self.root) is not None:
                raise RuntimeError('音频转换工具无法运行，请重新安装知会。')
            raise RuntimeError('音频转换工具未安装。请先安装 ffmpeg。')
        # Stream audio decoding to bound memory and allow cancellation on long files.
        process = subprocess.Popen(
            [ffmpeg, '-nostdin', '-v', 'error', '-protocol_whitelist', 'file,pipe',
             '-i', str(audio), '-vn', '-ac', '1',
             '-ar', '16000', '-f', 'f32le', '-'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            self._wait_lock(self._asr_lock, cancel_event)
            try:
                import numpy as np
                import sherpa_onnx
                if self._asr is None:
                    self._asr = sherpa_onnx.OfflineRecognizer.from_sense_voice(
                        model=str(self.models / 'sensevoice/model.int8.onnx'),
                        tokens=str(self.models / 'sensevoice/tokens.txt'),
                        num_threads=3, language='auto', use_itn=True, provider='cpu',
                    )
                config = sherpa_onnx.VadModelConfig()
                config.silero_vad.model = str(self.models / 'sensevoice/silero_vad.onnx')
                config.silero_vad.threshold = 0.5
                config.silero_vad.min_silence_duration = 0.45
                config.silero_vad.min_speech_duration = 0.2
                config.silero_vad.max_speech_duration = 20
                config.sample_rate = 16000
                config.num_threads = 1
                vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=90)
                pending = np.array([], dtype=np.float32)
                texts, count, languages = [], 0, []
                utterances = []
                selector = selectors.DefaultSelector()
                selector.register(process.stdout, selectors.EVENT_READ, 'audio')
                selector.register(process.stderr, selectors.EVENT_READ, 'error')
                error_bytes = bytearray()
                raw_pending = b''
                last_audio = time.monotonic()

                def drain():
                    while not vad.empty():
                        self._check_cancel(cancel_event)
                        speech = vad.front
                        stream = self._asr.create_stream()
                        stream.accept_waveform(16000, speech.samples)
                        self._asr.decode_stream(stream)
                        result = stream.result
                        text = re.sub(r'<\|[^|]+\|>', '', result.text).strip()
                        if text:
                            texts.append(text)
                            utterances.append({'text': text, 'start_seconds': speech.start / 16000,
                                               'end_seconds': (speech.start + len(speech.samples)) / 16000})
                            language = getattr(result, 'lang', '') or ''
                            languages.append(language.replace('<|', '').replace('|>', ''))
                        vad.pop()

                try:
                    while selector.get_map():
                        self._check_cancel(cancel_event)
                        if time.monotonic() - last_audio > 30:
                            raise RuntimeError('音频解码长时间没有进展，请检查文件后重试。')
                        for key, _ in selector.select(timeout=0.2):
                            self._check_cancel(cancel_event)
                            raw = os.read(key.fileobj.fileno(), 65536)
                            if not raw:
                                selector.unregister(key.fileobj)
                                continue
                            if key.data == 'error':
                                # Drain the pipe continuously, while bounding retained diagnostics.
                                error_bytes.extend(raw[:max(0, 4096 - len(error_bytes))])
                                continue
                            last_audio = time.monotonic()
                            raw_pending += raw
                            usable = len(raw_pending) // 4 * 4
                            values = np.frombuffer(raw_pending[:usable], dtype=np.float32)
                            raw_pending = raw_pending[usable:]
                            if not np.isfinite(values).all():
                                raise RuntimeError('音频包含无效采样数据。')
                            count += len(values)
                            pending = np.concatenate((pending, values))
                            window = config.silero_vad.window_size
                            while len(pending) >= window:
                                vad.accept_waveform(pending[:window])
                                pending = pending[window:]
                                drain()
                    if raw_pending:
                        raise RuntimeError('音频解码数据不完整。')
                finally:
                    selector.close()
                if len(pending):
                    vad.accept_waveform(np.pad(pending, (0, config.silero_vad.window_size - len(pending))))
                vad.flush()
                drain()
                code = process.wait(timeout=10)
                if code:
                    logging.getLogger(__name__).warning('音频解码失败：%s', bytes(error_bytes[:800]).decode(errors='replace'))
                    raise RuntimeError('无法读取此音频，文件可能损坏或格式不受支持。请换一个音频文件重试。')
                self._check_cancel(cancel_event)
                for utterance in utterances:
                    utterance['end_seconds'] = min(utterance['end_seconds'], count / 16000)
                return {'text': '\n'.join(texts), 'duration_seconds': count / 16000,
                        'language': next((x for x in languages if x), 'auto'), 'utterances': utterances}
            finally:
                self._asr_lock.release()
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            process.stdout.close()
            process.stderr.close()

    def generate(self, prompt: str, system: str, on_chunk=None, cancel_event=None,
                 max_tokens=1600) -> str:
        self._check_cancel(cancel_event)
        if not self.status()['llm']['ready']:
            raise RuntimeError('本地语言模型未准备，请运行项目的模型安装脚本。')
        self._wait_lock(self._llm_lock, cancel_event)
        try:
            from mlx_lm import load, stream_generate
            from mlx_lm.sample_utils import make_sampler
            import mlx.core as mx
            if self._llm is None:
                self._llm, self._tokenizer = load(str(self.models / 'qwen3-4b'))
            self._check_cancel(cancel_event)
            messages = [
                {'role': 'system', 'content': system + '\n请使用自然、准确的简体中文。资料缺失时明确说明。'},
                {'role': 'user', 'content': prompt},
            ]
            formatted = self._tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True,
            )
            # A bounded context protects a local desktop from unbounded file input.
            if len(self._tokenizer.encode(formatted)) > 24000:
                raise RuntimeError('本次参考内容过长，请缩小范围后重试。')
            iterator = stream_generate(self._llm, self._tokenizer, formatted,
                                       max_tokens=min(max(int(max_tokens), 16), 4096),
                                       sampler=make_sampler(temp=0.15, top_p=0.85),
                                       prefill_step_size=512,
                                       prompt_progress_callback=lambda done, total: self._check_cancel(cancel_event))
            parts = []
            try:
                for response in iterator:
                    self._check_cancel(cancel_event)
                    parts.append(response.text)
                    if on_chunk:
                        on_chunk(response.text)
            finally:
                iterator.close()
                mx.clear_cache()
            self._check_cancel(cancel_event)
            return ''.join(parts).strip()
        finally:
            self._llm_lock.release()
