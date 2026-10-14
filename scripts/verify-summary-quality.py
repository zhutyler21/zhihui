from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from backend.engines import LocalModels

from backend.prompts import SUMMARY_SYSTEM as SYSTEM

CASES = [
    ('预算与下次会议', '[1] 今天讨论客户方案。我们决定把项目预算定为31472元，由李青负责，截止日期是11月9日。下次会议要确认合同和交付时间。', ['内部审批', '审批流程', '全体项目组', '下次会议召开前']),
    ('尚未确定的预算', '[1] 今天讨论软件采购方案。预算尚未确定，负责人和截止日期也没有确定。我们下次继续讨论。', ['31472', '98204', '王红', '李青', '确定采购预算为']),
    ('明确决定与一个行动', '[1] 团队决定本周暂不上线。张伟负责周五前提交测试报告。预算问题本次没有讨论。', ['本周上线', '周五上线', '李青', '批准预算']),
]


if __name__ == '__main__':
    m = LocalModels(ROOT)
    outputs = []
    for name, evidence, forbidden in CASES:
        answer = m.generate(evidence + '\n请按系统要求整理会议纪要。', SYSTEM, max_tokens=900)
        failures = [term for term in forbidden if term in answer]
        if name == '预算与下次会议' and ('31472' not in answer.replace(',', '') or '李青' not in answer):
            failures.append('丢失预算或负责人')
        outputs.append({'name': name, 'evidence': evidence, 'answer': answer, 'failures': failures})
        print(name, 'PASS' if not failures else 'FAIL', answer, flush=True)
    (ROOT / 'work/summary-quality-candidate.json').write_text(json.dumps(outputs, ensure_ascii=False, indent=2))
    if any(item['failures'] for item in outputs):
        raise SystemExit(1)
