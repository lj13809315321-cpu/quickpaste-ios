//
//  MozhiHostArbiterHook.m
//  v1.8.32：iOS 26.4+ 宿主 App 包名捕获（键盘扩展专用）。
//
//  参考 KeyboardHostBundleID（MIT）与 KeyboardKit 的 FB22247647 说明：
//  iOS 26.4 起 _hostPID -> PKService -> xpc_connection_copy_bundle_id 链失效，
//  宿主切换事件改由
//  -[_UIKeyboardArbiterClientInputDestination queue_keyboardChanged:onComplete:]
//  投递，change 参数带 KVC key _sourceBundleIdentifier。
//
//  设计原则：
//   · 所有私有类名 / selector 全部运行时解析，静态不引用，类不存在就静默失败；
//   · +load 安装（早于 UIKit 首次 arbiter 派发），ping 时再懒装一次兜底；
//   · 全程 @try/@catch + respondsToSelector，绝不因私有 API 变化崩溃；
//   · 只在键盘出现 / 点击时各 ping 一次，不轮询、不占主线程。
//

#import "MozhiHostArbiterHook.h"
#import <objc/runtime.h>
#import <pthread.h>

static NSString *gCapturedHost = nil;
static uint64_t gGeneration = 0;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL gInstalled = NO;
static IMP gOriginalQueueChanged = NULL;

static BOOL MozhiLooksLikeBundleId(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    if (s.length < 4 || s.length > 120) return NO;
    if ([s rangeOfString:@"."].location == NSNotFound) return NO;
    NSString *own = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([s isEqualToString:own] || [s hasPrefix:@"app.mulberry6323"]) return NO;
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
                          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [[s stringByTrimmingCharactersInSet:ok] length] == 0;
}

static void MozhiStoreHost(NSString *host) {
    if (!MozhiLooksLikeBundleId(host)) return;
    pthread_mutex_lock(&gLock);
    gCapturedHost = [host copy];
    gGeneration += 1;
    pthread_mutex_unlock(&gLock);
}

/// swizzle 后的 queue_keyboardChanged:onComplete: 实现。
/// 从 change（不是 self）上 KVC 读 _sourceBundleIdentifier，然后原样转发。
static void MozhiQueueChangedTrampoline(id self, SEL _cmd, id change, id onComplete) {
    @try {
        if (change && [change respondsToSelector:NSSelectorFromString(@"valueForKey:")]) {
            id raw = [change valueForKey:@"_sourceBundleIdentifier"];
            MozhiStoreHost(raw);
        }
    } @catch (NSException *e) {
        (void)e; // 私有 key 变了就当没拿到，绝不让扩展崩
    }
    if (gOriginalQueueChanged) {
        ((void (*)(id, SEL, id, id))gOriginalQueueChanged)(self, _cmd, change, onComplete);
    }
}

static void MozhiInstallHook(void) {
    if (gInstalled) return;
    Class client = NSClassFromString(@"_UIKeyboardArbiterClient");
    Class dest = NSClassFromString(@"_UIKeyboardArbiterClientInputDestination");
    if (!client || !dest) return; // iOS 16 ~ 26.3：没有这套 arbiter，走旧链

    // 先确认目标方法真的存在；不存在就一个系统行为都不改，
    // 避免把 +enabled 强行打开却没有我们的 trampoline 接管。
    SEL sel = NSSelectorFromString(@"queue_keyboardChanged:onComplete:");
    Method m = class_getInstanceMethod(dest, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    if (!orig || orig == (IMP)MozhiQueueChangedTrampoline) return;

    @try {
        // ① 键盘扩展进程里 +[_UIKeyboardArbiterClient enabled] 默认返回 NO，
        //    整套 destination-changed 派发会被跳过，强制成 YES 才会调 trampoline。
        Method enabledM = class_getClassMethod(client, NSSelectorFromString(@"enabled"));
        if (enabledM) {
            IMP yesImp = imp_implementationWithBlock(^BOOL(id _self) { (void)_self; return YES; });
            if (yesImp) method_setImplementation(enabledM, yesImp);
        }
        // ② 替换实例方法，保留原 IMP 并原样转发。
        gOriginalQueueChanged = orig;
        method_setImplementation(m, (IMP)MozhiQueueChangedTrampoline);
        gInstalled = YES;
    } @catch (NSException *e) { (void)e; }
}

/// dyld 加载镜像时安装，早于 Swift 运行时与 UIKit 首次 arbiter 派发。
@interface MozhiHostArbiterInstaller : NSObject
@end
@implementation MozhiHostArbiterInstaller
+ (void)load {
    @autoreleasepool { MozhiInstallHook(); }
}
@end

NSString * _Nullable MozhiCapturedHostBundleId(void) {
    NSString *v = nil;
    pthread_mutex_lock(&gLock);
    v = [gCapturedHost copy];
    pthread_mutex_unlock(&gLock);
    return v;
}

uint64_t MozhiCapturedHostGeneration(void) {
    uint64_t v = 0;
    pthread_mutex_lock(&gLock);
    v = gGeneration;
    pthread_mutex_unlock(&gLock);
    return v;
}

void MozhiResetCapturedHost(void) {
    pthread_mutex_lock(&gLock);
    gCapturedHost = nil;
    pthread_mutex_unlock(&gLock);
}

void MozhiPingKeyboardArbiter(void) {
    // 类可能在 +load 之后才注册，这里再懒装一次。
    if (!gInstalled) MozhiInstallHook();
    @try {
        Class client = NSClassFromString(@"_UIKeyboardArbiterClient");
        if (!client) return;
        SEL sharedSel = NSSelectorFromString(@"automaticSharedArbiterClient");
        if (![client respondsToSelector:sharedSel]) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id arbiter = [client performSelector:sharedSel];
#pragma clang diagnostic pop
        if (!arbiter) return;
        SEL checkSel = NSSelectorFromString(@"checkConnection");
        if ([arbiter respondsToSelector:checkSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [arbiter performSelector:checkSel];
#pragma clang diagnostic pop
        }
    } @catch (NSException *e) { (void)e; }
}
