#!/usr/bin/env python3
"""Real offline four-language audio → transcript → translation → Chinese minutes.

Supply synthetic zh/en/ja/ko.aiff files in a project work directory. No daily
meeting data is read. This checks model/API persistence, not microphone hardware.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import socket
import sys
import threading
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio-dir', type=Path, required=True)
    parser.add_argument('--port', type=int, default=8796)
    args = parser.parse_args()
    assert ROOT == Path('/Users/zhutyler21/我的项目仓库/知会本地会议').resolve()
    audio_dir = args.audio_dir.resolve()
    assert audio_dir.is_relative_to(ROOT / 'work') and args.port != 8768
    for language in ('zh', 'en', 'ja', 'ko'):
        assert (audio_dir / (language + '.aiff')).is_file()
    run = ROOT / 'work' / 'live-translation-20261016' / ('integration-' + uuid.uuid4().hex)
    run.mkdir(mode=0o700, parents=True)
    assert run.resolve().is_relative_to(ROOT / 'work')
    report = {'data_dir': str(run), 'port': args.port, 'cases': [], 'additional_translation_pairs': [], 'network_attempts': [], 'pass': False}
    original_connect = socket.socket.connect

    def guarded_connect(sock, address):
        if not isinstance(address, tuple) or address[0] not in ('127.0.0.1', '::1'):
            report['network_attempts'].append(str(address))
            raise RuntimeError('Offline verification blocked a network connection')
        return original_connect(sock, address)

    socket.socket.connect = guarded_connect
    server = None
    try:
        from backend.server import make_server
        from backend.translation import missing_numbers, missing_time_expressions, target_script_issue
        server = make_server(args.port, run, run / 'api-token', root=ROOT)
        assert server.app.store.data_dir == run.resolve()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        token = (run / 'api-token').read_text().strip()

        def call(route, payload=None, method=None):
            request = urllib.request.Request(f'http://127.0.0.1:{args.port}' + route,
                data=None if payload is None else json.dumps(payload).encode(),
                method=method or ('GET' if payload is None else 'POST'),
                headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
            return json.load(urllib.request.urlopen(request, timeout=10))

        def job(route, payload):
            start = time.monotonic()
            response = call(route, payload)
            job_id = response['job_id']
            while time.monotonic() - start < 180:
                record = call('/api/jobs/' + job_id)
                if record['state'] == 'done':
                    return record['result'], round(time.monotonic() - start, 3)
                if record['state'] in ('error', 'cancelled'):
                    raise RuntimeError(str(record))
                time.sleep(0.1)
            raise RuntimeError('Model task exceeded 180 seconds')

        health = call('/api/health')
        assert health['project_root'] == str(ROOT) and health['data_dir'] == str(run)
        assert health['models_dir'] == str(ROOT / 'models')
        assert all(health['models'][key]['ready'] for key in ('asr', 'llm', 'embedding'))
        report['health'] = health
        # Validate every synthetic meeting's complete metadata before using the batch.
        meetings = {lang: call('/api/meetings', {'title': f'合成四语验收-{lang}'}) for lang in ('zh', 'en', 'ja', 'ko')}
        assert len({m['id'] for m in meetings.values()}) == 4
        assert all(m['title'] == f'合成四语验收-{lang}' and m['id'] for lang, m in meetings.items())
        for lang, meeting in meetings.items():
            mid = meeting['id']; target = 'en' if lang == 'zh' else 'zh'
            call(f'/api/meetings/{mid}/translation-settings', {'source_language': lang,
                 'target_language': target, 'enabled': True}, 'PATCH')
            result, elapsed = job(f'/api/meetings/{mid}/transcribe', {'path': str(audio_dir / (lang + '.aiff')), 'request_id': 'synthetic-' + lang})
            assert result['text'].strip() and result['duration_seconds'] > 0
            start = time.monotonic()
            while time.monotonic() - start < 180:
                record = call('/api/jobs/' + result['translation_job_id'])
                if record['state'] == 'done':
                    assert record['result']['failed'] == 0, record
                    break
                assert record['state'] not in ('error', 'cancelled'), record
                time.sleep(0.1)
            else:
                raise RuntimeError('Translation exceeded deadline')
            translation_seconds = round(time.monotonic() - start, 3)
            detail = call(f'/api/meetings/{mid}')
            translation = detail['segments'][0]['translations'][0]
            assert translation['state'] == 'done' and translation['target_language'] == target
            assert not missing_numbers(result['text'], translation['text'])
            assert not missing_time_expressions(result['text'], translation['text'], target)
            assert not target_script_issue(translation['text'], target)
            summary, summary_seconds = job(f'/api/meetings/{mid}/summarize', {})
            assert all(x in summary['summary'] for x in ('总览', '决定', '行动', '未决'))
            assert re.search(r'\[\d+\]', summary['summary'])
            if lang in ('ja', 'ko'):
                assert '下周五' in translation['text'], translation
                assert '下周五' in summary['summary'], summary
            if lang in ('zh', 'en'):
                assert '11月9' in summary['summary'], summary
                assert '下周五' not in summary['summary'], summary
            for quote in re.findall(r'「([^」]+)」', summary['summary']):
                assert quote in result['text'], 'Summary quote is not a source substring: ' + quote
            exported = call(f'/api/meetings/{mid}/export')['markdown']
            assert result['text'] in exported and translation['text'] in exported and summary['summary'] in exported
            item = {'language': lang, 'meeting_id': mid, 'audio_seconds': result['duration_seconds'],
                    'asr_seconds': elapsed, 'translation_seconds': translation_seconds,
                    'summary_seconds': summary_seconds, 'transcript': result['text'],
                    'translation': translation['text'], 'summary': summary['summary']}
            report['cases'].append(item)
            print(json.dumps(item, ensure_ascii=False), flush=True)
            for other_target in ('zh', 'en', 'ja', 'ko'):
                if other_target in (lang, target):
                    continue
                translated, pair_seconds = job(f'/api/meetings/{mid}/translate', {'target_language': other_target})
                assert translated['failed'] == 0, translated
                reread = call(f'/api/meetings/{mid}')
                pair = next(t for t in reread['segments'][0]['translations'] if t['target_language'] == other_target)
                assert pair['state'] == 'done' and pair['text'].strip()
                assert not missing_numbers(result['text'], pair['text'])
                assert not missing_time_expressions(result['text'], pair['text'], other_target)
                assert not target_script_issue(pair['text'], other_target)
                assert pair['text'] in call(f'/api/meetings/{mid}/export')['markdown']
                report['additional_translation_pairs'].append({'source': lang, 'target': other_target,
                    'text': pair['text'], 'seconds': pair_seconds})
        assert not report['network_attempts']
        report['pass'] = True
    finally:
        if server:
            server.shutdown(); server.server_close(); server.app.close()
        socket.socket.connect = original_connect
        report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in [*ROOT.glob('backend/*.py'), *ROOT.glob('Sources/*.swift')]}
        (run / 'receipt.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print('Receipt: ' + str(run / 'receipt.json'), flush=True)
    if not report['pass']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
