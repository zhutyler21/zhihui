import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--ready', required=True)
args = parser.parse_args()
state = {'cancelled': [], 'requests': 0, 'saved_notes': {}, 'translation_complete': {}}
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def respond(self, payload, status=200):
        raw = json.dumps(payload).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        if self.path.split('?')[0] == '/api/meetings':
            return self.respond({'items':[]})
        if self.path == '/api/test/status':
            with lock: result = dict(state, cancelled=list(state['cancelled']))
            return self.respond(result)
        if self.path.startswith('/api/meetings/'):
            mid = self.path.split('/')[3].split('?')[0]
            if mid == 'A': time.sleep(0.25)
            elif mid == 'B': time.sleep(0.02)
            if self.path.endswith('/projection'):
                return self.respond({'id':mid,'title':mid+' projection','segments':[],
                                     'deleted_at':1700000000 if mid=='deleted' else None})
            if '/segments' in self.path:
                return self.respond({'items':[{'id':mid+'-trash','text':mid+' deleted','start_seconds':0,'end_seconds':1}]})
            with lock: note = state['saved_notes'].get(mid,mid+' saved')
            if mid.startswith('translation-'):
                with lock: complete = state['translation_complete'].get(mid, False)
                return self.respond({'id':mid,'title':mid+' synthetic meeting','note':note,
                    'created_at':1700000000,'attachments':[], 'segments':[{'id':mid+'-segment',
                    'text':'合成译文状态检查','start_seconds':0,'end_seconds':1,
                    'translations':[{'target_language':'en','state':'done' if complete else 'running',
                                     'text':'Synthetic translation' if complete else ''}]}]})
            return self.respond({'id':mid,'title':mid+' meeting','note':note,'created_at':1700000000,'segments':[],'attachments':[]})
        return self.respond({'error':'missing'},404)
    def do_PATCH(self):
        if self.headers.get('Authorization') != 'Bearer native-fixture-token':
            return self.respond({'error':'unauthorized'},401)
        payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        if self.path.startswith('/api/meetings/'):
            mid = self.path.split('/')[3]
            if self.path.endswith('/translation-settings'):
                return self.respond({'error':'synthetic settings rejected'},500) if mid == 'translation-fail' else self.respond({'ok': True})
            if payload.get('note') == 'FAILSAVE': return self.respond({'error':'fixture save rejected'},500)
            with lock: state['saved_notes'][mid] = payload.get('note','')
            return self.respond({'id':mid,'title':mid+' meeting','note':payload.get('note','')})
        return self.respond({'error':'missing'},404)
    def do_POST(self):
        if self.headers.get('Authorization') != 'Bearer native-fixture-token':
            return self.respond({'error':'unauthorized'},401)
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/api/test/complete-translation':
            mid = json.loads(raw)['meeting_id']
            if mid not in ('translation-save', 'translation-fail', 'translation-other'):
                return self.respond({'error':'unknown synthetic meeting'},400)
            with lock: state['translation_complete'][mid] = True
            return self.respond({'ok': True})
        if self.path == '/api/ask':
            with lock:
                state['requests'] += 1
                jid = 'delayed-job-' + str(state['requests'])
            time.sleep(0.25)
            return self.respond({'job_id':jid})
        if self.path.startswith('/api/jobs/') and self.path.endswith('/cancel'):
            jid = self.path.split('/')[3]
            with lock: state['cancelled'].append(jid)
            return self.respond({'ok': True})
        return self.respond({'error':'missing'},404)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Path(args.ready).write_text(json.dumps({'port':server.server_port}))
server.serve_forever()
