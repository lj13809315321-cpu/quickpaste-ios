//
//  KeyboardButtonBar.m
//  iOS 键盘扩展专用底栏：只使用 App Extension 允许的公开 API。
//

#import "KeyboardButtonBar.h"

static NSInteger const kKBBarTagBase = 0x4B420100;
static NSUInteger const kKBBarMaxHistory = 50;

static NSString * const kKBBarKeyActions = @"KBButtonBarActions";
static NSString * const kKBBarKeySpacing = @"KBButtonBarSpacing";
static NSString * const kKBBarKeyInset   = @"KBButtonBarEdgeInset";
static NSString * const kKBBarKeyLeft    = @"KBButtonBarLeftInset";
static NSString * const kKBBarKeyRight   = @"KBButtonBarRightInset";
static NSString * const kKBBarKeyHeight  = @"KBButtonBarHeight";

/// 计算「用户可感知的字符数」而不是 UTF-16 长度，避免 emoji / 组合字符被删两次。
static NSUInteger KBBarComposedLength(NSString *text) {
    __block NSUInteger count = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString * _Nullable substring, NSRange subRange,
                                       NSRange enclosingRange, BOOL * _Nonnull stop) {
        (void)substring; (void)subRange; (void)enclosingRange; (void)stop;
        count += 1;
    }];
    return count;
}

static NSDictionary<NSString *, NSNumber *> *KBBarActionMap(void) {
    static NSDictionary<NSString *, NSNumber *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"dismiss":      @(KBKeyboardActionDismiss),
            @"undo":         @(KBKeyboardActionUndo),
            @"cursorLeft":   @(KBKeyboardActionCursorLeft),
            @"cursorRight":  @(KBKeyboardActionCursorRight),
            @"backspace":    @(KBKeyboardActionBackspace),
            @"copy":         @(KBKeyboardActionCopy),
            @"cut":          @(KBKeyboardActionCut),
            @"paste":        @(KBKeyboardActionPaste),
            @"nextKeyboard": @(KBKeyboardActionNextKeyboard),
            @"selectAll":    @(KBKeyboardActionSelectAll),
        };
    });
    return map;
}

@interface KBKeyboardButtonBar ()
@property (nonatomic, weak) UIInputViewController *hostController;
@property (nonatomic, strong) NSMutableArray<UIButton *> *buttons;
@property (nonatomic, strong) NSMutableArray<NSString *> *insertHistory;
+ (NSString *)kb_titleForAction:(KBKeyboardAction)action;
+ (BOOL)kb_requiresFullAccessForAction:(KBKeyboardAction)action;
- (void)kb_rebuildButtons;
- (void)kb_buttonTapped:(UIButton *)sender;
- (void)kb_performAction:(KBKeyboardAction)action;
- (BOOL)kb_hasFullAccess;
- (void)kb_undoWithProxy:(id<UITextDocumentProxy>)proxy;
- (void)kb_copySelectionWithProxy:(id<UITextDocumentProxy>)proxy cut:(BOOL)cut;
- (void)kb_pasteWithProxy:(id<UITextDocumentProxy>)proxy;
- (void)kb_selectAllWithProxy:(id<UITextDocumentProxy>)proxy;
@end

@implementation KBKeyboardButtonBar

#pragma mark - 构造与配置

- (instancetype)initWithInputViewController:(UIInputViewController *)controller {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _hostController = controller;
        _buttonSpacing = 10;
        _edgeInset = 12;
        _leftInset = 12;
        _rightInset = 12;
        _barHeight = 44;
        _buttons = [NSMutableArray array];
        _insertHistory = [NSMutableArray array];
        _buttonActions = @[@(KBKeyboardActionDismiss), @(KBKeyboardActionUndo),
                           @(KBKeyboardActionCursorLeft), @(KBKeyboardActionCursorRight)];
        self.backgroundColor = [UIColor clearColor];
        [self kb_rebuildButtons];
    }
    return self;
}

+ (instancetype)barWithConfigurationFromBundle:(NSBundle *)bundle
                                hostController:(UIInputViewController *)controller {
    KBKeyboardButtonBar *bar = [[self alloc] initWithInputViewController:controller];
    NSDictionary<NSString *, id> *info = [bundle infoDictionary] ?: @{};

    id actionNames = info[kKBBarKeyActions];
    if ([actionNames isKindOfClass:[NSArray class]]) {
        NSArray<NSNumber *> *parsed = [self actionsFromNames:(NSArray *)actionNames];
        if (parsed.count) {
            bar.buttonActions = parsed;
        }
    }

    id spacing = info[kKBBarKeySpacing];
    if ([spacing respondsToSelector:@selector(doubleValue)]) {
        bar.buttonSpacing = (CGFloat)[spacing doubleValue];
    }
    id inset = info[kKBBarKeyInset];
    if ([inset respondsToSelector:@selector(doubleValue)]) {
        bar.edgeInset = (CGFloat)[inset doubleValue];
    }
    // 可选：左右分别留白，覆盖 edgeInset 的对称值。把按钮塞进已有底栏时用来给
    // 左侧切换键 / 右侧听写键让位，对应黄白的「到地球间距」「到听写间距」。
    id left = info[kKBBarKeyLeft];
    if ([left respondsToSelector:@selector(doubleValue)]) {
        bar.leftInset = (CGFloat)[left doubleValue];
    }
    id right = info[kKBBarKeyRight];
    if ([right respondsToSelector:@selector(doubleValue)]) {
        bar.rightInset = (CGFloat)[right doubleValue];
    }
    id height = info[kKBBarKeyHeight];
    if ([height respondsToSelector:@selector(doubleValue)]) {
        bar.barHeight = (CGFloat)[height doubleValue];
    }
    [bar refreshAccessState];
    return bar;
}

+ (NSArray<NSNumber *> *)actionsFromNames:(NSArray<NSString *> *)names {
    NSDictionary<NSString *, NSNumber *> *map = KBBarActionMap();
    NSMutableArray<NSNumber *> *parsed = [NSMutableArray array];
    for (id name in names ?: @[]) {
        NSNumber *value = [name isKindOfClass:[NSString class]] ? map[name] : nil;
        if (value && value.integerValue < KBKeyboardActionCount) {
            [parsed addObject:value];
        }
    }
    return parsed;
}

- (void)embedInBottomRow:(UIView *)bottomRow {
    if (!bottomRow) {
        return;
    }
    self.frame = bottomRow.bounds;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [bottomRow addSubview:self];
    [self setNeedsLayout];
    [self refreshAccessState];
}

- (void)setEdgeInset:(CGFloat)edgeInset {
    _edgeInset = edgeInset;
    _leftInset = edgeInset;
    _rightInset = edgeInset;
    [self setNeedsLayout];
}

- (void)setButtonActions:(NSArray<NSNumber *> *)buttonActions {
    _buttonActions = [buttonActions copy] ?: @[];
    [self kb_rebuildButtons];
}

#pragma mark - 按钮渲染

+ (NSString *)kb_titleForAction:(KBKeyboardAction)action {
    switch (action) {
        case KBKeyboardActionDismiss:      return @"关闭";
        case KBKeyboardActionUndo:         return @"撤销";
        case KBKeyboardActionCursorLeft:   return @"←";
        case KBKeyboardActionCursorRight:  return @"→";
        case KBKeyboardActionBackspace:    return @"退格";
        case KBKeyboardActionCopy:         return @"复制";
        case KBKeyboardActionCut:          return @"剪切";
        case KBKeyboardActionPaste:        return @"粘贴";
        case KBKeyboardActionNextKeyboard: return @"切换";
        case KBKeyboardActionSelectAll:    return @"全选";
        case KBKeyboardActionCount:        return @"";
    }
    return @"";
}

+ (BOOL)kb_requiresFullAccessForAction:(KBKeyboardAction)action {
    switch (action) {
        case KBKeyboardActionDismiss:      return NO;
        case KBKeyboardActionUndo:         return NO;
        case KBKeyboardActionCursorLeft:   return NO;
        case KBKeyboardActionCursorRight:  return NO;
        case KBKeyboardActionBackspace:    return NO;
        case KBKeyboardActionCopy:         return YES;
        case KBKeyboardActionCut:          return YES;
        case KBKeyboardActionPaste:        return YES;
        case KBKeyboardActionNextKeyboard: return NO;
        case KBKeyboardActionSelectAll:    return YES;
        case KBKeyboardActionCount:        return NO;
    }
    return NO;
}

- (void)kb_rebuildButtons {
    for (UIButton *button in self.buttons) {
        [button removeFromSuperview];
    }
    [self.buttons removeAllObjects];

    for (NSNumber *value in self.buttonActions) {
        KBKeyboardAction action = (KBKeyboardAction)value.integerValue;
        if (action < 0 || action >= KBKeyboardActionCount) {
            continue;
        }
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = kKBBarTagBase + action;
        // 与 QuickPaste 主工程 QPColor.ink 一致的自适应墨色（深色模式白色图标）
        UIColor *ink = [UIColor colorWithDynamicProvider:^UIColor * (UITraitCollection *trait) {
            return trait.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:240.0 / 255.0 green:241.0 / 255.0 blue:245.0 / 255.0 alpha:1]
                : [UIColor colorWithRed:17.0 / 255.0 green:17.0 / 255.0 blue:17.0 / 255.0 alpha:1];
        }];
        button.tintColor = ink;
        [button setTitleColor:ink forState:UIControlStateNormal];
        [button setTitle:[KBKeyboardButtonBar kb_titleForAction:action]
                forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:15];
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.7;
        [button addTarget:self action:@selector(kb_buttonTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:button];
        [self.buttons addObject:button];
    }
    [self setNeedsLayout];
    [self refreshAccessState];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    NSUInteger count = self.buttons.count;
    if (count == 0 || width <= 0 || height <= 0) {
        return;
    }
    CGFloat usable = width - self.leftInset - self.rightInset
                     - self.buttonSpacing * (count - 1);
    CGFloat buttonWidth = MAX(24, usable / count);
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat x = self.leftInset + i * (buttonWidth + self.buttonSpacing);
        self.buttons[i].frame = CGRectMake(x, 4, buttonWidth, height - 8);
    }
}

- (void)refreshAccessState {
    BOOL fullAccess = [self kb_hasFullAccess];
    for (UIButton *button in self.buttons) {
        KBKeyboardAction action = (KBKeyboardAction)(button.tag - kKBBarTagBase);
        BOOL allowed = ![KBKeyboardButtonBar kb_requiresFullAccessForAction:action] || fullAccess;
        button.enabled = allowed;
        button.alpha = allowed ? 1.0 : 0.4;
    }
}

#pragma mark - 动作分派

- (BOOL)kb_hasFullAccess {
    UIInputViewController *controller = self.hostController;
    if (!controller) {
        return NO;
    }
    if ([controller respondsToSelector:@selector(hasFullAccess)]) {
        return [controller hasFullAccess];
    }
    return NO;
}

- (void)kb_buttonTapped:(UIButton *)sender {
    // 与 QuickPaste 主工程「按键震动」开关共用 qp.cursorHaptic（默认开）
    NSNumber *hapticPref = [[NSUserDefaults standardUserDefaults] objectForKey:@"qp.cursorHaptic"];
    if (hapticPref == nil || hapticPref.boolValue) {
        static UIImpactFeedbackGenerator *gen = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        });
        [gen impactOccurred];
    }
    KBKeyboardAction action = (KBKeyboardAction)(sender.tag - kKBBarTagBase);
    if (action >= 0 && action < KBKeyboardActionCount) {
        [self kb_performAction:action];
    }
    [self refreshAccessState];
}

- (void)kb_performAction:(KBKeyboardAction)action {
    UIInputViewController *controller = self.hostController;
    if (!controller) {
        return;
    }
    id<UITextDocumentProxy> proxy = controller.textDocumentProxy;
    switch (action) {
        case KBKeyboardActionDismiss:
            [controller dismissKeyboard];
            break;
        case KBKeyboardActionUndo:
            [self kb_undoWithProxy:proxy];
            break;
        case KBKeyboardActionCursorLeft:
            [proxy adjustTextPositionByCharacterOffset:-1];
            break;
        case KBKeyboardActionCursorRight:
            [proxy adjustTextPositionByCharacterOffset:1];
            break;
        case KBKeyboardActionBackspace:
            [proxy deleteBackward];
            break;
        case KBKeyboardActionCopy:
            [self kb_copySelectionWithProxy:proxy cut:NO];
            break;
        case KBKeyboardActionCut:
            [self kb_copySelectionWithProxy:proxy cut:YES];
            break;
        case KBKeyboardActionPaste:
            [self kb_pasteWithProxy:proxy];
            break;
        case KBKeyboardActionNextKeyboard:
            [controller advanceToNextInputMode];
            break;
        case KBKeyboardActionSelectAll:
            [self kb_selectAllWithProxy:proxy];
            break;
        case KBKeyboardActionCount:
            break;
    }
}

#pragma mark - 撤销（近似）

- (void)recordInsertedText:(NSString *)text {
    if (text.length == 0) {
        return;
    }
    [self.insertHistory addObject:[text copy]];
    if (self.insertHistory.count > kKBBarMaxHistory) {
        [self.insertHistory removeObjectAtIndex:0];
    }
}

- (void)clearHistory {
    [self.insertHistory removeAllObjects];
}

- (void)kb_undoWithProxy:(id<UITextDocumentProxy>)proxy {
    NSString *last = self.insertHistory.lastObject;
    if (last.length == 0) {
        [proxy deleteBackward];
        return;
    }
    [self.insertHistory removeLastObject];

    NSString *before = proxy.documentContextBeforeInput ?: @"";
    if ([before hasSuffix:last]) {
        NSUInteger steps = KBBarComposedLength(last);
        for (NSUInteger i = 0; i < steps; i++) {
            [proxy deleteBackward];
        }
    } else {
        // 光标被移动过或文档被外部改过，历史栈已失效：只删一个字符并清空，避免误删。
        [proxy deleteBackward];
        [self clearHistory];
    }
}

#pragma mark - 剪贴板（需完全访问）

- (void)kb_copySelectionWithProxy:(id<UITextDocumentProxy>)proxy cut:(BOOL)cut {
    if (![self kb_hasFullAccess]) {
        return;
    }
    NSString *selected = proxy.selectedText;
    if (selected.length == 0) {
        return;
    }
    [[UIPasteboard generalPasteboard] setString:selected];
    if (cut) {
        NSUInteger steps = KBBarComposedLength(selected);
        for (NSUInteger i = 0; i < steps; i++) {
            [proxy deleteBackward];
        }
        [self clearHistory];
    }
}

- (void)kb_pasteWithProxy:(id<UITextDocumentProxy>)proxy {
    if (![self kb_hasFullAccess]) {
        return;
    }
    NSString *text = [UIPasteboard generalPasteboard].string;
    if (text.length == 0) {
        return;
    }
    [proxy insertText:text];
    [self recordInsertedText:text];
}

#pragma mark - 全选（近似）

- (void)kb_selectAllWithProxy:(id<UITextDocumentProxy>)proxy {
    if (![self kb_hasFullAccess]) {
        return;
    }
    // 第一步：尝试标准编辑动作 selectAll:。键盘扩展与宿主分属两个进程，
    // sendAction 走的是扩展进程自己的响应链，能不能落到宿主输入框随系统
    // 版本而异——能落地就是「真全选」，落不了地也不报错，无害。
    @try {
        id app = [[UIApplication class] performSelector:NSSelectorFromString(@"sharedApplication")];
        SEL send = NSSelectorFromString(@"sendAction:to:from:forEvent:");
        if (app && [app respondsToSelector:send]) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                                 [app methodSignatureForSelector:send]];
            [inv setTarget:app];
            [inv setSelector:send];
            SEL selAll = @selector(selectAll:);
            id nilTarget = nil, fromSelf = self, nilEvent = nil;
            [inv setArgument:&selAll atIndex:2];
            [inv setArgument:&nilTarget atIndex:3];
            [inv setArgument:&fromSelf atIndex:4];
            [inv setArgument:&nilEvent atIndex:5];
            [inv invoke];
        }
    } @catch (NSException *ignored) {
        // 私有转发失败不致命，走下面的公开兜底
    }
    // 第二步：公开 API 兜底。光标前后文拼起来 ≈ 输入框全文（部分宿主对
    // 超长文本可能截断，但对聊天输入框基本完整）。写入系统剪贴板后，
    // 效果等价于「全选 + 复制」，用户按「粘贴」即可把全文带到任何地方。
    NSString *before = proxy.documentContextBeforeInput ?: @"";
    NSString *after = proxy.documentContextAfterInput ?: @"";
    NSString *all = [before stringByAppendingString:after];
    if (all.length > 0) {
        [[UIPasteboard generalPasteboard] setString:all];
    }
}

@end
