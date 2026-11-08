#!/usr/bin/env python3
"""在 codesign 之前，把仓库里的自定义 Info.plist 合并回构建产物。

背景
----
Xcode 16 + XcodeGen 默认 GENERATE_INFOPLIST_FILE=YES，会忽略仓库中的
App/Info.plist 与 Keyboard/Info.plist，自动生成一份只包含构建元数据的 plist。
实测产物因此缺失：
  * CFBundleIdentifier  -> 爱思等重签工具导入时判「文件已损坏」
  * NSExtension         -> iOS 不认 .appex 是键盘扩展，装了也不会出现
  * CFBundlePackageType -> 扩展应为 XPC!，自动生成的却是 APPL

做法：以仓库源码 plist 为基础（完全可控），补入 Xcode 生成的必要构建元数据
（MinimumOSVersion / DTPlatformVersion / CFBundleSupportedPlatforms 等），
再显式写入可执行文件类型与 Bundle ID，并展开 $(PRODUCT_MODULE_NAME)。

必须在 codesign 之前执行，否则 _CodeSignature/CodeResources 的哈希会对不上。
"""

import plistlib
import sys
from pathlib import Path

APP_ID = "app.mulberry6323.twilight7904"
KEYBOARD_ID = APP_ID + ".keyboard"
KEYBOARD_MODULE = "QuickPasteKeyboard"

# 由 Xcode 注入、源码 plist 里没有、但对安装/校验有用的构建元数据
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
    "UIRequiredDeviceCapabilities",
    "CFBundleInfoDictionaryVersion",
    "CFBundleDevelopmentRegion",
)


def read(path):
    with Path(path).open("rb") as f:
        return plistlib.load(f)


def write(path, data):
    with Path(path).open("wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_XML, sort_keys=True)


def patch(prod_path, src_path, executable, pkg_type, bundle_id, module=None):
    generated = read(prod_path)
    result = read(src_path)

    for key in BUILD_META_KEYS:
        if key in generated and key not in result:
            result[key] = generated[key]

    result["CFBundleExecutable"] = executable
    result["CFBundlePackageType"] = pkg_type
    result["CFBundleIdentifier"] = bundle_id

    if module and isinstance(result.get("NSExtension"), dict):
        ns = result["NSExtension"]
        principal = ns.get("NSExtensionPrincipalClass", "")
        ns["NSExtensionPrincipalClass"] = principal.replace(
            "$(PRODUCT_MODULE_NAME)", module
        )

    write(prod_path, result)
    return result


def main():
    app = Path("build/Build/Products/Release-iphoneos/QuickPaste.app")
    ext = app / "PlugIns" / "QuickPasteKeyboard.appex"
    app_plist = app / "Info.plist"
    ext_plist = ext / "Info.plist"

    for path in (app_plist, ext_plist):
        if not path.exists():
            sys.exit(f"[FATAL] 找不到 {path}")

    main_app = patch(
        app_plist, "App/Info.plist", "QuickPaste", "APPL", APP_ID
    )
    keyboard = patch(
        ext_plist,
        "Keyboard/Info.plist",
        "QuickPasteKeyboard",
        "XPC!",
        KEYBOARD_ID,
        KEYBOARD_MODULE,
    )

    # PkgInfo：4 字节包类型 + 4 字节 creator
    (app / "PkgInfo").write_bytes(b"APPL????")
    (ext / "PkgInfo").write_bytes(b"XPC!????")

    ok = True
    for label, data in (("主 app", main_app), ("键盘扩展", keyboard)):
        print(f"[{label}] CFBundleIdentifier = {data.get('CFBundleIdentifier')}")
        print(f"[{label}] CFBundleExecutable = {data.get('CFBundleExecutable')}")
        print(f"[{label}] CFBundlePackageType= {data.get('CFBundlePackageType')}")
        print(f"[{label}] MinimumOSVersion   = {data.get('MinimumOSVersion')}")
        if not data.get("CFBundleIdentifier") or not data.get("CFBundleExecutable"):
            ok = False

    ns = keyboard.get("NSExtension") or {}
    print(f"[键盘扩展] NSExtensionPointIdentifier = {ns.get('NSExtensionPointIdentifier')}")
    print(f"[键盘扩展] NSExtensionPrincipalClass  = {ns.get('NSExtensionPrincipalClass')}")
    if ns.get("NSExtensionPointIdentifier") != "com.apple.keyboard-service":
        ok = False
    if not ns.get("NSExtensionPrincipalClass") or "$(" in ns["NSExtensionPrincipalClass"]:
        ok = False

    for label, data in (("主 app", main_app), ("键盘扩展", keyboard)):
        if data.get("MinimumOSVersion") is None:
            print(f"[WARN] {label} 缺 MinimumOSVersion")
    if not ok:
        sys.exit("[FATAL] Info.plist 关键字段校验失败，终止构建")
    print("[OK] Info.plist 已修正并通过自检")


if __name__ == "__main__":
    main()
