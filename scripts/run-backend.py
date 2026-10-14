#!/usr/bin/env python3
"""Run only the backend shipped beside this launcher under isolated Python."""
from pathlib import Path
import runpy
import sys

ROOT = Path(__file__).resolve().parents[1]
if not (ROOT / 'backend/server.py').is_file():
    raise SystemExit('应用内的后端文件不完整，请重新下载知会。')
sys.path.insert(0, str(ROOT))
runpy.run_module('backend.server', run_name='__main__')
