"""Translation lifecycle regressions, using synthetic data in an owned work directory."""
from pathlib import Path
import shutil
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
assert ROOT == Path('/Users/zhutyler21/我的项目仓库/知会本地会议').resolve()


class Models:
    def __init__(self):
        self.entered = threading.Event()
        self.release = threading.Event()
        self.release.set()
        self.fail = False

    def embed(self, texts):
        return [[1.0, 0.1] for _ in texts]

    def translate(self, text, target, source='auto', cancel_event=None):
        self.entered.set()
        while not self.release.wait(0.01):
            if cancel_event and cancel_event.is_set():
                raise InterruptedError('cancelled')
        if self.fail:
            raise RuntimeError('synthetic model failure')
        return f'{target}: {text}'

    def transcribe(self, path, cancel_event=None, language='auto'):
        return {'text': '合成预算31472元。', 'duration_seconds': 3, 'language': 'zh'}


class TranslationTests(unittest.TestCase):
    def setUp(self):
        parent = ROOT / 'work' / 'translation-regressions'
        parent.mkdir(parents=True, exist_ok=True)
        self.path = Path(tempfile.mkdtemp(dir=parent))
        assert self.path.resolve().is_relative_to(parent.resolve())
        from backend.server import Application
        self.models = Models()
        self.app = Application(self.path, self.models, root=ROOT)
        self.store = self.app.store
        self.meeting = self.store.create_meeting('合成翻译验收会议')
        assert self.meeting['title'] == '合成翻译验收会议' and self.meeting['id']

    def tearDown(self):
        self.models.release.set()
        self.app.close()
        shutil.rmtree(self.path)

    def wait(self, job):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            record = self.store.get_job(job)
            if record['state'] in ('done', 'error', 'cancelled'):
                return record
            time.sleep(0.01)
        self.fail('job did not settle')

    def segment(self, text='合成预算31472元。'):
        return self.store.add_segment(self.meeting['id'], text, 0, 3)

    def test_translation_persists_reopens_and_exports_bilingual_original(self):
        mid = self.meeting['id']
        self.store.configure_translation(mid, {'enabled': True, 'source_language': 'zh', 'target_language': 'en'})
        original = self.segment()
        self.assertEqual(self.wait(self.app.translate(mid, 'en'))['state'], 'done')
        from backend.store import Store
        reopened = Store(self.path, self.models)
        detail = reopened.get_meeting(mid)
        self.assertEqual(detail['translation']['source_language'], 'zh')
        self.assertEqual(detail['segments'][0]['text'], original['text'])
        self.assertEqual(detail['segments'][0]['translations'][0]['state'], 'done')
        exported = reopened.export_meeting(mid)['markdown']
        self.assertIn(original['text'], exported)
        self.assertIn('译文（en）', exported)

    def test_source_edited_during_inference_cannot_publish_stale_translation(self):
        segment = self.segment(); self.models.release.clear()
        first = self.app.translate(self.meeting['id'], 'en')
        self.assertTrue(self.models.entered.wait(2))
        self.store.edit_segment(self.meeting['id'], segment['id'], '校对后预算200元。')
        self.models.release.set()
        self.assertEqual(self.wait(first)['result']['failed'], 1)
        self.assertEqual(self.store.get_meeting(self.meeting['id'])['segments'][0]['translations'], [])
        second = self.app.translate(self.meeting['id'], 'en')
        self.assertNotEqual(first, second)
        self.assertEqual(self.wait(second)['result']['translated'], 1)
        self.assertIn('200', self.store.get_meeting(self.meeting['id'])['segments'][0]['translations'][0]['text'])

    def test_failed_translation_can_retry_without_retranscribing_or_losing_original(self):
        self.segment(); self.models.fail = True
        first = self.app.translate(self.meeting['id'], 'ja')
        self.assertEqual(self.wait(first)['result']['failed'], 1)
        self.models.fail = False
        second = self.app.translate(self.meeting['id'], 'ja')
        self.assertNotEqual(first, second)
        self.assertEqual(self.wait(second)['result']['translated'], 1)
        self.assertEqual(len(self.store.get_meeting(self.meeting['id'])['segments']), 1)

    def test_deleted_original_blocks_inflight_translation_and_export(self):
        segment = self.segment(); self.models.release.clear()
        job = self.app.translate(self.meeting['id'], 'en')
        self.assertTrue(self.models.entered.wait(2))
        self.store.segment_trash(self.meeting['id'], segment['id'], True)
        self.models.release.set(); self.wait(job)
        self.assertNotIn('31472', self.store.export_meeting(self.meeting['id'])['markdown'])
        self.store.segment_trash(self.meeting['id'], segment['id'], False)
        rows = self.store.get_meeting(self.meeting['id'])['segments'][0]['translations']
        self.assertFalse(any(t['state'] == 'done' for t in rows))
        self.assertTrue(all(t['state'] == 'error' for t in rows))

    def test_live_asr_keeps_saving_while_translation_is_slow(self):
        mid = self.meeting['id']
        self.store.configure_translation(mid, {'enabled': True})
        self.models.release.clear()
        audio = self.path / 'synthetic.wav'; audio.write_bytes(b'synthetic fixture audio')
        first = self.wait(self.app.transcribe(mid, {'path': str(audio), 'request_id': 'a'}))
        self.assertEqual(first['state'], 'done')
        self.assertTrue(self.models.entered.wait(2))
        second = self.wait(self.app.transcribe(mid, {'path': str(audio), 'request_id': 'b', 'start_seconds': 3}))
        self.assertEqual(second['state'], 'done')
        self.assertEqual(len(self.store.get_meeting(mid)['segments']), 2)

    def test_queued_cancel_has_visible_retry_state(self):
        mid = self.meeting['id']; a = self.segment(); b = self.segment('第二段合成讲话。')
        self.models.release.clear()
        first = self.app.translate(mid, 'en', [a['id']])
        self.assertTrue(self.models.entered.wait(2))
        queued = self.app.translate(mid, 'en', [b['id']])
        self.app.jobs.cancel(queued)
        rows = self.store.list_segments(mid)
        self.assertEqual(next(s for s in rows if s['id'] == b['id'])['translations'][0]['state'], 'error')
        self.app.jobs.cancel(first); self.models.release.set()
        self.wait(first); self.wait(queued)
        retry = self.app.translate(mid, 'en', [b['id']])
        self.assertEqual(self.wait(retry)['result']['translated'], 1)

    def test_written_amount_regression_and_legitimate_month_format(self):
        from backend.translation import missing_numbers, missing_time_expressions
        self.assertIn('31472', missing_numbers('预算31472元。', 'The budget is 314,720 yuan.'))
        self.assertEqual(missing_numbers('11月9日提交31472元预算。', 'Submit a budget of 31,472 yuan on November 9.'), [])
        self.assertIn('11', missing_numbers('预算11元。', 'The budget is November yuan.'))
        self.assertTrue(missing_time_expressions('来週の金曜日までに完了します。', '我们将在本周五完成。', 'zh'))
        self.assertEqual(missing_time_expressions('다음 주 금요일까지 완료합니다.', '下周五前完成。', 'zh'), [])
        self.assertEqual(missing_time_expressions('下周五前完成。', 'Finish by next Friday.', 'en'), [])
        self.assertEqual(missing_time_expressions('Finish by next Friday.', '다음 금요일까지 완료합니다.', 'ko'), [])
        self.assertTrue(missing_time_expressions('Finish by next Friday.', '本周五完成。', 'zh'))
        self.assertEqual(missing_numbers('11월 9일까지 예산 31472위안.', 'Budget 31472 yuan by November 9.'), [])

    def test_rejects_obvious_wrong_target_script_without_rejecting_short_names(self):
        from backend.translation import target_script_issue
        wrong = '今日討論顧客提案，我們決定預算為31472元。陳杰負責在11月9日前提交方案。'
        self.assertTrue(target_script_issue(wrong, 'ja'))
        self.assertFalse(target_script_issue('予算は31472元です。田中さんが担当します。', 'ja'))
        self.assertTrue(target_script_issue('今天讨论客户方案，预算为31472元，负责人是田中，下次会议继续确认合同。', 'en'))
        self.assertTrue(target_script_issue('Today we discussed the client proposal and budget.', 'ko'))
        self.assertFalse(target_script_issue('田中', 'ja'))
        with self.assertRaises(ValueError):
            self.store.configure_translation(self.meeting['id'], {'source_language': 'fr'})

    def test_summary_keeps_quotes_exact_and_localizes_only_body_time(self):
        from backend.prompts import review_summary
        original = '来週の金曜日までにテストを完了します。'
        result, issues = review_summary('期限：来週的金曜日之前。依据：「' + original + '」[1]', ['[1] 原文\n' + original])
        self.assertEqual(issues, [])
        self.assertIn('下周五', result)
        self.assertIn('「' + original + '」', result)
        _, issues = review_summary('期限：下周五。依据：「Alice will finish testing by next Friday.」[1]',
                                   ['[1] 原文\nAlice will finish testing by next Friday.'])
        self.assertEqual(issues, [])
        _, issues = review_summary('期限：下周五。依据：「11月9日前提交」[1]', ['[1] 原文\n11月9日前提交'])
        self.assertTrue(issues)
        normalized, issues = review_summary('依据：「김민수입니다。」[1]', ['[1] 原文\n김민수입니다.'])
        self.assertEqual(issues, [])
        self.assertIn('「김민수입니다」', normalized)


if __name__ == '__main__':
    unittest.main()
