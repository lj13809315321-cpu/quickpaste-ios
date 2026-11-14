#!/usr/bin/env python3
"""编译后、codesign 之前，把完整 Info.plist 写回主 App 产物。

背景
----
Xcode 16 + XcodeGen 默认 GENERATE_INFOPLIST_FILE=NO（本工程已显式关闭），
但 Xcode 仍可能在构建期就地改写仓库里的 Info.plist，或生成的 plist 缺字段；
本脚本**不依赖源文件**，直接内置完整的必需字段，再继承构建元数据，
保证产物含：CFBundleIdentifier / CFBundlePackageType / ATS / UIBackgroundModes(audio) /
CFBundleURLTypes(nianshu) / LSApplicationQueriesSchemes 白名单。

必须在 codesign 之前执行，否则 _CodeSignature/CodeResources 的哈希会对不上。
"""

import plistlib
import sys
from pathlib import Path

APP_ID = "app.mulberry6323.nianshu"
APP_NAME = "粘鼠"
EXEC = "Nianshu"

BUILD_META_KEYS = (
    "MinimumOSVersion", "DTPlatformName", "DTPlatformVersion",
    "DTPlatformBuild", "DTSDKName", "DTSDKBuild", "DTXcode",
    "DTXcodeBuild", "DTCompiler", "BuildMachineOSBuild",
    "CFBundleSupportedPlatforms", "UIDeviceFamily", "CFBundleInfoDictionaryVersion",
)

ATS = {"NSAllowsArbitraryLoads": True, "NSAllowsLocalNetworking": True}
LOCAL_DESC = "粘鼠 需要访问局域网，用于后续可能添加的电脑同步服务。"
ORIENTATIONS = [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]
# 跳回微信/抖音等来源 App 的协议白名单 + 自身 scheme。
QUERY_SCHEMES = ["nianshu", "weixin", "snssdk1128", "mqq", "sinaweibo",
                "alipay", "taobao", "xhsdiscover", "sms", "mobilenotes"]

MAIN_APP_PLIST = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": APP_NAME,
    "CFBundleIdentifier": APP_ID,
    "CFBundleExecutable": EXEC,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": APP_NAME,
    "CFBundlePackageType": "APPL",
    "CFBundleSignature": "????",
    "CFBundleShortVersionString": "1.0.0",
    "CFBundleVersion": "1",
    "LSApplicationQueriesSchemes": QUERY_SCHEMES,
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "16.0",
    "NSAppTransportSecurity": dict(ATS),
    "NSLocalNetworkUsageDescription": LOCAL_DESC,
    "UILaunchScreen": {},
    "UIBackgroundModes": ["audio"],
    "CFBundleURLTypes": [{
        "CFBundleURLName": APP_ID,
        "CFBundleURLSchemes": ["nianshu"],
    }],
    # 暂不设图标：CFBundleIconName 留给以后放好 Assets.xcassets 再补。
    "UIRequiredDeviceCapabilities": ["arm64"],
    "UISupportedInterfaceOrientations": ORIENTATIONS,
}


def patch(prod_path, required):
    generated = plistlib.loads(Path(prod_path).read_bytes())
    print("[诊断] %s 原有顶层键: %s" % (prod_path, sorted(generated.keys())))
    result = dict(required)
    for key in BUILD_META_KEYS:
        if key in generated and key not in result:
            result[key] = generated[key]
    Path(prod_path).write_bytes(plistlib.dumps(result, fmt=plistlib.FMT_XML,
                                               sort_keys=True))
    return result


def verify(name, data, want_id, want_type):
    got_id = data.get("CFBundleIdentifier")
    got_type = data.get("CFBundlePackageType")
    print("[%s] CFBundleIdentifier = %s" % (name, got_id))
    print("[%s] CFBundleExecutable = %s" % (name, data.get("CFBundleExecutable")))
    print("[%s] CFBundlePackageType= %s" % (name, got_type))
    print("[%s] MinimumOSVersion   = %s" % (name, data.get("MinimumOSVersion")))
    print("[%s] UIBackgroundModes = %s" % (name, data.get("UIBackgroundModes")))
    print("[%s] CFBundleURLTypes  = %s" % (name, data.get("CFBundleURLTypes")))
    ok = got_id == want_id and got_type == want_type and bool(data.get("CFBundleExecutable"))
    ats = data.get("NSAppTransportSecurity") or {}
    if ats.get("NSAllowsArbitraryLoads") is not True or not data.get("NSLocalNetworkUsageDescription"):
        print("[%s] [FATAL] 缺 ATS 例外或本地网络描述" % name)
        ok = False
    if data.get("UIBackgroundModes") != ["audio"]:
        print("[%s] [FATAL] 缺画中画后台模式 audio" % name)
        ok = False
    schemes = [s for t in (data.get("CFBundleURLTypes") or [])
               for s in (t.get("CFBundleURLSchemes") or [])]
    if "nianshu" not in schemes:
        print("[%s] [FATAL] 缺 nianshu URL scheme" % name)
        ok = False
    return ok


def main():
    app = Path("build/Build/Products/Release-iphoneos/Nianshu.app")
    app_plist = app / "Info.plist"
    if not app_plist.exists():
        sys.exit("[FATAL] 找不到 %s" % app_plist)

    main_app = patch(app_plist, MAIN_APP_PLIST)
    (app / "PkgInfo").write_bytes(b"APPL????")

    ok = verify("主 app", main_app, APP_ID, "APPL")

    if not ok:
        sys.exit("[FATAL] Info.plist 关键字段校验失败，终止构建")
    print("[OK] 主 app Info.plist 已修正并通过自检")


if __name__ == "__main__":
    main()
