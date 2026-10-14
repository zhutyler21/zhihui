#!/usr/bin/env python3
"""Install this project's signed app, retaining a previous own build as a backup."""
from pathlib import Path
import datetime
import json
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'dist/知会.app'
TARGET = Path.home() / 'Applications/知会.app'


def metadata(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        return plistlib.load(stream)


def main():
    info = metadata(SOURCE)
    if info.get('CFBundleIdentifier') != 'io.local.zhihui.meetings' or info.get('ZhihuiProjectRoot') != str(ROOT):
        raise RuntimeError('待安装应用与本项目身份不一致。')
    if any(key in info for key in ('ZhihuiDataDirectory', 'ZhihuiPort')):
        raise RuntimeError('这是隔离验收配置，请重新构建正式版后安装。')
    subprocess.run(['codesign', '--verify', '--strict', str(SOURCE)], check=True)
    TARGET.parent.mkdir(exist_ok=True)
    if TARGET.exists():
        old = metadata(TARGET)
        if old.get('CFBundleIdentifier') != info['CFBundleIdentifier'] or old.get('ZhihuiProjectRoot') != str(ROOT):
            raise RuntimeError('应用程序目录已有同名但不同项目的应用，请另选名称；本脚本不会覆盖它。')
    stage = TARGET.parent / ('.知会-install-' + uuid.uuid4().hex + '.app')
    shutil.copytree(SOURCE, stage, symlinks=True)
    try:
        subprocess.run(['codesign', '--verify', '--strict', str(stage)], check=True)
        backup = None
        if TARGET.exists():
            destination = ROOT / 'work/installed-app-backups'
            destination.mkdir(parents=True, exist_ok=True)
            backup = destination / ('知会-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '.app')
            TARGET.rename(backup)
        try:
            stage.rename(TARGET)
        except BaseException:
            if backup and not TARGET.exists():
                backup.rename(TARGET)
            raise
        print(json.dumps({'installed': str(TARGET), 'backup': str(backup) if backup else None}, ensure_ascii=False))
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == '__main__':
    main()
