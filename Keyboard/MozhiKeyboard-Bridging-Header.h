//
//  MozhiKeyboard-Bridging-Header.h
//  把 ObjC 参考实现（路线 E：黄白风格底栏按钮）暴露给 Swift 工程。
//
//  说明：
//  - 实现源文件位于 Keyboard/KeyboardButtonBar.{h,m}（由 XcodeGen 的 - Keyboard 源目录扫描编译）。
//  - QuickPasteKBEnhancement/reference-objc/ 里的是「文档/对照」副本，不要重复编译。
//  - 只暴露需要的头文件即可，避免把 Objective-C 内部细节泄露给 Swift 侧。
//

#import "KeyboardButtonBar.h"
// v1.8.32：iOS 26.4+ 键盘仲裁器宿主包名捕获（ObjC +load 安装 hook）。
// 只编进键盘扩展 target；主 App target 不引用这些 C 函数。
#import "MozhiHostArbiterHook.h"
