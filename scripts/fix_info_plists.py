#!/usr/bin/env python3
"""编译后、codesign 之前，把完整 Info.plist 写回主 App 与键盘扩展产物。

背景
----
Xcode 16 + XcodeGen 默认 GENERATE_INFOPLIST_FILE=YES，会忽略仓库中的
App/Info.plist 与 Keyboard/Info.plist，自动生成只包含构建元数据的 plist。
实测产物因此缺失：
  * CFBundleIdentifier  -> 爱思等重签工具导入时判「文件已损坏」
  * NSExtension         -> iOS 不认 .appex 是键盘扩展，装了也不会出现
  * CFBundlePackageType -> 扩展应为 XPC!，自动生成的却是 APPL
  * NSAppTransportSecurity -> 键盘扩展内 URLSession 打不开 http:// 局域网地址

另外，Xcode 构建过程可能就地改写仓库里的 Info.plist，所以本脚本**不依赖源文件**，
直接内置完整的必需字段；仅从 Xcode 生成的 plist 里继承构建元数据。
必须在 codesign 之前执行，否则 _CodeSignature/CodeResources 的哈希会对不上。
"""

import plistlib
import sys
from pathlib import Path

APP_ID = "app.mulberry6323.mozhi"
KEYBOARD_ID = APP_ID + ".keyboard"
KEYBOARD_MODULE = "MozhiKeyboard"

BUILD_META_KEYS = (
    "MinimumOSVersion", "DTPlatformName", "DTPlatformVersion",
    "DTPlatformBuild", "DTSDKName", "DTSDKBuild", "DTXcode",
    "DTXcodeBuild", "DTCompiler", "BuildMachineOSBuild",
    "CFBundleSupportedPlatforms", "UIDeviceFamily", "CFBundleInfoDictionaryVersion",
)

ATS = {"NSAllowsArbitraryLoads": True, "NSAllowsLocalNetworking": True}
LOCAL_DESC = "墨指 需要访问局域网，以连接同一 WiFi 下电脑上的剪贴板同步服务。"
ORIENTATIONS = [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]

MAIN_APP_PLIST = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": "墨指",
    "CFBundleIdentifier": APP_ID,
    "CFBundleExecutable": "Mozhi",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "Mozhi",
    "CFBundlePackageType": "APPL",
    "CFBundleSignature": "????",
    "CFBundleShortVersionString": "1.8.33",
    "CFBundleVersion": "52",
    # v1.8.32：主 App 要跳回微信/抖音等来源 App，公开 open(URL) 必须声明白名单。
    # v1.8.31 只给键盘 plist 加了，主 App 缺这一份 —— 这就是「没跳回来」的硬伤之一。
    "LSApplicationQueriesSchemes": ["mozhi", "weixin", "snssdk1128", "mqq", "sinaweibo", "alipay", "taobao", "xhsdiscover", "sms", "mobilenotes"],
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "16.0",
    "NSAppTransportSecurity": dict(ATS),
    "NSLocalNetworkUsageDescription": LOCAL_DESC,
    "NSPhotoLibraryUsageDescription": "用于选择要同步到电脑的图片。",
    "UILaunchScreen": {},
    # 系统画中画（PiP）连续复制：PiP 期间 App 需要在后台保持运行，
    # 靠 audio background mode + AVAudioSession(.playback) 实现。
    "UIBackgroundModes": ["audio"],
    # 键盘里点「连续复制」跳主 App：mozhi://pip/start
    "CFBundleURLTypes": [{
        "CFBundleURLName": APP_ID,
        "CFBundleURLSchemes": ["mozhi"],
    }],
    # v1.8.26：声明要查询/打开的 scheme，缺它系统可能直接拒绝 URL 打开。
    "LSApplicationQueriesSchemes": ["mozhi", "weixin", "snssdk1128", "mqq", "sinaweibo", "alipay", "taobao", "xhsdiscover", "sms", "mobilenotes"],
    "CFBundleIconName": "AppIcon",
    "UIRequiredDeviceCapabilities": ["arm64"],
    "UISupportedInterfaceOrientations": ORIENTATIONS,
}

KEYBOARD_PLIST = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleDisplayName": "墨指",
    "CFBundleIdentifier": KEYBOARD_ID,
    "CFBundleExecutable": "MozhiKeyboard",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "Mozhi",
    "CFBundlePackageType": "XPC!",
    "CFBundleSignature": "????",
    "CFBundleShortVersionString": "1.8.33",
    "CFBundleVersion": "52",
    "MinimumOSVersion": "16.0",
    # v1.8.26：键盘扩展要打开主 App 的 mozhi:// scheme，系统要求声明查询白名单。
    "LSApplicationQueriesSchemes": ["mozhi", "weixin", "snssdk1128", "mqq", "sinaweibo", "alipay", "taobao", "xhsdiscover", "sms", "mobilenotes"],
    # 键盘扩展里跑 URLSession，这一份 ATS 例外同样不能少
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
        "NSExtensionPrincipalClass": KEYBOARD_MODULE + ".KeyboardViewController",
    },
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
    print("[%s] ATS               = %s" % (name, data.get("NSAppTransportSecurity")))
    ok = got_id == want_id and got_type == want_type and bool(data.get("CFBundleExecutable"))
    ats = data.get("NSAppTransportSecurity") or {}
    if ats.get("NSAllowsArbitraryLoads") is not True or not data.get("NSLocalNetworkUsageDescription"):
        print("[%s] [FATAL] 缺 ATS 例外或本地网络描述" % name)
        ok = False
    return ok


def main():
    app = Path("build/Build/Products/Release-iphoneos/Mozhi.app")
    ext = app / "PlugIns" / "MozhiKeyboard.appex"
    app_plist = app / "Info.plist"
    ext_plist = ext / "Info.plist"

    for p in (app_plist, ext_plist):
        if not p.exists():
            sys.exit("[FATAL] 找不到 %s" % p)

    main_app = patch(app_plist, MAIN_APP_PLIST)
    keyboard = patch(ext_plist, KEYBOARD_PLIST)

    (app / "PkgInfo").write_bytes(b"APPL????")
    (ext / "PkgInfo").write_bytes(b"XPC!????")

    ok = verify("主 app", main_app, APP_ID, "APPL")
    ok = verify("键盘扩展", keyboard, KEYBOARD_ID, "XPC!") and ok

    print("[主 app] UIBackgroundModes = %s" % main_app.get("UIBackgroundModes"))
    print("[主 app] CFBundleURLTypes = %s" % main_app.get("CFBundleURLTypes"))
    if main_app.get("UIBackgroundModes") != ["audio"] or not main_app.get("CFBundleURLTypes"):
        print("[主 app] [FATAL] 缺画中画后台模式或 quickpaste URL scheme")
        ok = False

    ns = keyboard.get("NSExtension") or {}
    attrs = ns.get("NSExtensionAttributes") or {}
    point = ns.get("NSExtensionPointIdentifier")
    principal = ns.get("NSExtensionPrincipalClass")
    print("[键盘扩展] NSExtensionPointIdentifier = %s" % point)
    print("[键盘扩展] NSExtensionPrincipalClass  = %s" % principal)
    print("[键盘扩展] RequestsOpenAccess         = %s" % attrs.get("RequestsOpenAccess"))
    if point != "com.apple.keyboard-service" or not principal or "$(" in principal:
        ok = False
    if attrs.get("RequestsOpenAccess") is not True:
        print("[键盘扩展] [FATAL] 缺 RequestsOpenAccess")
        ok = False

    if not ok:
        sys.exit("[FATAL] Info.plist 关键字段校验失败，终止构建")
    print("[OK] 主 app + 键盘扩展 Info.plist 已修正并通过自检")


if __name__ == "__main__":
    main()
