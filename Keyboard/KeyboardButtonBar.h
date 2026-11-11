//
//  KeyboardButtonBar.h
//  iOS 自定义键盘扩展（UIInputViewController）专用的底栏快捷按钮
//
//  与 KBEnhancer.h/.m 的区别：
//    KBEnhancer      —— 注入宿主 App 进程，往 UITextEffectsWindow 上叠视图，用 sendAction: 操作第一响应者。
//    KeyboardButtonBar —— 运行在键盘扩展自己的进程，只往 self.inputView 里加一行按钮，
//                        全部动作走 UIInputViewController / UITextDocumentProxy 公开 API。
//
//  因此可以直接放进 App Store 的 Keyboard Extension target，无需越狱、无需注入、无需私有 API。
//  代价见下方「能力边界」：截图、真·撤销、真·全选在扩展进程里没有等价能力。
//
//  能力边界（相对黄白 dylib 的默认四按钮）：
//    关闭键盘 → dismissKeyboard                     完全等价
//    撤销     → 本地插入历史栈 + deleteBackward     近似，仅能回退本会话由本键盘插入的文本
//    光标左移 → adjustTextPositionByCharacterOffset 完全等价，另附右移
//    截图     → 不可实现：扩展进程看不到宿主 App 的窗口层级，也不能截宿主屏幕
//    复制/剪切/粘贴 → 需要 RequestsOpenAccess + 用户在「设置」打开「允许完全访问」；
//                     copy/cut 只能作用于「当前已有选区」（selectedText）
//    全选     → 扩展无法对宿主输入框发起真正的系统级全选（无公开 API）；
//               本类的近似实现 = 先尝试 sendAction(selectAll:)，再把光标前
//               后文拼成的「输入框全文」写入系统剪贴板，效果等价于
//               「全选 + 复制」，随后可用「粘贴」把全文带到任何地方。
//
//  把本文件与 KeyboardButtonBar.m 拖进 Keyboard Extension target，
//  接入示例见 KeyboardViewController.h/.m，配置键见 KeyboardExtension-Info.plist。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KBKeyboardAction) {
    KBKeyboardActionDismiss = 0,       // 关闭键盘：dismissKeyboard
    KBKeyboardActionUndo,              // 撤销（近似）：回退本会话最后一次插入
    KBKeyboardActionCursorLeft,        // 光标左移一格
    KBKeyboardActionCursorRight,       // 光标右移一格
    KBKeyboardActionBackspace,         // 退格删一个字符
    KBKeyboardActionCopy,              // 复制当前选区（需完全访问）
    KBKeyboardActionCut,               // 剪切当前选区（需完全访问）
    KBKeyboardActionPaste,             // 粘贴剪贴板文本（需完全访问）
    KBKeyboardActionNextKeyboard,      // 切换到下一个输入法
    KBKeyboardActionSelectAll,         // 全选（近似）：尝试系统全选 + 输入框全文复制到剪贴板
    KBKeyboardActionCount              // 哨兵，不是按钮
};

@interface KBKeyboardButtonBar : UIView

/// 宿主键盘控制器，弱引用避免循环持有。
- (instancetype)initWithInputViewController:(UIInputViewController *)controller;

/// 从 Info.plist 读取 KBButtonBarActions / KBButtonBarSpacing /
/// KBButtonBarEdgeInset / KBButtonBarHeight 并构造好一条按钮栏。
+ (instancetype)barWithConfigurationFromBundle:(NSBundle *)bundle
                                hostController:(UIInputViewController *)controller;

/// 把配置里的动作名数组（dismiss / undo / cursorLeft / paste ...）转成
/// buttonActions 可直接使用的枚举数组。容器 App 通过 App Group 下发按钮列表时用它。
+ (NSArray<NSNumber *> *)actionsFromNames:(NSArray<NSString *> *)names;

/// 显示的按钮及顺序。默认：关闭键盘 / 撤销 / 光标左移 / 光标右移
/// （黄白默认四按钮里的「截图」在扩展里不可实现，用光标右移补位）。
@property (nonatomic, copy) NSArray<NSNumber *> *buttonActions;

/// v1.8.35 定制菜单栏：按功能 id 渲染（id 定义在 Shared/QPBarCatalog.swift）。
/// 设置后 kb_rebuildButtons 走 id 分支，点击统一回调 onAction 交给 Swift 分发；
/// 老的 buttonActions 路径保留给「没有配置」的兜底，一行不动。
@property (nonatomic, copy) NSArray<NSString *> *actionIDs;
@property (nonatomic, copy, nullable) void (^onAction)(NSString *actionID);

/// 按 id 执行已有的动作（切换/关闭/撤销/光标/复制/剪切/粘贴/全选/删除）。
/// 返回 YES = 已由本类处理；NO = 新动作，交给 Swift 侧 performBarAction。
- (BOOL)performActionForID:(NSString *)actionID;
/// v1.8.35 新增：重做（撤销的反操作，共用同一份插入历史）。
- (void)performRedo;
/// v1.8.35「中文转译」：ICU 简↔繁转换（键盘扩展没有系统翻译接口，用最接近的行为实现，不砍项）。
+ (NSString *)kb_translateChinese:(NSString *)text traditional:(BOOL)traditional;

/// 按钮之间的间距，默认 10（pt）。
@property (nonatomic, assign) CGFloat buttonSpacing;

/// 距键盘左右边缘的留白，默认 12（pt）。设置它会同时覆盖 leftInset / rightInset。
@property (nonatomic, assign) CGFloat edgeInset;

/// 左右分别留白，默认均为 12（pt）。把按钮栏塞进已有底栏、需要给左边的
/// 切换键 / 右边的听写键让位时，单独调这两个值——对应黄白设置页的
/// 「到地球间距」「到听写间距」。配置键：KBButtonBarLeftInset / KBButtonBarRightInset。
@property (nonatomic, assign) CGFloat leftInset;
@property (nonatomic, assign) CGFloat rightInset;

/// 按钮栏高度，默认 44（pt）。接入时把它作为 heightAnchor 的常量加进 inputView 总高度。
@property (nonatomic, assign) CGFloat barHeight;

/// 键盘每次调用 insertText: 后把插入的文本交给按钮栏，撤销按钮才有可回退的记录。
/// 忽略系统/宿主直接修改的文本（那些不在本进程的可控范围内）。
- (void)recordInsertedText:(NSString *)text;

/// 切换输入框 / 键盘收起 / 用户手动移动光标后调用，作废撤销栈，避免删错位置。
- (void)clearHistory;

/// 把按钮栏嵌进输入法**已有的底栏容器**：按钮落在原来那一行、键盘高度不变。
/// 容器 bounds 变化时自动跟随；给左侧切换键 / 右侧听写键让位用 leftInset / rightInset。
/// 这是「不增高、还是原来那一排」的推荐接法；只在没有自绘底栏时才退回贴底新增一行。
- (void)embedInBottomRow:(UIView *)bottomRow;

/// 动作结果的提示回调（全选/复制/粘贴的成败与字数），由宿主键盘显示 toast。
/// 不设置则这些动作静默执行。
@property (nonatomic, copy, nullable) void (^onFeedback)(NSString *message);

/// 完全访问状态变化时（viewDidAppear:、用户改完设置回来）刷新按钮可用状态。
- (void)refreshAccessState;

@end

NS_ASSUME_NONNULL_END
