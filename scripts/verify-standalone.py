#!/usr/bin/env python3
"""Exercise a copied release with original checkout, uv and Homebrew reads denied.
Only UUID-owned temporary fixtures are changed. No real meetings or TCC are used.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import tempfile
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
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/知会.app')
    args = parser.parse_args()
    if not (ROOT / 'Resources/ModelCatalog.json').is_file() or not (ROOT / 'work').is_dir():
        raise RuntimeError('Run only from the approved project checkout or exact staged export.')
    run = Path(tempfile.mkdtemp(prefix='zhihui-standalone-')).resolve()
    if run.parent != Path(tempfile.gettempdir()).resolve() or not run.name.startswith('zhihui-standalone-'):
        raise RuntimeError('Fixture ownership guard failed.')
    run.chmod(0o700)
    app = run / 'Moved Applications 中文' / '知会.app'
    app.parent.mkdir()
    shutil.copytree(args.app.resolve(), app, symlinks=True)
    rt = app / 'Contents/Resources/Runtime'
    data = run / 'private-data'
    models = data / 'models'
    models.mkdir(parents=True)
    catalog = json.loads((rt / 'Resources/ModelCatalog.json').read_text())
    result = {'fixture': str(run), 'checks': [], 'pass': False, 'model_files': [], 'answers': {}}
    receipt = ROOT / 'work/standalone-release-v0.5.0' / ('portable-' + uuid.uuid4().hex + '.json')
    receipt.parent.mkdir(parents=True, exist_ok=True)
    process = None

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        result['checks'].append(message)
        print('PASS', message, flush=True)

    original = ROOT.resolve()
    # A frozen export may reuse only verified model bytes from its own models link.
    denied = [str(original), str(Path.home() / '.local/share/uv'), '/opt/homebrew', '/usr/local']
    if original != Path('/Users/zhutyler21/我的项目仓库/知会本地会议'):
        denied.append('/Users/zhutyler21/我的项目仓库/知会本地会议')
    profile = run / 'isolation.sb'
    profile.write_text('(version 1)\n(allow default)\n' +
        '\n'.join('(deny file-read* (subpath ' + json.dumps(path, ensure_ascii=False) + '))' for path in denied) +
        '\n(deny file-write* (subpath ' + json.dumps(str(app), ensure_ascii=False) + '))\n' +
        '(deny network-outbound)\n(allow network-outbound (remote ip "localhost:*"))\n')
    environment = {'PATH': str(rt / 'bin') + ':/usr/bin:/bin', 'HOME': str(run / 'home'),
        'TMPDIR': str(run / 'tmp'), 'LANG': 'en_US.UTF-8', 'HF_HUB_OFFLINE': '1',
        'TRANSFORMERS_OFFLINE': '1', 'HF_HUB_DISABLE_TELEMETRY': '1',
        'SSL_CERT_FILE': str(rt / 'python/lib/python3.12/site-packages/certifi/cacert.pem')}
    Path(environment['HOME']).mkdir(); Path(environment['TMPDIR']).mkdir()
    command = ['/usr/bin/sandbox-exec', '-f', str(profile), str(rt / 'python/bin/python3'), '-I', '-B', '-u']
    try:
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        before = {str(p.relative_to(app)): sha(p) for p in app.rglob('*') if p.is_file()}
        probe = 'import pathlib; denied=' + repr(denied) + '; outcomes=[]\n'
        probe += 'for p in denied:\n try: list(pathlib.Path(p).iterdir()); outcomes.append(False)\n except PermissionError: outcomes.append(True)\n'
        probe += 'assert all(outcomes), outcomes\nprint("denied all original roots")'
        completed = subprocess.run([*command, '-c', probe], env=environment, cwd=run, capture_output=True, text=True)
        result['sandbox_probe'] = {'exit': completed.returncode, 'stdout': completed.stdout, 'stderr': completed.stderr}
        check(completed.returncode == 0, 'OS sandbox denies original checkout, uv and Homebrew reads')
        protections = 'import pathlib,socket\n'
        protections += 'try: pathlib.Path(' + repr(str(app / 'Contents/Resources/forbidden-probe')) + ').write_text("blocked"); raise AssertionError("App write permitted")\nexcept PermissionError: pass\n'
        protections += 'try: socket.create_connection(("1.1.1.1",443),timeout=2); raise AssertionError("External network permitted")\nexcept PermissionError: pass\nprint("write and external network denied")'
        protected = subprocess.run([*command, '-c', protections], env=environment, cwd=run, capture_output=True, text=True)
        result['protections_probe'] = {'exit': protected.returncode, 'stdout': protected.stdout, 'stderr': protected.stderr}
        check(protected.returncode == 0, 'OS sandbox denies App writes and outbound internet connections')
        cold = subprocess.run([*command, str(rt / 'scripts/setup-models.py'), '--status-json',
                               '--model-dir', str(run / 'cold-models')], env=environment, cwd=run, capture_output=True, text=True)
        result['cold_status'] = {'exit': cold.returncode, 'stdout': cold.stdout, 'stderr': cold.stderr}
        check(cold.returncode == 0 and all(not m['ready'] for m in json.loads(cold.stdout.splitlines()[-1])['models']), 'New-user model check runs from bundled Python with no models')
        for model in catalog['models']:
            for item in model['files']:
                source = (ROOT / 'models' / item['path']).resolve()
                check(source.is_file() and source.stat().st_size == item['size'] and sha(source) == item['sha256'],
                      'Verified fixture model: ' + item['path'])
                target = models / item['path']; target.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run(['/bin/cp', '-c', str(source), str(target)], check=True)
                result['model_files'].append({'path': item['path'], 'sha256': sha(target)})
        audio = run / '中文会议验收.aiff'
        shutil.copy2(ROOT / 'work/中文会议验收.aiff', audio)
        with socket.socket() as port_socket:
            port_socket.bind(('127.0.0.1', 0)); port = port_socket.getsockname()[1]
        token_path = data / 'api-token'
        log = (run / 'backend.log').open('w')
        process = subprocess.Popen([*command, str(rt / 'scripts/run-backend.py'), '--port', str(port),
            '--data-dir', str(data), '--token-file', str(token_path), '--models-dir', str(models),
            '--ffmpeg', str(rt / 'bin/ffmpeg')], env=environment, cwd=run, stdout=log, stderr=subprocess.STDOUT)
        address = 'http://127.0.0.1:' + str(port)
        def api(path, method='GET', payload=None, authenticated=True):
            headers = {'Content-Type': 'application/json'}
            if authenticated:
                headers['Authorization'] = 'Bearer ' + token_path.read_text().strip()
            req = urllib.request.Request(address + path, method=method, headers=headers,
                    data=None if payload is None else json.dumps(payload).encode())
            with urllib.request.urlopen(req, timeout=15) as response:
                return json.load(response)
        for _ in range(120):
            if process.poll() is not None:
                raise RuntimeError('Owned packaged backend exited: ' + (run / 'backend.log').read_text())
            try:
                health = api('/api/health'); break
            except (OSError, ValueError):
                time.sleep(0.25)
        else:
            raise TimeoutError('Packaged backend did not start.')
        result['health'] = health
        check(health['app'] == 'zhihui' and health['project_root'] == str(rt)
            and health['data_dir'] == str(data) and health['models_dir'] == str(models)
            and health['ffmpeg_path'] == str(rt / 'bin/ffmpeg'), 'Real backend identity binds moved runtime, data, models and audio converter')
        check(all(m['ready'] for m in health['models'].values()), 'All three copied model packages are ready')
        try:
            api('/api/health', authenticated=False)
            raise AssertionError('Unauthenticated API succeeded.')
        except urllib.error.HTTPError as error:
            check(error.code == 401, 'Real packaged API rejects unauthenticated requests')
        def job(path, payload=None):
            jid = api(path, 'POST', payload or {})['job_id']
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                state = api('/api/jobs/' + jid)
                if state['state'] == 'done': return state['result']
                if state['state'] in ('error', 'cancelled'): raise RuntimeError(str(state))
                time.sleep(0.25)
            raise TimeoutError('Real-model job exceeded 300 seconds.')
        fixture_id = uuid.uuid4().hex
        expected = ['独立验收-' + fixture_id + '-' + x for x in ('客户方案', '机房维护', '空会议')]
        ids = [api('/api/meetings', 'POST', {'title': title})['id'] for title in expected]
        all_meetings = api('/api/meetings')['items']
        check(len(set(ids)) == 3 and {x['id']: x['title'] for x in all_meetings} == dict(zip(ids, expected)),
              'Entire synthetic meeting batch is owned and validated before content access')
        a, b, empty = ids
        transcript = job('/api/meetings/' + a + '/transcribe', {'path': str(audio), 'request_id': 'portable-audio-v1'})
        result['asr'] = transcript
        check('31472' in transcript['text'].replace(',', '').replace('，', '') and '11月9日' in transcript['text'],
              'Chinese audio is converted, transcribed and indexed by the moved App runtime')
        corrected = transcript['text'].replace('李清', '李青')
        api('/api/meetings/' + a + '/segments/' + transcript['segment']['id'], 'PATCH', {'text': corrected})
        api('/api/meetings/' + b + '/segments', 'POST', {'text': '机房维护费用98204元，王红负责，12月31日完成。核验口令红石968。'})
        attachment = run / '客户方案.txt'; attachment.write_text('客户方案费用31472元，李青负责，11月9日完成。核验口令青松742。')
        job('/api/sources', {'paths': [str(attachment)], 'meeting_id': a})
        summary = job('/api/meetings/' + a + '/summarize')['summary']; result['summary'] = summary
        check('31472' in summary.replace(',', '') and '李青' in summary and '11月9日' in summary, 'Bundled Qwen generates a Chinese summary with source facts')
        for mid, budget, owner, code, forbidden in [(a, '31472', '李青', '青松742', '98204'), (b, '98204', '王红', '红石968', '31472')]:
            answer = job('/api/ask', {'question': '费用多少、谁负责、什么时候完成、核验口令是什么？', 'scope': 'meeting', 'meeting_id': mid})
            result['answers'][mid] = answer
            text = answer['answer'].replace(',', '')
            check(budget in text and owner in text and code in text and forbidden not in text,
                  'Real embedding + Qwen answers the selected meeting only')
            check(bool(answer['citations']) and all(x['meeting_id'] == mid for x in answer['citations']), 'Answer citations belong to the selected meeting')
        answer = job('/api/ask', {'question': '费用多少？', 'scope': 'meeting', 'meeting_id': empty,
                                'history': [{'role': 'assistant', 'content': '费用98204元'}]})
        check(not answer['citations'] and '98204' not in answer['answer'], 'Empty meeting does not borrow other-meeting or chat facts')
        exported = api('/api/meetings/' + a + '/export')['markdown']
        check('31472' in exported.replace(',', '') and '李青' in exported, 'Export reads back persisted transcript and Chinese summary')
        process.terminate(); process.wait(timeout=30)
        check(process.returncode == 0, 'Owned bundled backend exits normally without leaving its child running')
        process = None
        # Compile the production native host from the same frozen source, then run it
        # in the same OS isolation against the actual packaged backend (no substitutes).
        native = ROOT / 'work/standalone-release-v0.5.0/native-host-build/packaged-host-test'
        subprocess.run(['bash', str(ROOT / 'scripts/test-packaged-host.sh')], cwd=ROOT, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        copied_native = run / 'packaged-host-test'; shutil.copy2(native, copied_native)
        native_environment = dict(environment, TMPDIR=str(run.parent))
        probe = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(profile), str(copied_native),
                                str(app), str(data), str(port)], env=native_environment, cwd=run,
                               capture_output=True, text=True, timeout=90)
        result['native_host'] = {'exit': probe.returncode, 'stdout': probe.stdout, 'stderr': probe.stderr,
                                'executable_sha256': sha(copied_native)}
        check(probe.returncode == 0 and json.loads(probe.stdout.splitlines()[-1])['pass'],
              'Production native BackendHost starts/reuses/stops the actual moved packaged backend')
        after = {str(p.relative_to(app)): sha(p) for p in app.rglob('*') if p.is_file()}
        check(before == after, 'Read-only App bytes remain unchanged after real inference')
        result['app_files_sha256'] = before
        result['pass'] = True
    finally:
        if process and process.poll() is None:
            process.terminate(); process.wait(timeout=30)
        receipt.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print('Receipt: ' + str(receipt), flush=True)
    if not result['pass']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
