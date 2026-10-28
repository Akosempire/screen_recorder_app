#!/usr/bin/env python3
"""Android emulator smoke test: install, record a few seconds, check the Gallery.

  python3 tool/android_smoke.py <apk> <screenshots-dir>

Drives the UI through `uiautomator dump` (Flutter exposes its semantics to it)
and prints a one-line result for the CI log. Exit code 1 if no video was saved.
"""
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PKG = "app.screenrecorder.recorder"


def adb(*args, check=True, text=True):
    return subprocess.run(["adb", *args], check=check, capture_output=True, text=text).stdout


def shot(out_dir, name):
    png = subprocess.run(["adb", "exec-out", "screencap", "-p"], capture_output=True).stdout
    with open(f"{out_dir}/{name}.png", "wb") as f:
        f.write(png)


def nodes():
    adb("shell", "uiautomator", "dump", "/sdcard/ui.xml", check=False)
    xml = adb("shell", "cat", "/sdcard/ui.xml", check=False)
    try:
        return list(ET.fromstring(xml).iter("node"))
    except ET.ParseError:
        return []


def tap(pattern, timeout=20):
    """Taps the first node whose text or content-desc matches `pattern`."""
    rx = re.compile(pattern, re.I)
    end = time.time() + timeout
    while time.time() < end:
        for n in nodes():
            label = f"{n.get('text', '')} {n.get('content-desc', '')}"
            if rx.search(label):
                x1, y1, x2, y2 = map(int, re.findall(r"\d+", n.get("bounds", "[0,0][0,0]")))
                adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
                return label.strip()
        time.sleep(1)
    return None


def main():
    apk, out = sys.argv[1], sys.argv[2]
    adb("install", "-r", "-g", apk)
    adb("shell", "pm", "grant", PKG, "android.permission.RECORD_AUDIO", check=False)
    adb("shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS", check=False)
    adb("shell", "am", "start", "-n", f"{PKG}/.MainActivity")
    time.sleep(15)
    shot(out, "android-home")

    steps = []
    steps.append(("record", tap(r"Start recording")))
    # The system's "start recording / casting?" prompt.
    steps.append(("allow", tap(r"^\s*(Start now|Start|Allow)\s*$|Start now", timeout=15)))
    time.sleep(6)
    shot(out, "android-recording")
    adb("shell", "am", "start", "-n", f"{PKG}/.MainActivity", check=False)
    time.sleep(2)
    steps.append(("stop", tap(r"^\s*Stop\s*$")))
    time.sleep(6)
    shot(out, "android-saved")

    rows = adb("shell", "content", "query", "--uri", "content://media/external/video/media",
               "--projection", "_display_name:relative_path:duration", check=False)
    saved = [r for r in rows.splitlines() if "Screen Recorder" in r]
    print(f"steps={steps} saved={len(saved)} {saved[:1]}")
    sys.exit(0 if saved else 1)


if __name__ == "__main__":
    main()
