"""Meeting naming regressions against isolated SQLite and authenticated HTTP."""
from datetime import datetime
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
import threading
import time
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
assert ROOT == Path('/Users/zhutyler21/我的项目仓库/知会本地会议').resolve()


class TitleModels:
    def __init__(self):
        self.title = '客户方案预算与交付安排'
        self.title_calls = 0
        self.title_error = None
        self.title_entered = None
        self.title_release = None

    def embed(self, texts):
        return [[1., .2, .3] for _ in texts]

    def status(self):
        return {'fixture': True}

    def generate(self, prompt, system, on_chunk=None, cancel_event=None, max_tokens=1600):
        from backend.meeting_titles import TITLE_SYSTEM
        if system == TITLE_SYSTEM:
            self.title_calls += 1
            if self.title_entered is not None:
                self.title_entered.set()
                if not self.title_release.wait(5):
                    raise RuntimeError('fixture title barrier timed out')
            if self.title_error:
                raise self.title_error
            return json.dumps({'title': self.title}, ensure_ascii=False)
        result = '# 总览\n讨论客户方案、预算与交付。\n\n## 决定\n- 预算 31472 元。依据：「项目预算为31472元」[1]\n\n## 行动项\n资料未提及。\n\n## 未决问题\n资料未提及。'
        if on_chunk:
            on_chunk(result)
        return result


class NamingTests(unittest.TestCase):
    def setUp(self):
        self.path = Path(tempfile.mkdtemp(prefix='title-', dir=ROOT/'work'/'fixture')).resolve()
        assert self.path.is_relative_to((ROOT/'work'/'fixture').resolve())
        from backend.server import make_server
        self.models = TitleModels()
        self.server = make_server(0, self.path/'data', self.path/'token', self.models)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = 'http://127.0.0.1:' + str(self.server.server_port)
        self.automatic = self.server.app.store.create_meeting()
        self.manual = self.server.app.store.create_meeting('合成手动命名验收')
        # Validate the entire cohort before accessing any meeting content.
        cohort = self.server.app.store.list_meetings()
        self.assertEqual(len(cohort), 2)
        self.assertEqual({m['id'] for m in cohort}, {self.automatic['id'], self.manual['id']})
        self.assertNotEqual(self.automatic['id'], self.manual['id'])
        self.assertTrue(self.automatic['title'].startswith('会议 '))
        self.assertEqual(self.manual['title'], '合成手动命名验收')

    def tearDown(self):
        if self.models.title_release:
            self.models.title_release.set()
        self.server.shutdown(); self.server.server_close(); self.server.app.close()
        self.thread.join(timeout=5)
        shutil.rmtree(self.path)

    def request(self, method, path, body=None):
        request = urllib.request.Request(self.base+path, method=method,
            headers={'Authorization': 'Bearer '+self.server.token, 'Content-Type': 'application/json'},
            data=None if body is None else json.dumps(body).encode())
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.load(response)

    def submit(self, meeting):
        self.server.app.store.add_segment(meeting['id'], '今天讨论客户方案，项目预算为31472元，交付安排下次确认。')
        return self.request('POST', '/api/meetings/'+meeting['id']+'/summarize', {})['job_id']

    def wait(self, job_id):
        for _ in range(150):
            job = self.request('GET', '/api/jobs/'+job_id)
            if job['state'] in ('done', 'error', 'cancelled'):
                return job
            time.sleep(.03)
        self.fail('summary did not finish')

    def test_summary_names_default_meeting_and_refreshes_automatic_name(self):
        job = self.wait(self.submit(self.automatic))
        self.assertEqual(job['state'], 'done')
        current = self.request('GET', '/api/meetings/'+self.automatic['id'])
        self.assertEqual(current['title'], self.models.title)
        self.assertTrue(current['summary'])
        self.assertTrue(job['result']['title_changed'])
        self.models.title = '客户方案交付时间讨论'
        job = self.wait(self.submit(current))
        self.assertEqual(job['state'], 'done')
        self.assertEqual(self.request('GET', '/api/meetings/'+current['id'])['title'], self.models.title)

    def test_manual_name_stays_and_skips_title_generation(self):
        job = self.wait(self.submit(self.manual))
        self.assertEqual(job['state'], 'done')
        self.assertEqual(self.request('GET', '/api/meetings/'+self.manual['id'])['title'], self.manual['title'])
        self.assertEqual(self.models.title_calls, 0)
        self.assertFalse(job['result']['title_changed'])

    def test_manual_save_of_same_name_is_still_protected_after_reopen(self):
        store = self.server.app.store
        store.patch_meeting(self.automatic['id'], {'title': self.automatic['title']})
        from backend.store import Store
        reopened = Store(self.path/'data', self.models)
        self.assertFalse(reopened.summary_evidence(self.automatic['id'])['title_automatic'])
        job = self.wait(self.submit(self.automatic))
        self.assertEqual(job['state'], 'done')
        self.assertEqual(self.models.title_calls, 0)

    def test_title_failure_preserves_valid_summary_and_reports_it(self):
        for response in ('会议纪要', '预算99999元', '项目预算1元讨论', '预算九万九千元讨论', '含换行\n名称'):
            with self.subTest(title=response):
                self.models.title = response
                job = self.wait(self.submit(self.automatic))
                self.assertEqual(job['state'], 'done')
                current = self.request('GET', '/api/meetings/'+self.automatic['id'])
                self.assertEqual(current['title'], self.automatic['title'])
                self.assertTrue(current['summary'])
                self.assertTrue(job['result']['title_warning'])
        self.models.title_error = RuntimeError('synthetic model title failure')
        job = self.wait(self.submit(self.automatic))
        self.assertEqual(job['state'], 'done')
        self.assertTrue(job['result']['title_warning'])

    def test_edit_or_cancel_during_title_generation_commits_neither_result(self):
        for operation in ('rename', 'note', 'cancel'):
            with self.subTest(operation=operation):
                # Fresh automatic ownership is explicit fixture metadata.
                with self.server.app.store.db() as conn:
                    conn.execute('UPDATE meetings SET title_automatic=1,summary=\'\' WHERE id=?', (self.automatic['id'],))
                self.models.title_entered = threading.Event(); self.models.title_release = threading.Event()
                job_id = self.submit(self.automatic)
                self.assertTrue(self.models.title_entered.wait(3))
                if operation == 'cancel':
                    self.request('POST', '/api/jobs/'+job_id+'/cancel', {})
                else:
                    self.request('PATCH', '/api/meetings/'+self.automatic['id'],
                                 {'title': '用户正在输入的会议名'} if operation == 'rename' else {'note': '最新资料发生变化'})
                self.models.title_release.set(); job = self.wait(job_id)
                self.assertEqual(job['state'], 'cancelled' if operation == 'cancel' else 'error')
                current = self.request('GET', '/api/meetings/'+self.automatic['id'])
                self.assertEqual(current['summary'], '')
                self.assertNotEqual(current['title'], self.models.title)
                self.assertEqual(job['partial'], '')

    def test_legacy_migration_only_recognizes_exact_local_default_name(self):
        from backend.store import Store
        legacy = self.path/'legacy'; legacy.mkdir()
        stamp = 1700000000.
        expected = datetime.fromtimestamp(stamp).strftime('会议 %Y-%m-%d %H:%M')
        with sqlite3.connect(legacy/'database.sqlite') as conn:
            conn.execute("CREATE TABLE meetings(id TEXT PRIMARY KEY,title TEXT NOT NULL,note TEXT NOT NULL DEFAULT '',summary TEXT NOT NULL DEFAULT '',created_at REAL NOT NULL,updated_at REAL NOT NULL,deleted_at REAL,origin_event_id TEXT,origin_timestamp INTEGER,content_version INTEGER NOT NULL DEFAULT 0,UNIQUE(origin_event_id,origin_timestamp))")
            conn.executemany('INSERT INTO meetings(id,title,created_at,updated_at,origin_event_id) VALUES(?,?,?,?,?)',
                             [('default', expected, stamp, stamp, None), ('custom', '客户年度讨论', stamp, stamp, None),
                              ('imported', expected, stamp, stamp, 'foresight'), ('different-date', '会议 2020-01-01 00:00', stamp, stamp, None)])
        migrated = Store(legacy, self.models)
        self.assertEqual({m['id'] for m in migrated.list_meetings()}, {'default', 'custom', 'imported', 'different-date'})
        self.assertTrue(migrated.summary_evidence('default')['title_automatic'])
        for mid in ('custom', 'imported', 'different-date'):
            self.assertFalse(migrated.summary_evidence(mid)['title_automatic'])


class TitleFormatTests(unittest.TestCase):
    def test_reference_labels_and_filenames_do_not_prove_numeric_claims(self):
        from backend.meeting_titles import generated_title, naming_evidence
        material = naming_evidence(['[1] 2026年度文件\n今天讨论客户方案，尚未确定预算。'])
        for title in ('项目预算1元讨论', '2026年度预算讨论', '九万九千元预算讨论'):
            with self.subTest(title=title), self.assertRaises(ValueError):
                generated_title(json.dumps({'title':title}), material)

    def test_strict_title_response_preserves_valid_specific_name(self):
        from backend.meeting_titles import generated_title
        self.assertEqual(generated_title('```json\n{"title":"客户方案预算讨论"}\n```', '预算讨论'), '客户方案预算讨论')
        for value in ('{"title":"会议"}', '{"title":23}', '{"title":"标题","extra":"bad"}',
                      '{"title":"预算99999元"}', '解释：{"title":"预算讨论"}', '{"title":"'+'长'*41+'"}'):
            with self.subTest(response=value), self.assertRaises(ValueError):
                generated_title(value, '预算31472元')
