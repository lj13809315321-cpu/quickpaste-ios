//
//  MozhiHostArbiterHook.h
//  v1.8.32：iOS 26.4+ 键盘仲裁器宿主包名捕获。
//
//  Apple 在 iOS 26.4 移除了键盘扩展读宿主 App 包名的旧私有链
//  (_hostPID -> PKService.personalities -> xpc_connection_copy_bundle_id)，
//  导致所有第三方键盘的 hostApplicationBundleId 变成 nil，
//  连带「语音输入 / 听写结束后自动跳回来源 App」失效（KeyboardKit FB22247647）。
//  新系统改由 _UIKeyboardArbiterClientInputDestination 的
//  queue_keyboardChanged:onComplete: 回调携带 _sourceBundleIdentifier。
//
//  全部私有符号运行时解析，静态不引用，类不存在时静默失败。
//

#import <Foundation/Foundation.h>

/// 返回本次键盘会话内捕获到的宿主 App 包名；没有则 nil。
FOUNDATION_EXPORT NSString * _Nullable MozhiCapturedHostBundleId(void);
/// 捕获代数，每收到一次合法宿主事件 +1。
FOUNDATION_EXPORT uint64_t MozhiCapturedHostGeneration(void);
/// 主动向仲裁器发一次 ping，请求投递一次 destination 事件。
/// 是「请求」不是保证；调用方必须能接受 nil。
FOUNDATION_EXPORT void MozhiPingKeyboardArbiter(void);
/// 键盘收起 / 宿主会话结束时清掉缓存，避免跨 App 串值。
FOUNDATION_EXPORT void MozhiResetCapturedHost(void);
