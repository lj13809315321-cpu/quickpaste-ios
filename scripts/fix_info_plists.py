#!/usr/bin/env python3
"""编译后、codesign 之前，把完整 Info.plist 写回单 App 产物（同步版）。

背景：Xcode 16 + XcodeGen 可能忽略仓库 Info.plist，自动生成只有构建元数据的
plist，导致产物缺 CFBundleIdentifier / ATS 例外 / 本地网络描述，爱思导入报
「文件已损坏」，且 WKWebView 打不开 http 局域网页面。
本脚本不依赖源文件，直接内置完整必需字段，从 Xcode 生成的 plist 继承构建元数据。
必须在 codesign 之前执行，否则 _CodeSignature/CodeResources 哈希对不上。
"""

import plistlib
import sys
from pathlib import Path

APP_ID = "app.mulberry6323.twilight7904"

BUILD_META_KEYS = (
    "MinimumOSVersion", "DTPlatformName", "DTPlatformVersion",
    "DTPlatformBuild", "DTSDKName", "DTSDKBuild", "DTXcode",
    "DTXcodeBuild", "DTCompiler", "BuildMachineOSBuild",
    "CFBundleSupportedPlatforms", "UIDeviceFamily", "CFBundleInfoDictionaryVersion",
)

MAIN_APP_PLIST = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": "QuickPaste",
    "CFBundleIdentifier": APP_ID,
    "CFBundleExecutable": "QuickPaste",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "QuickPaste",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.6",
    "CFBundleVersion": "16",
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "16.0",
    "NSAppTransportSecurity": {
        "NSAllowsArbitraryLoads": True,
        "NSAllowsLocalNetworking": True,
    },
    "NSLocalNetworkUsageDescription":
        "QuickPaste 需要访问局域网，以连接同一 WiFi 下电脑上的剪贴板同步服务。",
    "NSPhotoLibraryUsageDescription": "用于选择要同步到电脑的图片。",
    "NSCameraUsageDescription": "用于拍摄要同步到电脑的图片。",
    "UILaunchScreen": {},
    "UIRequiredDeviceCapabilities": ["arm64"],
    "UISupportedInterfaceOrientations": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
}


def main():
    app = Path("build/Build/Products/Release-iphoneos/QuickPaste.app")
    plist = app / "Info.plist"
    if not plist.exists():
        sys.exit("[FATAL] 找不到 " + str(plist))

    generated = plistlib.loads(plist.read_bytes())
    print("[诊断] 原顶层键:", sorted(generated.keys()))
    result = dict(MAIN_APP_PLIST)
    for key in BUILD_META_KEYS:
        if key in generated and key not in result:
            result[key] = generated[key]
    plist.write_bytes(plistlib.dumps(result, fmt=plistlib.FMT_XML, sort_keys=True))
    (app / "PkgInfo").write_bytes(b"APPL????")

    got_id = result.get("CFBundleIdentifier")
    got_type = result.get("CFBundlePackageType")
    print("[主 app] CFBundleIdentifier =", got_id)
    print("[主 app] CFBundleExecutable =", result.get("CFBundleExecutable"))
    print("[主 app] CFBundlePackageType =", got_type)
    print("[主 app] ATS =", result.get("NSAppTransportSecurity"))
    print("[主 app] LocalNetwork =", bool(result.get("NSLocalNetworkUsageDescription")))
    if got_id != APP_ID or got_type != "APPL" or not result.get("CFBundleExecutable"):
        sys.exit("[FATAL] Info.plist 关键字段校验失败")
    print("[OK] 单 App Info.plist 已修正并通过自检")


if __name__ == "__main__":
    main()
