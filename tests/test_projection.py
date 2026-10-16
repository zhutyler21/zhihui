"""Multilingual fan-out and projection privacy use synthetic owned meetings only."""
from pathlib import Path
import shutil
import tempfile
import time
import unittest

from test_translation import Models

ROOT = Path(__file__).resolve().parents[1]


class ProjectionTests(unittest.TestCase):
    def setUp(self):
        assert ROOT == Path('/Users/zhutyler21/我的项目仓库/知会本地会议').resolve()
        parent = ROOT / 'work/projection-regressions'; parent.mkdir(parents=True, exist_ok=True)
        self.path = Path(tempfile.mkdtemp(dir=parent)).resolve(); assert self.path.is_relative_to(parent)
        from backend.server import Application
        self.models = Models(); self.app = Application(self.path, self.models, root=ROOT)
        self.store = self.app.store
        self.meetings = [self.store.create_meeting('合成大屏-'+role) for role in ('current', 'other')]
        assert len({m['id'] for m in self.meetings}) == 2
        assert [m['title'] for m in self.meetings] == ['合成大屏-current', '合成大屏-other']
        self.mid = self.meetings[0]['id']

    def tearDown(self):
        self.models.release.set(); self.app.close(); shutil.rmtree(self.path)

    def wait(self, jid):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            job = self.store.get_job(jid)
            if job['state'] in ('done', 'error', 'cancelled'):
                return job
            time.sleep(0.01)
        self.fail('projection fixture job did not finish')

    def transcribe(self, **extra):
        audio = self.path / 'fixture.wav'; audio.write_bytes(b'owned synthetic PCM fixture')
        result = self.wait(self.app.transcribe(self.mid, {'path': str(audio), **extra}))
        self.assertEqual(result['state'], 'done')
        return result['result']

    def test_existing_single_language_migrates_without_losing_original_or_translation(self):
        segment = self.store.add_segment(self.mid, '原有合成原文31472元。', 0, 3)
        self.store.configure_translation(self.mid, {'target_language': 'ja', 'enabled': True})
        self.wait(self.app.translate(self.mid, 'ja'))
        with self.store.db() as c:
            c.execute('DROP TABLE translation_settings')
            c.execute('CREATE TABLE translation_settings(meeting_id TEXT PRIMARY KEY,source_language TEXT,target_language TEXT,enabled INTEGER)')
            c.execute('INSERT INTO translation_settings VALUES(?,?,?,?)', (self.mid, 'yue', 'ja', 1))
        from backend.store import Store
        reopened = Store(self.path, self.models)
        self.assertEqual(reopened.translation_settings(self.mid)['target_languages'], ['ja'])
        self.assertEqual(reopened.get_meeting(self.mid)['segments'][0]['id'], segment['id'])
        self.assertEqual(reopened.get_meeting(self.mid)['segments'][0]['translations'][0]['state'], 'done')
        reopened.configure_translation(self.mid, {'target_languages': ['en', 'ja', 'ko']})
        self.assertEqual(reopened.translation_settings(self.mid)['target_language'], 'en')

    def test_invalid_target_arrays_leave_settings_unchanged(self):
        before = self.store.translation_settings(self.mid)
        for targets in ([], ['en', 'en'], ['fr'], 'en', [None], ['en', 'ja', 'ko', 'zh', 'en']):
            with self.assertRaises(ValueError): self.store.configure_translation(self.mid, {'target_languages': targets})
            self.assertEqual(self.store.translation_settings(self.mid), before)

    def test_one_audio_persists_original_once_and_all_three_languages(self):
        self.store.configure_translation(self.mid, {'enabled': True, 'target_languages': ['en', 'ja', 'ko']})
        result = self.transcribe(request_id='single-audio')
        self.assertEqual(len(result['translation_job_ids']), 3)
        self.assertEqual(result['translation_job_id'], result['translation_job_ids'][0])
        for jid in result['translation_job_ids']: self.assertEqual(self.wait(jid)['state'], 'done')
        detail = self.store.get_meeting(self.mid)
        self.assertEqual(len(detail['segments']), 1)
        self.assertEqual({t['target_language'] for t in detail['segments'][0]['translations']}, {'en', 'ja', 'ko'})
        exported = self.store.export_meeting(self.mid)['markdown']
        for target in ('en', 'ja', 'ko'): self.assertIn('译文（'+target+'）', exported)

    def test_audio_snapshot_targets_override_current_settings_and_empty_disables(self):
        self.store.configure_translation(self.mid, {'enabled': True, 'target_languages': ['en', 'ko']})
        result = self.transcribe(request_id='captured-ja', translation_targets=['ja'])
        for jid in result['translation_job_ids']: self.wait(jid)
        self.assertEqual([t['target_language'] for t in self.store.get_meeting(self.mid)['segments'][0]['translations']], ['ja'])
        self.assertEqual(self.transcribe(request_id='captured-off', translation_targets=[])['translation_job_ids'], [])

    def test_one_language_failure_keeps_other_languages_and_original(self):
        base = self.models.translate
        def translate(text, target, source='auto', cancel_event=None):
            if target == 'ja': raise RuntimeError('synthetic Japanese failure')
            return base(text, target, source, cancel_event)
        self.models.translate = translate
        self.store.configure_translation(self.mid, {'enabled': True, 'target_languages': ['en', 'ja', 'ko']})
        result = self.transcribe()
        for jid in result['translation_job_ids']: self.wait(jid)
        projection = self.store.live_projection(self.mid)
        self.assertEqual({t['target_language']: t['state'] for t in projection['segments'][0]['translations']},
                         {'en': 'done', 'ja': 'error', 'ko': 'done'})

    def test_projection_is_bounded_scoped_and_clears_deleted_content(self):
        self.store.patch_meeting(self.mid, {'note': '不应投屏的合成笔记'})
        other = self.store.add_segment(self.meetings[1]['id'], '其他会议的合成秘密', 0, 1)
        segments = [self.store.add_segment(self.mid, '本场合成发言'+str(i), i*3, i*3+3) for i in range(35)]
        self.store.segment_trash(self.mid, segments[-2]['id'], True)
        projection = self.store.live_projection(self.mid)
        self.assertEqual(len(projection['segments']), 30)
        self.assertNotIn('note', projection); self.assertNotIn('summary', projection); self.assertNotIn('attachments', projection)
        self.assertNotIn(other['id'], [s['id'] for s in projection['segments']])
        self.assertNotIn(segments[-2]['id'], [s['id'] for s in projection['segments']])
        self.assertEqual(projection['segments'][-1]['id'], segments[-1]['id'])
        self.store.meeting_trash(self.mid, True)
        self.assertEqual(self.store.live_projection(self.mid)['segments'], [])
        self.store.meeting_trash(self.mid, False)
        self.assertEqual(len(self.store.live_projection(self.mid)['segments']), 30)

    def test_observed_cantonese_currency_and_invented_week_are_rejected(self):
        from backend.translation import ambiguous_currency_issue, missing_time_expressions
        original = '预算系三万一千四百七十二蚊，下次开会再确认合约。'
        self.assertTrue(ambiguous_currency_issue(original, 'The budget is 31,472 Hong Kong dollars.'))
        self.assertFalse(ambiguous_currency_issue(original, 'The budget is 31472 蚊.'))
        self.assertFalse(ambiguous_currency_issue('防蚊项目。', 'Mosquito prevention project.'))
        self.assertFalse(ambiguous_currency_issue('预算是港币五十蚊。', 'The budget is HKD 50.'))
        self.assertTrue(missing_time_expressions(original, '다음 주에 회의를 가질 예정입니다.', 'ko'))
        self.assertFalse(missing_time_expressions('聽日交方案。', 'Submit the proposal tomorrow.', 'en'))
