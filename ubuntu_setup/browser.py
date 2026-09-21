"""Ask the current Linux desktop to open a completed local HTML report."""

import os
from pathlib import Path
import shutil
import subprocess


def open_report(path):
    report = Path(path).absolute()
    if not report.is_file():
        return {"status": "failed", "reason": "HTML 报告文件不存在，未请求打开"}
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return {"status": "unavailable", "reason": "未检测到桌面会话；HTML 报告已保存，可通过文件路径查看"}
    opener = shutil.which("xdg-open", path="/usr/bin:/bin")
    if opener is None:
        return {"status": "unavailable", "reason": "未找到 xdg-open；HTML 报告已保存，可手动用浏览器打开"}
    try:
        result = subprocess.run([opener, report.as_uri()], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=5, start_new_session=True, check=False)
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "reason": "打开请求未在 5 秒内返回，未重复启动；HTML 报告已保存"}
    except OSError:
        return {"status": "failed", "reason": "无法启动默认浏览器；HTML 报告已保存，可手动打开"}
    if result.returncode:
        return {"status": "failed", "reason": "默认浏览器打开请求失败；HTML 报告已保存，可手动打开"}
    return {"status": "requested", "reason": "已请求默认浏览器打开 HTML 报告"}
