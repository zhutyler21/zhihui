#!/usr/bin/env python3
"""Verify the installed Cantonese ASR with synthetic audio and isolated data.

No daily meetings or hardware permissions are used. Supply an owned test AIFF
under project work/ with the documented Cantonese fixture (budget 31472).
Model bytes are verified and cloned, without downloading.
"""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import os
import plistlib
import re
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio', type=Path, required=True)
    parser.add_argument('--app', type=Path, default=Path.home() / 'Applications/知会.app')
    args = parser.parse_args()
    assert ROOT == Path('/Users/zhutyler21/我的项目仓库/知会本地会议').resolve()
    audio = args.audio.resolve()
    assert audio.is_relative_to(ROOT / 'work') and audio.is_file()
    app = args.app.resolve(); rt = app / 'Contents/Resources/Runtime'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'io.local.zhihui.meetings'
    assert info['ZhihuiRuntimeLayout'] == 'bundled-v1'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    run = ROOT / 'work/cantonese-20261016' / ('run-' + uuid.uuid4().hex)
    run.mkdir(parents=True, mode=0o700)
    assert run.resolve().is_relative_to(ROOT / 'work/cantonese-20261016')
    data = run / 'data'; models = run / 'models'; data.mkdir(mode=0o700); models.mkdir(mode=0o700)
    report = {'pass': False, 'run': str(run), 'version': info['CFBundleShortVersionString'],
              'build': info['CFBundleVersion'], 'binary_sha256': sha(app / 'Contents/MacOS/知会'),
              'audio_sha256': sha(audio), 'cases': []}
    process = None
    try:
        catalog = json.loads((rt / 'Resources/ModelCatalog.json').read_text())
        files = [item for model in catalog['models'] for item in model['files']]
        assert len(files) == 23
        for item in files:
            rel = PurePosixPath(item['path'])
            assert not rel.is_absolute() and '..' not in rel.parts
            source = ROOT / 'models' / item['path']; target = models / item['path']
            assert source.stat().st_size == item['size'] and sha(source) == item['sha256']
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['/bin/cp', '-c', str(source), str(target)], check=True)
        profile = run / 'offline.sb'
        daily = str(Path.home() / 'Library/Application Support/知会')
        profile.write_text('(version 1)\n(allow default)\n'
            '(deny file-read* (subpath ' + json.dumps(daily, ensure_ascii=False) + '))\n'
            '(deny file-write* (subpath ' + json.dumps(str(app), ensure_ascii=False) + '))\n'
            '(deny network-outbound)\n(allow network-outbound (remote ip "localhost:*"))\n')
        environment = {'PATH': str(rt / 'bin') + ':/usr/bin:/bin', 'HOME': str(run / 'home'),
            'TMPDIR': str(run / 'tmp'), 'LANG': 'en_US.UTF-8', 'HF_HUB_OFFLINE': '1',
            'TRANSFORMERS_OFFLINE': '1', 'HF_HUB_DISABLE_TELEMETRY': '1',
            'SSL_CERT_FILE': str(rt / 'python/lib/python3.12/site-packages/certifi/cacert.pem')}
        Path(environment['HOME']).mkdir(); Path(environment['TMPDIR']).mkdir()
        command = ['/usr/bin/sandbox-exec', '-f', str(profile), str(rt / 'python/bin/python3'), '-I', '-B', '-u']
        probe = subprocess.run([*command, '-c', 'import socket\ntry: socket.create_connection(("1.1.1.1",443),timeout=1); raise AssertionError("network allowed")\nexcept PermissionError: pass'], env=environment, capture_output=True)
        assert probe.returncode == 0, probe.stderr.decode()
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0)); port = listener.getsockname()[1]
        assert port != 8768
        report['port'] = port
        token = data / 'api-token'
        with (run / 'backend.log').open('w') as log:
            process = subprocess.Popen([*command, str(rt / 'scripts/run-backend.py'), '--port', str(port),
                '--data-dir', str(data), '--token-file', str(token), '--models-dir', str(models),
                '--ffmpeg', str(rt / 'bin/ffmpeg')], env=environment, cwd=run, stdout=log, stderr=subprocess.STDOUT)

        def api(route, payload=None, method=None):
            request = urllib.request.Request(f'http://127.0.0.1:{port}' + route,
                method=method or ('GET' if payload is None else 'POST'),
                headers={'Authorization': 'Bearer ' + token.read_text().strip(), 'Content-Type': 'application/json'},
                data=None if payload is None else json.dumps(payload).encode())
            return json.load(urllib.request.urlopen(request, timeout=10))

        def job(route, payload):
            start = time.monotonic(); jid = api(route, payload)['job_id']
            while time.monotonic() - start < 180:
                record = api('/api/jobs/' + jid)
                if record['state'] == 'done':
                    return record['result'], round(time.monotonic() - start, 3)
                assert record['state'] not in ('error', 'cancelled'), record
                time.sleep(0.1)
            raise TimeoutError('Cantonese model job exceeded 180 seconds')

        for _ in range(120):
            assert process.poll() is None, (run / 'backend.log').read_text()
            try:
                health = api('/api/health'); break
            except (OSError, ValueError):
                time.sleep(0.25)
        else:
            raise TimeoutError('Packaged backend did not start')
        assert health['app'] == 'zhihui' and health['project_root'] == str(rt)
        assert health['data_dir'] == str(data) and health['models_dir'] == str(models)
        assert health['ffmpeg_path'] == str(rt / 'bin/ffmpeg')
        assert all(health['models'][key]['ready'] for key in ('asr', 'llm', 'embedding'))
        report['health'] = health
        meetings = {lang: api('/api/meetings', {'title': '合成粤语验收-' + lang}) for lang in ('yue', 'auto')}
        assert len({m['id'] for m in meetings.values()}) == 2
        assert all(m['id'] and m['title'] == '合成粤语验收-' + lang for lang, m in meetings.items())
        for language, meeting in meetings.items():
            mid = meeting['id']
            api(f'/api/meetings/{mid}/translation-settings', {'source_language': language, 'enabled': False}, 'PATCH')
            result, asr_seconds = job(f'/api/meetings/{mid}/transcribe', {'path': str(audio), 'request_id': 'synthetic-' + language})
            assert result['text'].strip() and result['duration_seconds'] > 0
            assert result['language'] == 'yue', result
            # Cantonese ITN may preserve correct spoken Chinese numerals.
            assert any(amount in result['text'].replace(',', '') for amount in ('31472', '三万一千四百七十二', '三萬一千四百七十二')), result
            assert '陈小姐' in result['text'] or '陳小姐' in result['text'], result
            assert '十一月九' in result['text'] or '11月9' in result['text'], result
            summary, summary_seconds = job(f'/api/meetings/{mid}/summarize', {})
            assert any(amount in summary['summary'].replace(',', '') for amount in ('31472', '三万一千四百七十二', '三萬一千四百七十二')), summary
            assert '陈小姐' in summary['summary'] or '陳小姐' in summary['summary'], summary
            assert '十一月九' in summary['summary'] or '11月9' in summary['summary'], summary
            assert all(q in result['text'] for q in re.findall(r'「([^」]+)」', summary['summary']))
            exported = api(f'/api/meetings/{mid}/export')['markdown']
            assert result['text'] in exported and summary['summary'] in exported
            detail = api(f'/api/meetings/{mid}')
            assert detail['translation']['source_language'] == language and not detail['translation']['enabled']
            assert len(detail['segments']) == 1
            case = {'source_language': language, 'meeting_id': mid, 'asr_seconds': asr_seconds,
                    'summary_seconds': summary_seconds, 'transcript': result['text'], 'summary': summary['summary']}
            report['cases'].append(case); print(json.dumps(case, ensure_ascii=False), flush=True)
        report['pass'] = True
    finally:
        if process is not None and process.poll() is None:
            process.terminate(); process.wait(timeout=45)
        report['backend_exit'] = None if process is None else process.returncode
        if report['backend_exit'] != 0:
            report['pass'] = False
        report['packaged_source_sha256'] = {p.name: sha(p) for p in (rt / 'backend').glob('*.py')}
        (run / 'receipt.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print('Receipt: ' + str(run / 'receipt.json'), flush=True)
    assert report['pass'], 'Owned packaged backend did not exit cleanly'


if __name__ == '__main__':
    main()
