#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
编译后兜底：把关键字段强制写回产物里的 Info.plist。
（即使 Xcode 在某些情况下篡改了 plist，这里也会纠正，避免包损坏/键盘不出现。）
改新 App 时改这里顶部的常量即可。
"""
import os
import sys
import glob
import plistlib

# ===== 改成你新 App 的标识 =====
APP_ID = "app.mulberry6323.mozhi.pinyinkeyboard"
KEYBOARD_ID = "app.mulberry6323.mozhi.pinyinkeyboard.keyboard"
DISPLAY_APP = "九宫格拼音键盘"
DISPLAY_KB = "九宫格拼音"
VERSION = "1.0"
BUILD = "1"
PRINCIPAL = "PinyinKeyboardKeyboard.KeyboardViewController"


def find_apps(root):
    return [a for a in glob.glob(os.path.join(root, "**", "*.app"), recursive=True)
            if not a.endswith(".appex")]


def find_appex(root):
    return glob.glob(os.path.join(root, "**", "*.appex"), recursive=True)


def patch(plist_path, fn):
    with open(plist_path, "rb") as f:
        data = plistlib.load(f)
    fn(data)
    with open(plist_path, "wb") as f:
        plistlib.dump(data, f)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "build"
    for app in find_apps(root):
        p = os.path.join(app, "Info.plist")
        if os.path.exists(p):
            patch(p, lambda d: (
                d.__setitem__("CFBundleIdentifier", APP_ID),
                d.__setitem__("CFBundleShortVersionString", VERSION),
                d.__setitem__("CFBundleVersion", BUILD),
                d.__setitem__("CFBundleDisplayName", DISPLAY_APP),
            ))
            print("patched app ->", app)

    for apx in find_appex(root):
        p = os.path.join(apx, "Info.plist")
        if os.path.exists(p):
            def f(d):
                d["CFBundleIdentifier"] = KEYBOARD_ID
                d["CFBundleShortVersionString"] = VERSION
                d["CFBundleVersion"] = BUILD
                d["CFBundleDisplayName"] = DISPLAY_KB
                ext = d.setdefault("NSExtension", {})
                ext["NSExtensionPointIdentifier"] = "com.apple.keyboard-service"
                ext.setdefault("NSExtensionAttributes", {})["RequestsOpenAccess"] = True
                d["NSExtensionPrincipalClass"] = PRINCIPAL
            patch(p, f)
            print("patched appex ->", apx)


if __name__ == "__main__":
    main()
