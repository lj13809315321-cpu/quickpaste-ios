#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""编译后、codesign 之前，把完整 Info.plist 写回主 App 与键盘扩展产物。

背景（对齐墨指 Mozhi 已知可装方案）
-----------------------------
Xcode 16 + XcodeGen 默认 GENERATE_INFOPLIST_FILE=YES 会忽略仓库里的自定义
plist，自动生成只含构建元数据的 plist；即便设 NO，源码 plist 里的 $(...) 占位
也未必被展开。实测缺失会导致：
  * CFBundleExecutable       -> 签名工具报「文件已损坏」
  * NSExtension / Principal  -> iOS 不认 .appex 是键盘扩展，装了也不出现
  * CFBundlePackageType      -> 扩展应为 XPC!，自动生成却是 APPL

本脚本不依赖源文件，直接内置完整必需字段，仅从 Xcode 生成的 plist 里继承
构建元数据（DT* / MinimumOSVersion 等）。必须在 codesign 之前执行，否则
_CodeSignature/CodeResources 哈希会对不上。

改新 App 时只改本文件顶部常量即可。
"""
import os
import sys
import glob
import plistlib

# ===== 改这里：你的键盘 App 标识 =====
APP_ID = "app.mulberry6323.mozhi.pinyinkeyboard"
KEYBOARD_ID = APP_ID + ".keyboard"
APP_MODULE = "PinyinKeyboard"
KEYBOARD_MODULE = "PinyinKeyboardKeyboard"
DISPLAY_APP = "九宫格拼音键盘"
DISPLAY_KB = "九宫格拼音"
VERSION = "1.0"
BUILD = "1"
PRINCIPAL = KEYBOARD_MODULE + ".KeyboardViewController"

BUILD_META_KEYS = (
    "MinimumOSVersion", "DTPlatformName", "DTPlatformVersion",
    "DTPlatformBuild", "DTSDKName", "DTSDKBuild", "DTXcode",
    "DTXcodeBuild", "DTCompiler", "BuildMachineOSBuild",
    "CFBundleSupportedPlatforms", "UIDeviceFamily", "CFBundleInfoDictionaryVersion",
)

ATS = {"NSAllowsArbitraryLoads": True, "NSAllowsLocalNetworking": True}
LOCAL_DESC = "九宫格拼音键盘 需要访问局域网，以连接同一 WiFi 下电脑上的同步服务。"
ORIENTATIONS = [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]

MAIN_APP_PLIST = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": DISPLAY_APP,
    "CFBundleIdentifier": APP_ID,
    "CFBundleExecutable": APP_MODULE,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": APP_MODULE,
    "CFBundlePackageType": "APPL",
    "CFBundleSignature": "????",
    "CFBundleShortVersionString": VERSION,
    "CFBundleVersion": BUILD,
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "16.0",
    "NSAppTransportSecurity": dict(ATS),
    "NSLocalNetworkUsageDescription": LOCAL_DESC,
    "UILaunchScreen": {},
    "UIRequiredDeviceCapabilities": ["arm64"],
    "UISupportedInterfaceOrientations": ORIENTATIONS,
}

KEYBOARD_PLIST = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": DISPLAY_KB,
    "CFBundleIdentifier": KEYBOARD_ID,
    "CFBundleExecutable": KEYBOARD_MODULE,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": APP_MODULE,
    "CFBundlePackageType": "XPC!",
    "CFBundleSignature": "????",
    "CFBundleShortVersionString": VERSION,
    "CFBundleVersion": BUILD,
    "MinimumOSVersion": "16.0",
    "NSAppTransportSecurity": dict(ATS),
    "NSLocalNetworkUsageDescription": LOCAL_DESC,
    "UIRequiredDeviceCapabilities": ["arm64"],
    "NSExtension": {
        "NSExtensionAttributes": {
            "IsASCIICapable": False,
            "PrefersRightToLeft": False,
            "PrimaryLanguage": "zh-Hans",
            "RequestsOpenAccess": True,
        },
        "NSExtensionPointIdentifier": "com.apple.keyboard-service",
        "NSExtensionPrincipalClass": PRINCIPAL,
    },
}


def find_app(root):
    apps = [a for a in glob.glob(os.path.join(root, "**", "*.app"), recursive=True)
            if not a.endswith(".appex")]
    return apps[0] if apps else None


def patch(prod_path, required):
    generated = plistlib.loads(open(prod_path, "rb").read())
    print("[诊断] %s 原有顶层键: %s" % (prod_path, sorted(generated.keys())))
    result = dict(required)
    for key in BUILD_META_KEYS:
        if key in generated and key not in result:
            result[key] = generated[key]
    open(prod_path, "wb").write(plistlib.dumps(result, fmt=plistlib.FMT_XML, sort_keys=True))
    return result


def verify(name, data, want_id, want_type):
    got_id = data.get("CFBundleIdentifier")
    got_type = data.get("CFBundlePackageType")
    print("[%s] CFBundleIdentifier = %s" % (name, got_id))
    print("[%s] CFBundleExecutable = %s" % (name, data.get("CFBundleExecutable")))
    print("[%s] CFBundlePackageType= %s" % (name, got_type))
    print("[%s] MinimumOSVersion   = %s" % (name, data.get("MinimumOSVersion")))
    print("[%s] ATS               = %s" % (name, data.get("NSAppTransportSecurity")))
    ok = got_id == want_id and got_type == want_type and bool(data.get("CFBundleExecutable"))
    ats = data.get("NSAppTransportSecurity") or {}
    if ats.get("NSAllowsArbitraryLoads") is not True or not data.get("NSLocalNetworkUsageDescription"):
        print("[%s] [FATAL] 缺 ATS 例外或本地网络描述" % name)
        ok = False
    return ok


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "build"
    app = find_app(root)
    if not app:
        sys.exit("[FATAL] 在 %s 下找不到 .app" % root)
    ext = None
    plugs = os.path.join(app, "PlugIns")
    if os.path.isdir(plugs):
        cand = [a for a in glob.glob(os.path.join(plugs, "*.appex"))]
        if cand:
            ext = cand[0]
    app_plist = os.path.join(app, "Info.plist")
    ext_plist = os.path.join(ext, "Info.plist") if ext else None

    if not os.path.exists(app_plist):
        sys.exit("[FATAL] 找不到 %s" % app_plist)
    if not ext_plist or not os.path.exists(ext_plist):
        sys.exit("[FATAL] 找不到键盘扩展 Info.plist（请确认 project.yml 里 embed:true）")

    main_app = patch(app_plist, MAIN_APP_PLIST)
    keyboard = patch(ext_plist, KEYBOARD_PLIST)

    open(os.path.join(app, "PkgInfo"), "wb").write(b"APPL????")
    open(os.path.join(ext, "PkgInfo"), "wb").write(b"XPC!????")

    ok = verify("主 app", main_app, APP_ID, "APPL")
    ok = verify("键盘扩展", keyboard, KEYBOARD_ID, "XPC!") and ok

    ns = keyboard.get("NSExtension") or {}
    attrs = ns.get("NSExtensionAttributes") or {}
    point = ns.get("NSExtensionPointIdentifier")
    principal = ns.get("NSExtensionPrincipalClass")
    print("[键盘扩展] NSExtensionPointIdentifier = %s" % point)
    print("[键盘扩展] NSExtensionPrincipalClass  = %s" % principal)
    print("[键盘扩展] RequestsOpenAccess         = %s" % attrs.get("RequestsOpenAccess"))
    if point != "com.apple.keyboard-service" or not principal or principal != PRINCIPAL:
        print("[键盘扩展] [FATAL] NSExtensionPrincipalClass 必须是 %s（在 NSExtension 内）" % PRINCIPAL)
        ok = False
    if attrs.get("RequestsOpenAccess") is not True:
        print("[键盘扩展] [FATAL] 缺 RequestsOpenAccess")
        ok = False

    if not ok:
        sys.exit("[FATAL] Info.plist 关键字段校验失败，终止构建")
    print("[OK] 主 app + 键盘扩展 Info.plist 已修正并通过自检")


if __name__ == "__main__":
    main()
