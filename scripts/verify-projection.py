#!/usr/bin/env python3
"""Real offline multi-target audio pipeline using owned synthetic fixtures only."""
from pathlib import Path
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
    assert ROOT == Path('/Users/zhutyler21/我的项目仓库/知会本地会议').resolve()
    run = ROOT / 'work/projection-20261016' / ('integration-' + uuid.uuid4().hex)
    run.mkdir(parents=True, mode=0o700); assert run.resolve().is_relative_to(ROOT / 'work/projection-20261016')
    report = {'pass': False, 'run': str(run), 'cases': [], 'network_attempts': []}
    original = socket.socket.connect
    def offline(sock, address):
        if not isinstance(address, tuple) or address[0] not in ('127.0.0.1', '::1'):
            report['network_attempts'].append(str(address)); raise RuntimeError('External network denied')
        return original(sock, address)
    socket.socket.connect = offline
    server = None
    try:
        from backend.server import make_server
        from backend.translation import missing_numbers, missing_time_expressions, target_script_issue
        server = make_server(8892, run / 'data', run / 'data/api-token', root=ROOT)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        token = (run / 'data/api-token').read_text().strip()
        def api(route, payload=None, method=None):
            req = urllib.request.Request('http://127.0.0.1:8892' + route,
                data=None if payload is None else json.dumps(payload).encode(),
                method=method or ('GET' if payload is None else 'POST'),
                headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
            return json.load(urllib.request.urlopen(req, timeout=10))
        def wait(jid):
            start = time.monotonic()
            while time.monotonic() - start < 180:
                job = api('/api/jobs/' + jid)
                if job['state'] == 'done': return job['result']
                assert job['state'] not in ('error', 'cancelled'), job
                time.sleep(.1)
            raise TimeoutError('Projection verification exceeded model deadline')
        health = api('/api/health')
        assert health['project_root'] == str(ROOT) and health['data_dir'] == str(run / 'data')
        assert health['models_dir'] == str(ROOT / 'models')
        report['health'] = health
        meetings = {role: api('/api/meetings', {'title': '合成大屏验收-' + role}) for role in ('current', 'other')}
        assert len({m['id'] for m in meetings.values()}) == 2
        assert all(m['id'] and m['title'] == '合成大屏验收-'+role for role, m in meetings.items())
        mid = meetings['current']['id']; report['meetings'] = meetings
        api(f'/api/meetings/{mid}', {'note': '仅用于隔离检查的笔记，不能投屏。'}, 'PATCH')
        api(f'/api/meetings/{meetings["other"]["id"]}/segments', {'text': '另一场合成会议，仅用于范围隔离。', 'start_seconds': 0, 'end_seconds': 3})
        api(f'/api/meetings/{mid}/translation-settings', {'enabled': True, 'target_languages': ['en', 'ja', 'ko']}, 'PATCH')
        fixtures = [ROOT / 'work/live-translation-20261016/audio/zh.aiff', ROOT / 'work/cantonese-20261016/audio/yue.aiff']
        offset = 0
        for index, audio in enumerate(fixtures):
            assert audio.resolve().is_relative_to(ROOT / 'work') and audio.is_file()
            start = time.monotonic()
            result = wait(api(f'/api/meetings/{mid}/transcribe', {'path': str(audio), 'request_id': 'projection-'+str(index), 'start_seconds': offset})['job_id'])
            assert len(result['translation_job_ids']) == 3
            initial = api(f'/api/meetings/{mid}/projection')
            for jid in result['translation_job_ids']: assert wait(jid)['failed'] == 0
            projection = api(f'/api/meetings/{mid}/projection')
            segment = next(s for s in projection['segments'] if s['id'] == result['segment']['id'])
            assert segment['start_seconds'] == offset and segment['text'] == result['text']
            assert {t['target_language'] for t in segment['translations']} == {'en', 'ja', 'ko'}
            for translated in segment['translations']:
                assert translated['state'] == 'done'
                assert not missing_numbers(segment['text'], translated['text'])
                assert not missing_time_expressions(segment['text'], translated['text'], translated['target_language'])
                assert not target_script_issue(translated['text'], translated['target_language'])
            case = {'audio': str(audio.relative_to(ROOT)), 'audio_sha256': hashlib.sha256(audio.read_bytes()).hexdigest(),
                    'source_language': result['language'], 'seconds': round(time.monotonic()-start, 3),
                    'initial_projection': initial, 'final_segment': segment}
            report['cases'].append(case); print(json.dumps(case, ensure_ascii=False), flush=True)
            offset += result['duration_seconds']
        projection = api(f'/api/meetings/{mid}/projection')
        assert len(projection['segments']) == 2 and projection['id'] == mid
        assert not {'note', 'summary', 'attachments'} & projection.keys()
        summary = wait(api(f'/api/meetings/{mid}/summarize', {})['job_id'])['summary']
        assert all(quote in '\n'.join(s['text'] for s in projection['segments']) for quote in re.findall(r'「([^」]+)」', summary))
        exported = api(f'/api/meetings/{mid}/export')['markdown']
        for segment in projection['segments']:
            assert segment['text'] in exported
            for translated in segment['translations']: assert translated['text'] in exported
        assert summary in exported and not report['network_attempts']
        report['summary'] = summary; report['pass'] = True
    finally:
        if server: server.shutdown(); server.server_close(); server.app.close()
        socket.socket.connect = original
        report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in [*ROOT.glob('backend/*.py'), *ROOT.glob('Sources/*.swift')]}
        (run / 'receipt.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print('Receipt: ' + str(run / 'receipt.json'), flush=True)


if __name__ == '__main__': main()
