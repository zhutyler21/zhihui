#!/usr/bin/env python3
"""Execute the authenticated app API with actual offline ASR, vectors and Qwen."""
from pathlib import Path
import hashlib
import json
import re
import socket
import sys
import threading
import time
import urllib.request
import urllib.error
import uuid
from datetime import datetime
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
if ROOT != Path('/Users/zhutyler21/我的项目仓库/知会本地会议'):
    raise RuntimeError('验收脚本不在批准的项目根目录。')
sys.path.insert(0, str(ROOT))
from backend.server import make_server
from backend.engines import LocalModels

RUN = ROOT / 'work' / ('real-app-' + uuid.uuid4().hex)
RUN.mkdir(mode=0o700)
result = {'date': datetime.now(ZoneInfo('Asia/Singapore')).isoformat(),
          'data_dir': str(RUN), 'checks': [], 'answers': {}, 'network_attempts': [], 'pass': False}
socket_connect = socket.socket.connect


def local_connect(self, address):
    if isinstance(address, tuple) and address[0] not in ('127.0.0.1', '::1', 'localhost'):
        result['network_attempts'].append(str(address))
        raise AssertionError('测试中禁止本地模型连接外网：' + str(address))
    return socket_connect(self, address)


def check(condition, name):
    if not condition:
        raise AssertionError(name)
    result['checks'].append(name)
    print('PASS', name, flush=True)


def normalized(text):
    return text.replace(',', '').replace('，', '')


def main():
    server = make_server(0, RUN / 'data', RUN / 'api-token', root=ROOT)
    token = (RUN / 'api-token').read_text().strip()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    socket.socket.connect = local_connect
    address = 'http://127.0.0.1:' + str(server.server_port)

    def api(path, method='GET', payload=None, authenticated=True):
        headers = {'Content-Type': 'application/json'}
        if authenticated:
            headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request(address + path, method=method, headers=headers,
                                         data=None if payload is None else json.dumps(payload).encode())
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)

    def wait(job_id, timeout=240):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            job = api('/api/jobs/' + job_id)
            if job['state'] == 'done':
                return job['result']
            if job['state'] in ('error', 'cancelled'):
                raise RuntimeError(str(job))
            time.sleep(0.15)
        raise TimeoutError('后台作业未在验收期限内结束。')

    def job(path, payload=None):
        return wait(api(path, 'POST', payload or {})['job_id'])

    try:
        try:
            api('/api/health', authenticated=False)
            raise AssertionError('未经鉴权的请求居然成功。')
        except urllib.error.HTTPError as error:
            check(error.code == 401, '真实 API 拒绝无令牌请求')
        health = api('/api/health')
        check(health['app'] == 'zhihui' and all(x['ready'] for x in health['models'].values()), '独立三模型文件就绪')
        a = api('/api/meetings', 'POST', {'title': '验收 A · 客户方案'})['id']
        b = api('/api/meetings', 'POST', {'title': '验收 B · 机房维护'})['id']
        empty = api('/api/meetings', 'POST', {'title': '验收空会议'})['id']
        audio = ROOT / 'work/中文会议验收.aiff'
        check(audio.is_file(), '真实中文音频输入存在')
        transcript = job('/api/meetings/' + a + '/transcribe', {'path': str(audio), 'request_id': 'real-audio-v1'})
        check('31472' in normalized(transcript['text']) and '11月9日' in transcript['text'], '真实中文 ASR 经 API 持久化并索引')
        result['asr'] = transcript
        segment = transcript['segment']['id']
        corrected = transcript['text'].replace('李清', '李青')
        api('/api/meetings/' + a + '/segments/' + segment, 'PATCH', {'text': corrected})
        check(api('/api/meetings/' + a)['segments'][0]['text'] == corrected, '转写校对保留正文和时间')
        repeated = job('/api/meetings/' + a + '/transcribe', {'path': str(audio), 'request_id': 'real-audio-v1'})
        check(len(api('/api/meetings/' + a)['segments']) == 1, '同一录音请求重试不重复')
        api('/api/meetings/' + b + '/segments', 'POST', {'text': '机房维护的项目费用为98204元，王红负责，12月31日完成。核验口令是红石968。'})
        attachment = RUN / 'A资料.txt'
        attachment.write_text('客户方案：费用31472元，李青负责，11月9日完成。核验口令是青松742。', encoding='utf-8')
        source = job('/api/sources', {'paths': [str(attachment)], 'meeting_id': a})
        job('/api/sources', {'paths': [str(attachment)], 'meeting_id': a})
        files = api('/api/sources?meeting_id=' + a)['items']
        check(len(files) == 1 and files[0]['filename'] == 'A资料.txt', '会议附件保存副本且内容去重')
        global_file = RUN / '停车场说明.txt'
        global_file.write_text('停车楼每日早上07:35开放，晚上22:45关闭。服务热线为400-123-8899。')
        job('/api/sources', {'paths': [str(global_file)]})
        summary = job('/api/meetings/' + a + '/summarize')
        check('31472' in normalized(summary['summary']) and '李青' in summary['summary'] and '11月9日' in summary['summary'], '真实千问中文纪要依据会议事实')
        result['summary'] = summary['summary']
        for meeting_id, budget, owner, code, forbidden in [(a, '31472', '李青', '青松742', '98204'), (b, '98204', '王红', '红石968', '31472')]:
            answer = job('/api/ask', {'question': '这笔支出有多少钱、由谁跟进、什么时候完成？核验口令是什么？', 'scope': 'meeting', 'meeting_id': meeting_id})
            text = normalized(answer['answer'])
            result['answers'][meeting_id] = answer
            check(budget in text and owner in text and code in text and forbidden not in text, '真实按会议问答正确且无另一场预算')
            check(bool(answer['citations']) and all(x['meeting_id'] == meeting_id for x in answer['citations']) and bool(re.search(r'\[\d+\]', text)), '语义检索严格范围与可查看引用')
        comparison = job('/api/ask', {'question': '对比客户方案和机房维护的费用，哪个项目更高？', 'scope': 'meetings'})
        result['answers']['comparison'] = comparison
        check('31472' in normalized(comparison['answer']) and '98204' in normalized(comparison['answer']), '跨会议查询两场真实资料')
        global_answer = job('/api/ask', {'question': '停车楼几点开放？', 'scope': 'all'})
        result['answers']['global'] = global_answer
        check(any(x['meeting_id'] is None for x in global_answer['citations']) and ('07:35' in global_answer['answer'] or '7:35' in global_answer['answer'] or '7点35' in global_answer['answer']), '全部知识库检索无会议关联的文件')
        empty_answer = job('/api/ask', {'question': '预算是多少？', 'scope': 'meeting', 'meeting_id': empty, 'history': [{'role': 'assistant', 'content': '预算98204元'}]})
        check(not empty_answer['citations'] and '98204' not in empty_answer['answer'], '空会议不从旧聊天或其他会议补事实')
        api('/api/meetings/' + b + '/trash', 'POST', {})
        answer = job('/api/ask', {'question': '机房项目费用是多少？', 'scope': 'meetings'})
        check(all(x['meeting_id'] != b for x in answer['citations']) and '98204' not in normalized(answer['answer']), '回收站会议不进入语义检索')
        api('/api/meetings/' + b + '/restore', 'POST', {})
        check(api('/api/meetings/' + b)['deleted_at'] is None, '恢复会议保留转写和附件关联')
        exported = api('/api/meetings/' + a + '/export')
        (RUN / '会议导出.md').write_text(exported['markdown'])
        check('31472' in normalized(exported['markdown']) and '李青' in exported['markdown'], '实际导出文件包含会议与中文纪要')
        check(not result['network_attempts'], '真实转写/索引/摘要/问答无外部 Python 网络连接')
        check((RUN / 'api-token').stat().st_mode & 0o777 == 0o600, '本地令牌私有权限')
        result['pass'] = True
    finally:
        server.shutdown()
        server.server_close()
        server.app.close()
        socket.socket.connect = socket_connect
        result['source_hashes'] = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in list((ROOT / 'backend').glob('*.py')) + [Path(__file__)]}
        (RUN / 'receipt.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print('真实模型验收记录：' + str(RUN / 'receipt.json'), flush=True)


if __name__ == '__main__':
    main()
