#!/usr/bin/env python3
"""在 codesign 之前，把完整正确的 Info.plist 写回构建产物。

背景
----
Xcode 16 + XcodeGen 默认 GENERATE_INFOPLIST_FILE=YES，会忽略仓库中的
App/Info.plist 与 Keyboard/Info.plist，自动生成一份只包含构建元数据的 plist。
实测产物因此缺失：
  * CFBundleIdentifier  -> 爱思等重签工具导入时判「文件已损坏」/ MissingCFBundleIdentifier
  * NSExtension         -> iOS 不认 .appex 是键盘扩展，装了也不会出现
  * CFBundlePackageType -> 扩展应为 XPC!，自动生成的却是 APPL

另外，Xcode 构建过程可能就地改写仓库里的 Info.plist，所以本脚本**不依赖源文件**，
直接内置完整的必需字段；仅从 Xcode 生成的 plist 里继承构建元数据
（MinimumOSVersion / DTPlatformVersion / CFBundleSupportedPlatforms 等）。

必须在 codesign 之前执行，否则 _CodeSignature/CodeResources 的哈希会对不上。
"""

import plistlib
import sys
from pathlib import Path

APP_ID = "app.mulberry6323.twilight7904"
KEYBOARD_ID = APP_ID + ".keyboard"
KEYBOARD_MODULE = "QuickPasteKeyboard"  # PRODUCT_MODULE_NAME

# 由 Xcode 注入、对安装/校验有用的构建元数据
BUILD_META_KEYS = (
    "MinimumOSVersion",
    "DTPlatformName",
    "DTPlatformVersion",
    "DTPlatformBuild",
    "DTSDKName",
    "DTSDKBuild",
    "DTXcode",
    "DTXcodeBuild",
    "DTCompiler",
    "BuildMachineOSBuild",
    "CFBundleSupportedPlatforms",
    "UIDeviceFamily",
    "CFBundleInfoDictionaryVersion",
)

MAIN_APP_PLIST = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": "QuickPaste",
    "CFBundleIdentifier": APP_ID,
    "CFBundleExecutable": "QuickPaste",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "QuickPaste",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "LSRequiresIPhoneOS": True,
    "UILaunchScreen": {},
    "UIRequiredDeviceCapabilities": ["arm64"],
    "UISupportedInterfaceOrientations": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
}

KEYBOARD_PLIST = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": "QuickPaste",
    "CFBundleIdentifier": KEYBOARD_ID,
    "CFBundleExecutable": "QuickPasteKeyboard",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "QuickPaste",
    "CFBundlePackageType": "XPC!",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "UIRequiredDeviceCapabilities": ["arm64"],
    "NSExtension": {
        "NSExtensionAttributes": {
            "IsASCIICapable": False,
            "PrefersRightToLeft": False,
            "PrimaryLanguage": "zh-Hans",
            "RequestsOpenAccess": True,
        },
        "NSExtensionPointIdentifier": "com.apple.keyboard-service",
        "NSExtensionPrincipalClass": KEYBOARD_MODULE + ".KeyboardViewController",
    },
}


def read(path):
    with Path(path).open("rb") as f:
        return plistlib.load(f)


def write(path, data):
    with Path(path).open("wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_XML, sort_keys=True)


def patch(prod_path, required):
    generated = read(prod_path)
    print(f"[诊断] {prod_path} 原有顶层键: {sorted(generated.keys())}")
    result = dict(required)
    for key in BUILD_META_KEYS:
        if key in generated and key not in result:
            result[key] = generated[key]
    write(prod_path, result)
    return result


def verify(name, data, want_id, want_type):
    got_id = data.get("CFBundleIdentifier")
    got_type = data.get("CFBundlePackageType")
    print(f"[{name}] CFBundleIdentifier = {got_id}")
    print(f"[{name}] CFBundleExecutable = {data.get('CFBundleExecutable')}")
    print(f"[{name}] CFBundlePackageType= {got_type}")
    print(f"[{name}] MinimumOSVersion   = {data.get('MinimumOSVersion')}")
    if got_id != want_id or got_type != want_type:
        return False
    if not data.get("CFBundleExecutable"):
        return False
    return True


def main():
    app = Path("build/Build/Products/Release-iphoneos/QuickPaste.app")
    ext = app / "PlugIns" / "QuickPasteKeyboard.appex"
    app_plist = app / "Info.plist"
    ext_plist = ext / "Info.plist"

    for path in (app_plist, ext_plist):
        if not path.exists():
            sys.exit(f"[FATAL] 找不到 {path}")

    main_app = patch(app_plist, MAIN_APP_PLIST)
    keyboard = patch(ext_plist, KEYBOARD_PLIST)

    # PkgInfo：4 字节包类型 + 4 字节 creator
    (app / "PkgInfo").write_bytes(b"APPL????")
    (ext / "PkgInfo").write_bytes(b"XPC!????")

    ok = verify("主 app", main_app, APP_ID, "APPL")
    ok = verify("键盘扩展", keyboard, KEYBOARD_ID, "XPC!") and ok

    ns = keyboard.get("NSExtension") or {}
    point = ns.get("NSExtensionPointIdentifier")
    principal = ns.get("NSExtensionPrincipalClass")
    print(f"[键盘扩展] NSExtensionPointIdentifier = {point}")
    print(f"[键盘扩展] NSExtensionPrincipalClass  = {principal}")
    if point != "com.apple.keyboard-service" or not principal or "$(" in principal:
        ok = False

    if not ok:
        sys.exit("[FATAL] Info.plist 关键字段校验失败，终止构建")
    print("[OK] Info.plist 已修正并通过自检")


if __name__ == "__main__":
    main()
