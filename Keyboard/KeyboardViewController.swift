import UIKit
import ImageIO
import NaturalLanguage

/// QuickPaste v1.6 真·系统键盘（iOS Keyboard Extension）。
///
/// 界面 1:1 对齐 quickpaste-ios-prototype.html 的 renderKeyboard() / syncHead：
///   连接状态头 / 工具条 / 剪贴板卡片 + 💻📱 来源图标 / 图片缩略图 /
///   清空行 / 底行按键 / 浮层菜单。
/// 数据源是电脑端 sync/server.js 的局域网同步服务，不是演示用的本地数组。
/// 前提是用户在 设置 → 通用 → 键盘 → QuickPaste → 打开「允许完全访问」。
final class KeyboardViewController: UIInputViewController {

    private var prefs = KeyboardPrefs()

    private var items: [SyncItem] = []
    private var thumbCache: [String: UIImage] = [:]
    private var syncSig = ""
    private var syncState = "off"       // off / connecting / online / error
    private var syncError = ""
    private var syncCount = 0
    private var lastSync: Date?
    private var backend = ""
    private var pollTimer: Timer?
    /// 主列表实际渲染的数据：本机复制历史 + 画中画抓取记录 + 电脑同步记录
    private var displayItems: [SyncItem] = []

    // MARK: - v1.8.8 筛选 / 排序 / 导出
    /// 类型筛选弹层（漏斗按钮点按）：磨砂圆角小菜单，选中项带 ✓
    private let filterOverlay = UIView()
    private let filterBox = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let filterStack = UIStackView()
    /// 导出弹层（漏斗按钮长按）：TXT / CSV / 图片，发到电脑 sync 服务
    private let exportOverlay = UIView()
    private let exportBox = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let exportStack = UIStackView()
    private weak var filterButton: UIButton?
    private weak var sortButton: UIButton?
    /// 当前滑开的卡片，滑开新的就把旧的收回去
    private weak var openedCard: QPSwipeCard?
    /// 手指正在卡片上滑动/长按：这期间不许重建列表，否则手势立刻作废
    private var cardBusy = false
    /// 交互中被推迟的刷新，松手后补上
    private var pendingListRefresh = false
    /// 还没成功推到电脑的文本（电脑没连上时先排队，连上就补发）
    private var pendingPush: [String] = []
    /// 最近已经推过的文本，避免同一条被反复 POST
    private var pushedRecent: [String] = []
    /// 键盘可见期间【常驻】的剪贴板轮询，与「连续复制 / 画中画」开关完全解耦。
    /// 旧版只在连续复制开启时才轮询，导致弹起键盘后复制第二段必须收起再弹。
    private var pasteboardTimer: Timer?
    /// 本次呼出键盘后抓到的新条数（只用于内部计数）
    private var capturedCount = 0
    /// 主 App 的系统画中画是否**真的**在后台抓（心跳 20 秒内算活）
    private var pipLive = false
    /// 主 App 是否报告「后台读剪贴板被系统拦住」
    private var pipBlocked = false
    /// 连接状态小圆点：绿 = 已连上电脑，红 = 没连上
    private weak var statusDot: UIView?
    private weak var copyButton: UIButton?

    private let root = UIStackView()
    private let toolbar = UIStackView()
    private let symScroll = UIScrollView()
    private let symStack = UIStackView()
    private let tabBar = UIStackView()
    private let listScroll = UIScrollView()
    private let listStack = UIStackView()
    private let calcBox = UIStackView()
    /// 计算模式下整行隐藏，换成计算器自己的「‹返回 / 空格 / 发送」
    private let bottomBar = UIStackView()
    private let menuOverlay = UIView()
    private let menuScroll = UIScrollView()
    private let menuStack = UIStackView()
    /// 长按条目菜单 v1.8.5（按用户图二 1:1）：整个键盘变灰色磨砂，
    /// 被按住的条目**原位浮起**成白卡片带阴影，下方只跟一张半透明灰的
    /// 4 项小菜单。「发送到电脑 / 置顶 / 删除」改为浮起卡片上的圆形小按钮，
    /// 这样菜单主体能贴住截图，同时一个功能都不砍。
    private let cardMenuOverlay = UIView()
    private let cardMenuDim = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let cardMenuShade = UIView()
    private let cardMenuLift = UIView()
    private let cardMenuLiftText = UILabel()
    private let cardMenuLiftSub = UILabel()
    private let cardMenuLiftThumb = UIImageView()
    private let cardMenuShell = UIView()
    /// 被长按的那一条：浮起期间把原位卡片暂时隐去，才有「提起来」的感觉
    private weak var cardMenuAnchorView: UIView?
    private let cardMenuBox = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let cardMenuScroll = UIScrollView()
    private let cardMenuStack = UIStackView()
    private let imageOverlay = UIView()
    private let imageBig = UIImageView()
    private var imageCloseButton: UIButton?
    /// 分词 / 预览 / 编辑共用的小面板
    private let sheetOverlay = UIView()
    private let sheetStack = UIStackView()
    private weak var editField: UITextView?
    /// v1.6 完整多页设置界面（设置首页 / 键盘设置 / 快捷符号 / 连续复制 /
    /// 局域网同步 / 6 篇教程 / 历史 / 最近删除 / 引导 / 关于）
    private let settings = KeyboardSettings()

    private var heightConstraint: NSLayoutConstraint!
    private var isCalcMode = false
    private var undoStack: [String] = []
    private var spaceOriginX: CGFloat = 0
    private var spaceLastSteps = 0
    /// ✕ 键左滑逐字符退删的位移基准与已删步数（对齐空格滑光标的手感）
    private var deleteOriginX: CGFloat = 0
    private var deleteDeletedSteps = 0
    /// 空格滑光标的离散步进震动：选择反馈器专用于「一次一格」的场景，
    /// 系统会自动节流，快速滑动不会震成一团。
    private var cursorFeedback: UISelectionFeedbackGenerator?
    private var currentImageItem: SyncItem?
    /// 路线 E：底部快捷条（黄白风格：切换/关闭/粘贴/撤销/←/→）
    private var kbBar: KBKeyboardButtonBar?
    private let kbBarRow = UIView()
    /// 键盘总高度 = 用户设定高度 + 底部快捷条高度
    private var kbBarHeight: CGFloat { kbBar?.barHeight ?? 0 }

    private var client: SyncClient {
        SyncClient(url: prefs.syncURL, pair: prefs.syncPair)
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        // iOS 26 起系统给键盘画整体圆角玻璃底（键盘顶部那截灰带就是它），
        // 根视图必须透明才能融入系统玻璃底、和宿主 App 背景连成一片
        //（Apple 开发者论坛 thread 793686 的官方适配结论）。按钮/卡片自带底色不受影响。
        view.backgroundColor = .clear

        // 路线 E：底部快捷条先就位，root 的底部约束要抬到它之上
        setupKBButtonBar()
        heightConstraint = view.heightAnchor.constraint(equalToConstant: prefs.height + kbBarHeight)
        heightConstraint.priority = .required
        heightConstraint.isActive = true

        buildRoot()
        // 状态头整块去掉：68px 全留给剪贴板列表，连接状态改为工具条上的小圆点
        buildToolbar()
        buildTabs()
        buildList()
        buildCalc()
        // 「清空剪贴板」不再单独占一行，改为列表最下边的可滚动条目
        buildBottomBar()
        buildMenu()
        buildCardMenu()
        buildFilterMenu()
        buildExportMenu()
        buildSheet()
        buildImageOverlay()
        settings.delegate = self
        settings.install(in: view)

        // 交互补读：键盘扩展进程可能被系统短暂挂起，用户每次点按也顺手读一次剪贴板，
        // 保证「复制完第二段回到键盘」立刻能看到，不必收起再弹出。
        let tap = UITapGestureRecognizer(target: self, action: #selector(userDidInteract))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)

        refreshHead()
        refreshTabBar()
        refreshCopyButton()
        refreshSymbols()
        refreshList()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if prefs.adoptPasteboardURL() {
            showToast("已采用剪贴板里的电脑地址")
        }
        // 「历史保留时间」：每次呼出键盘执行一次过期清理
        let pruned = prefs.pruneHistory()
        if pruned > 0 && prefs.savedTip { showToast("已清理 \(pruned) 条过期记录") }
        // ★ 每次呼出键盘都强制读一次剪贴板，然后启动常驻轮询。
        // 不再依赖「连续复制」开关：只要键盘在，复制第 2、3、N 段都会自动进列表。
        capturedCount = 0
        cardBusy = false            // 上次收起键盘时若正按着卡片，这里重置，别把刷新永久挡住
        pendingListRefresh = false
        startPasteboardTimer()
        checkClipboard(force: true)
        refreshHead()
        refreshTabBar()
        refreshCopyButton()
        refreshCopyOverlay()
        refreshSymbols()
        // 上次在计算器里直接收起键盘的话，这次弹起要回到列表模式
        if isCalcMode { toggleCalcMode() }
        refreshList()
        pull(showConnecting: true)
        startPolling()
        syncCaptureState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 用户可能刚从系统设置改过「允许完全访问」，刷新粘贴按钮可用态
        kbBar?.refreshAccessState()
        // iOS 16+ 首次读取会弹「是否允许粘贴」，弹窗关闭后分两次补读，
        // 覆盖用户点「允许」较慢的情况。
        for delay in [0.35, 1.20] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.checkClipboard(force: true)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 撤销栈只在同一个输入框会话内有效，收起键盘即作废
        kbBar?.clearHistory()
        stopPolling()
        stopPasteboardTimer()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let totalHeight = prefs.height + kbBarHeight
        if heightConstraint.constant != totalHeight {
            heightConstraint.constant = totalHeight
        }
    }

    /// 读一次系统剪贴板并写入本机历史。返回是否新增了记录。
    @discardableResult
    private func adoptClipboardText() -> Bool {
        guard hasFullAccess,
              let s = UIPasteboard.general.string?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return false }
        // 只有纯「http://IP:8787」这种服务地址才当配置吞掉；普通网址照常进历史，
        // 避免把用户复制的链接误判成电脑地址却又不显示。
        if isServerAddress(s) && prefs.adoptPasteboardURL() { return true }
        // 用户刚删掉 / 清空的正是这条：不许抓回来
        guard !prefs.isMuted(s) else { return false }
        return prefs.capture(s)
    }

    private func isServerAddress(_ s: String) -> Bool {
        s.count <= 64 && !s.contains(" ") && !s.contains("\n")
            && (s.hasPrefix("http://") || s.hasPrefix("https://"))
            && s.contains(":8787")
    }

    // MARK: - 剪贴板监听（连续复制的真正实现）

    /// 只要键盘可见就常驻轮询，和「连续复制 / 画中画」开关无关。
    private func startPasteboardTimer() {
        stopPasteboardTimer()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        RunLoop.main.add(t, forMode: .common)
        pasteboardTimer = t
    }

    private func stopPasteboardTimer() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
    }

    @objc private func userDidInteract() {
        checkClipboard(force: true)
    }

    /// ★ 只有 changeCount 真的变了才读正文。
    ///
    /// 旧版额外「每 1.5 秒强制读一次兜底」，副作用很大：删掉一条后，剪贴板里
    /// 还留着那条文字，强读一次就又 capture 回列表 —— 表现就是「删了又回来、
    /// 最后一条永远删不掉」，清空也清不干净。现在改成：
    ///   1. changeCount 变化才读；
    ///   2. 用户删掉 / 清空的内容进墓碑（mutedTexts），剪贴板没换就不抓；
    ///   3. 用户重新复制同一条时（changeCount 变了且正文就是它）墓碑自动解除。
    @discardableResult
    private func checkClipboard(force: Bool = false) -> Bool {
        guard hasFullAccess else { return false }
        let pb = UIPasteboard.general
        let change = pb.changeCount
        let changed = change != prefs.lastSeenChange

        var dirty = false

        // ① 主 App 后台抓到的（画中画小窗）。这一项**每次都读**：
        //    它走的是共享通道，不需要剪贴板权限，键盘一弹起就该把 App
        //    在后台收的每一条都并进本机列表 —— 旧版只在 changeCount 变时才读，
        //    结果就是「弹起键盘只看到最后一条」。
        let shared = QPSharedHistory.read()
        let live = shared.isAlive
        let blockedNow = shared.isBlocked
        if live != pipLive || blockedNow != pipBlocked {
            pipLive = live
            pipBlocked = blockedNow
            refreshCopyButton()
        }
        // 主 App 在后台（画中画）收的条目：并入列表的同时也推到电脑，
        // 否则「键盘收起时复制的」永远只留在手机里。
        for text in shared.items.reversed() where !text.isEmpty {
            // ★ 已收录的条目绝不再走 capture：capture 遇到「已存在但不在首位」会
            //   重排并返回 true，导致每 0.5 秒 refreshList 重建整列，
            //   手指按住卡片不到 0.4 秒就被销毁 → 长按菜单永远弹不出来。
            if !prefs.isMuted(text), !prefs.clips.contains(text), prefs.capture(text) {
                dirty = true
                autoPush(text)
            }
        }

        if force || changed {
            prefs.refreshMute()
            // ② 系统剪贴板正文
            let raw = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty {
                prefs.lastSeenChange = change
            } else if isServerAddress(raw) {
                _ = prefs.adoptPasteboardURL()
                prefs.lastSeenChange = change
            } else if prefs.isMuted(raw) {
                // 刚被删掉 / 清空的就是这条，剪贴板还没换 → 不要再抓回来
                prefs.lastSeenChange = change
            } else {
                if prefs.capture(raw) {
                    dirty = true
                    capturedCount += 1
                    // ★ 复制即同步：手机复制完，电脑端立刻就有这一条
                    autoPush(raw)
                }
                prefs.lastSeenChange = change
            }
        }

        if dirty {
            refreshList()
        }
        return dirty
    }

    // MARK: - 连续复制（键盘内监听 + 主 App 画中画后台监听）

    /// 第三个按钮（⧉）。用户明确要求：**别做成点了没反应的假开关**。
    ///   · 已经开着 → 关掉键盘侧的开关（后台小窗请在小窗上点 ✕）；
    ///   · 没开 → 立刻变蓝 + 让 App 记住「下次打开就自动开」，并尝试把 App 叫到前台。
    /// 旧版跳转失败还弹一整块「打开 QuickPaste」的指引面板，点了照样不动 ——
    /// 用户原话「弹也跳转不了有啥用」。现在不弹面板，只用一句 toast 如实说跳没跳成。
    private func toggleContinuous() {
        guard hasFullAccess else {
            showToast("请先在 设置 → 键盘 → QuickPaste 开启「允许完全访问」")
            return
        }
        let shared = QPSharedHistory.read()
        pipLive = shared.isAlive
        pipBlocked = shared.isBlocked
        if prefs.continuous {
            prefs.continuous = false
            QPSharedHistory.setWant(false)
            refreshCopyButton()
            showToast("已关闭键盘内连续复制；后台小窗请点小窗上的 ✕")
            return
        }

        prefs.continuous = true
        capturedCount = 0
        refreshCopyButton()
        // 让主 App 一打开就自动开画中画（不依赖这次跳转是否成功）
        QPSharedHistory.setWant(true)
        if pipLive && !pipBlocked {
            showToast("连续复制已开启（后台小窗在抓）")
            return
        }
        openMainAppReporting("pip/start") { [weak self] ok in
            if ok {
                self?.showToast("已打开 QuickPaste，小窗会自动开启")
            } else {
                self?.showToast("没跳过去？回主屏点一下 QuickPaste 图标，小窗照样会自动开")
            }
        }
    }

    /// 打开主 App 并**如实回报**结果。
    /// 键盘扩展里 extensionContext.open 基本都被系统拦掉，真正能用的是
    /// 「运行期取 UIApplication.shared 再 openURL:」（第三方输入法都是这么做的）。
    /// 所以先走那条，再等一小会儿看键盘是不是真的被 App 盖住了来判断成败。
    private func openMainAppReporting(_ path: String,
                                      completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "quickpaste://" + path) else {
            completion(false)
            return
        }
        // 先把所有能试的都试一遍（官方 API + UIApplication.shared + 响应链）
        let tried = openURLString(url.absoluteString)
        // 键盘还在原位 = 没跳走；被盖住后本扩展会挂起，这段也就不会跑了
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self else { return }
            let stillHere = self.viewIfLoaded?.window != nil
            completion(tried && !stillHere)
        }
    }

    /// 键盘扩展里打开 URL：把能试的路径全试一遍，任意一条生效即可。
    /// ① 运行期取 UIApplication.shared → openURL:（第三方输入法通用做法，成功率最高）
    /// ② open(_:options:completionHandler:) 新 API 兜底
    /// ③ 官方扩展 API extensionContext.open（多数系统版本对键盘直接拒绝）
    /// ④ 沿响应链找 openURL:
    @discardableResult
    private func openURLString(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        let sel = NSSelectorFromString("openURL:")
        var tried = false

        // ① ② 运行期拿到 UIApplication 实例（扩展里不能直接写 .shared）
        if let app = sharedApplicationInstance() {
            if app.responds(to: sel) {
                // 同一条 URL 只开一次，避免 App 收到两遍
                _ = app.perform(sel, with: url)
                return true
            }
            let sel3 = NSSelectorFromString("open:options:completionHandler:")
            if app.responds(to: sel3), let imp = app.method(for: sel3) {
                typealias OpenFn = @convention(c) (AnyObject, Selector, NSURL,
                                                   NSDictionary,
                                                   @convention(block) (Bool) -> Void) -> Void
                let fn = unsafeBitCast(imp, to: OpenFn.self)
                fn(app, sel3, url as NSURL, NSDictionary(), { _ in })
                tried = true
            }
            if tried { return true }
        }

        // ③ 官方扩展 API（异步，同步拿不到结果）
        if let ctx = extensionContext {
            ctx.open(url, completionHandler: nil)
            tried = true
        }

        // ④ 响应链（有些系统版本只有这条路通）
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: sel) {
                _ = r.perform(sel, with: url)
                return true
            }
            responder = r.next
        }
        return tried
    }

    /// 扩展里不能直接引用 `UIApplication.shared`（编译期会被标成「扩展不可用」），
    /// 运行期从 NSClassFromString 取类对象再 perform 是允许的 —— 这也是各家输入法
    /// 能在键盘里跳回自家 App 的实际做法。
    private func sharedApplicationInstance() -> NSObject? {
        guard let cls = NSClassFromString("UIApplication") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("sharedApplication")
        guard cls.responds(to: sel), let unmanaged = cls.perform(sel) else { return nil }
        return unmanaged.takeUnretainedValue() as? NSObject
    }

    @objc private func openContinuousSettings(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        settings.show(.continuous)
    }

    private func syncCaptureState() {
        refreshCopyButton()
    }

    /// 旧版这里有个深色浮层「连续复制中… 已收 N 条」+ 一行 10.5pt 的小字提示。
    /// 用户反馈：字太小看不清、那行提示没意义、还挡住列表。
    /// 现在状态只在两个地方说：第三个按钮的绿/橙小点，以及系统画中画小窗的大字。
    private func refreshCopyOverlay() {
        refreshCopyButton()
    }

    // MARK: - 同步

    private func pull(showConnecting: Bool) {
        if showConnecting {
            syncState = "connecting"
            refreshHead()
        }
        client.fetch(limit: 30) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let r = result {
                    self.apply(r)
                } else {
                    self.syncError = error ?? "连接失败"
                    self.syncState = "error"
                    self.refreshHead()
                }
            }
        }
    }

    private func apply(_ r: SyncClient.Result) {
        // ⚠️ 签名只看「有哪些条目」，不看时间戳：
        //   服务端对重复内容会刷新 ts，用 ts 参与比较会导致每 3 秒拉一次就重建整列，
        //   手指正在滑/长按的卡片被删掉重建 → 表现成「左右滑没反应、长按不弹菜单」。
        let sig = r.items.prefix(20).map { $0.id }.joined(separator: "|") + "#\(r.items.count)"
        if sig != syncSig {
            syncSig = sig
            items = r.items
            thumbCache.removeAll()
            refreshList()
        }
        syncCount = r.count
        backend = r.backend
        lastSync = Date()
        syncState = "online"
        refreshHead()
        // 之前电脑没连上时排队的内容，现在补发
        flushPendingPush()
    }

    // MARK: - 复制后自动推送到电脑

    /// 复制即同步：抓到新内容就 POST 给电脑。
    /// 电脑没连上不丢，先进队列，等下一次拉取成功再补发。
    private func autoPush(_ text: String) {
        guard prefs.autoPush else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isServerAddress(t) else { return }
        if pushedRecent.contains(t) { return }
        pushedRecent.append(t)
        if pushedRecent.count > 30 { pushedRecent.removeFirst(pushedRecent.count - 30) }

        guard syncState == "online" else {
            enqueuePush(t)
            return
        }
        client.pushText(t) { [weak self] error in
            guard let self = self, error != nil else { return }
            DispatchQueue.main.async {
                // 推失败：撤回「已推」标记并排队，等下次连上重发
                self.pushedRecent.removeAll { $0 == t }
                self.enqueuePush(t)
            }
        }
    }

    private func enqueuePush(_ text: String) {
        guard !pendingPush.contains(text) else { return }
        pendingPush.append(text)
        if pendingPush.count > 20 { pendingPush.removeFirst(pendingPush.count - 20) }
    }

    private func flushPendingPush() {
        guard prefs.autoPush, syncState == "online", !pendingPush.isEmpty else { return }
        let batch = pendingPush
        pendingPush = []
        for t in batch {
            guard !t.isEmpty else { continue }
            client.pushText(t) { [weak self] error in
                guard let self = self, error != nil else { return }
                DispatchQueue.main.async { self.enqueuePush(t) }
            }
        }
    }

    private func startPolling() {
        stopPolling()
        guard prefs.syncAuto else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pull(showConnecting: false)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func sendTextToPc(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("没有可发送的文字")
            return
        }
        client.pushText(text) { [weak self] error in
            DispatchQueue.main.async {
                if let e = error { self?.showToast("发送失败：" + e) }
                else {
                    self?.showToast("已发送到电脑，Ctrl+V 可粘贴")
                    self?.pull(showConnecting: false)
                }
            }
        }
    }

    private func sendInputTextToPc() {
        let proxy = textDocumentProxy
        let t = proxy.selectedText ?? proxy.documentContextBeforeInput ?? ""
        sendTextToPc(t)
    }

    private func sendPasteboardTextToPc() {
        guard hasFullAccess, let s = UIPasteboard.general.string else {
            showToast("剪贴板不可读，请先开启「允许完全访问」")
            return
        }
        sendTextToPc(s)
    }

    private func sendPasteboardImageToPc() {
        guard hasFullAccess, let img = UIPasteboard.general.image,
              let data = img.pngData() else {
            showToast("剪贴板里没有图片（需开启完全访问）")
            return
        }
        client.pushImage(data, mime: "image/png") { [weak self] error in
            DispatchQueue.main.async {
                if let e = error { self?.showToast("发图失败：" + e) }
                else {
                    self?.showToast("图片已发送到电脑，Ctrl+V 可粘贴")
                    self?.pull(showConnecting: false)
                }
            }
        }
    }

    private func deleteItem(id: String?) {
        // 电脑没连上就完全不发请求 —— 旧版这里会一直等到超时，
        // 弹「删除失败：请求超时」，看着像删不掉。
        guard syncState == "online" else {
            syncSig = ""
            showToast("已删除（本机）")
            return
        }
        client.delete(id: id) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.showToast(error == nil ? "已删除" : "已删除（电脑端稍后同步）")
                self.syncSig = ""
                self.pull(showConnecting: false)
            }
        }
    }

    // MARK: - 状态头 (.syncHead)

    private func buildRoot() {
        root.axis = .vertical
        root.spacing = 2
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        // 路线 E：root 底部抬到快捷条之上，整块键盘不与新增底栏重叠
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: kbBarRow.topAnchor)
        ])
    }

    // MARK: - 底部快捷条（路线 E：黄白微信助手底栏等价复刻）

    /// 黄白底栏等价复刻（v1.8.9 按用户要求重排）：
    /// 「切换」整键删掉（不切输入法），「撤销」顶到第一位；
    /// 「←/→」放正中间；末尾新增「全选」（近似 = 全文复制到剪贴板）。
    /// 独立一行贴键盘最底部，不与「返回/空格/发送」底栏冲突。
    private func setupKBButtonBar() {
        let bar = KBKeyboardButtonBar(inputViewController: self)
        bar.buttonActions = KBKeyboardButtonBar.actions(fromNames:
            ["undo", "dismiss", "cursorLeft", "cursorRight", "paste", "selectAll"])
        bar.barHeight = 40
        bar.buttonSpacing = 8
        bar.edgeInset = 8

        kbBarRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(kbBarRow)
        NSLayoutConstraint.activate([
            kbBarRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kbBarRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kbBarRow.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            kbBarRow.heightAnchor.constraint(equalToConstant: bar.barHeight)
        ])
        bar.embed(inBottomRow: kbBarRow)
        kbBar = bar
    }

    /// 路线 E：本键盘插入的文本统一走这里，底部「撤销」才有可回退记录
    /// （扩展撤销只能回退本会话由本键盘插入的文本，无法感知宿主直接改动）
    private func insertText(_ text: String) {
        textDocumentProxy.insertText(text)
        kbBar?.recordInsertedText(text)
    }

    /// 状态头整块已删掉：连接提示只占工具条上一个 9pt 小圆点，
    /// 省下的 68px 全给剪贴板列表。小圆点插在「⋯」和右边黑色 ✕ 之间。
    private func buildStatusDot() {
        let holder = UIView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.widthAnchor.constraint(equalToConstant: 16).isActive = true
        holder.heightAnchor.constraint(equalToConstant: QPTool.size).isActive = true

        let dot = UIView()
        dot.layer.cornerRadius = 4.5
        dot.backgroundColor = QPColor.red
        dot.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9)
        ])
        statusDot = dot
        holder.isUserInteractionEnabled = true
        holder.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                          action: #selector(headTapped)))
        holder.addGestureRecognizer(UILongPressGestureRecognizer(target: self,
                                                                 action: #selector(headLongPressed)))
        toolbar.addArrangedSubview(holder)
    }

    @objc private func headTapped() {
        pull(showConnecting: true)
    }

    /// 长按小圆点直接进「局域网同步」设置页
    @objc private func headLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        settings.show(.sync)
    }

    private func refreshHead() {
        // 只有两种颜色：连上电脑 = 绿；没连上 / 连接中 / 失败 / 未开完全访问 = 红。
        // 不显示任何文字，不占键盘高度。
        statusDot?.backgroundColor = (hasFullAccess && syncState == "online")
            ? QPColor.green : QPColor.red
    }

    // MARK: - 工具条 (.kbToolbar)

    private func buildToolbar() {
        toolbar.axis = .horizontal
        toolbar.spacing = 4
        toolbar.alignment = .center
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        toolbar.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let collapse = toolButton("")
        // HTML 原型 .kbTool.bare + i-kbhide：键盘轮廓 + 两排键点 + 下箭头，透明底
        collapse.setImage(kbHideIcon(QPColor.ink).withRenderingMode(.alwaysOriginal),
                          for: .normal)
        collapse.backgroundColor = .clear
        collapse.addAction(UIAction { [weak self] _ in self?.dismissKeyboard() },
                           for: .touchUpInside)
        let holdCollapse = UILongPressGestureRecognizer(target: self,
                                                        action: #selector(handleMenuPress(_:)))
        holdCollapse.minimumPressDuration = 1.0
        collapse.addGestureRecognizer(holdCollapse)
        toolbar.addArrangedSubview(collapse)

        // v1.8.9：地球键整键删掉（用户要求）——不切换输入法，
        // 切换输入法用系统键盘切换入口。

        // HTML 原型 .kbTool.copyBtn：连续复制一级开关，蓝色=开启；与「同步」无关
        let copyBtn = toolButton("")
        copyBtn.tag = 101
        copyBtn.setImage(copyIcon(QPColor.ink).withRenderingMode(.alwaysTemplate), for: .normal)
        copyButton = copyBtn
        copyBtn.addAction(UIAction { [weak self] _ in self?.toggleContinuous() },
                          for: .touchUpInside)
        let holdCopy = UILongPressGestureRecognizer(target: self,
                                                    action: #selector(openContinuousSettings(_:)))
        holdCopy.minimumPressDuration = 0.6
        copyBtn.addGestureRecognizer(holdCopy)
        toolbar.addArrangedSubview(copyBtn)

        // v1.8.8 剪贴板筛选：点按弹类型筛选菜单（全部/文本/链接/图片/文件），
        // 长按弹导出菜单（TXT / CSV / 图片 -> 发送到电脑）。
        // v1.8.9 改自绘漏斗图标：SF 旧名 line.3.decrease 在 iOS 15 已弃用
        // （现名 line.3.horizontal.decrease），新系统上不渲染导致按钮「隐形」；
        // 自绘与连续复制图标同一套画法，任何系统版本都不会消失。
        let filterBtn = toolButton("")
        filterBtn.setImage(filterIcon(QPColor.ink).withRenderingMode(.alwaysTemplate),
                           for: .normal)
        filterBtn.tintColor = QPColor.ink
        // 显式锁 38×38 并把抗压缩拉满，杜绝被工具条挤出宽度
        filterBtn.widthAnchor.constraint(equalToConstant: QPTool.size).isActive = true
        filterBtn.heightAnchor.constraint(equalToConstant: QPTool.size).isActive = true
        filterBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        filterBtn.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.openFilterMenu(anchor: filterBtn)
        }, for: .touchUpInside)
        let holdFilter = UILongPressGestureRecognizer(target: self,
                                                      action: #selector(handleExportPress(_:)))
        holdFilter.minimumPressDuration = 0.6
        filterBtn.addGestureRecognizer(holdFilter)
        toolbar.addArrangedSubview(filterBtn)
        filterButton = filterBtn

        // v1.8.8 剪贴板排序：↑ = 最新在上（默认，不改变历史行为），
        // 点按切 ↓ = 最旧在上，列表立即重排，方向记住。
        let sortBtn = toolButton("")
        sortBtn.setImage(UIImage(systemName: prefs.sortNewestTop ? "arrow.up" : "arrow.down",
                                 withConfiguration: toolIconConfig())?
                          .withRenderingMode(.alwaysTemplate), for: .normal)
        sortBtn.tintColor = QPColor.ink
        sortBtn.addAction(UIAction { [weak self] _ in self?.toggleSort() },
                          for: .touchUpInside)
        toolbar.addArrangedSubview(sortBtn)
        sortButton = sortBtn

        symScroll.showsHorizontalScrollIndicator = false
        symScroll.translatesAutoresizingMaskIntoConstraints = false
        symStack.axis = .horizontal
        symStack.spacing = 2
        symStack.alignment = .center
        symStack.translatesAutoresizingMaskIntoConstraints = false
        symScroll.addSubview(symStack)
        NSLayoutConstraint.activate([
            symStack.leadingAnchor.constraint(equalTo: symScroll.contentLayoutGuide.leadingAnchor, constant: 4),
            symStack.trailingAnchor.constraint(equalTo: symScroll.contentLayoutGuide.trailingAnchor, constant: -4),
            symStack.topAnchor.constraint(equalTo: symScroll.contentLayoutGuide.topAnchor),
            symStack.bottomAnchor.constraint(equalTo: symScroll.contentLayoutGuide.bottomAnchor),
            symStack.heightAnchor.constraint(equalTo: symScroll.frameLayoutGuide.heightAnchor)
        ])
        symScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        symScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(symScroll)

        // 连接状态小圆点：位置就在「⋯」和最右边黑色 ✕ 的中间
        buildStatusDot()

        let deleteKey = toolButton("✕")
        // 用户要求：删除键保留 76×38 横条，而且【要留底色】—— 让人一眼看出这是个按钮，
        // 其余工具键继续透明。底色用和功能键一致的浅灰，按下去会变深一点。
        deleteKey.backgroundColor = QPColor.keyBg
        deleteKey.setTitleColor(QPColor.ink, for: .normal)
        deleteKey.titleLabel?.font = .systemFont(ofSize: 19, weight: .medium)
        // 用户要求：删除键保留 76×38 横条，高度与其它工具键一致（38）
        deleteKey.widthAnchor.constraint(equalToConstant: 76).isActive = true
        deleteKey.contentHorizontalAlignment = .center
        deleteKey.contentEdgeInsets = .zero
        deleteKey.layer.cornerRadius = QPTool.radius
        deleteKey.clipsToBounds = true
        deleteKey.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.deleteBackward()
        }, for: .touchUpInside)
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(clearInput))
        swipeUp.direction = .up
        deleteKey.addGestureRecognizer(swipeUp)
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(restoreInput))
        swipeDown.direction = .down
        deleteKey.addGestureRecognizer(swipeDown)
        // 用户要求（对齐搜狗输入法）：按住 ✕ 往左滑，按滑动距离逐字符退删
        //（每 10pt 删一个字，光标跟着回退）；上滑清空 / 下滑恢复 /
        // 1 秒长按快捷菜单 / 单击删一个字全部保留。
        let deleteSlide = UILongPressGestureRecognizer(target: self,
                                                       action: #selector(handleDeleteSlide(_:)))
        deleteSlide.minimumPressDuration = 0.15
        deleteSlide.allowableMovement = .greatestFiniteMagnitude
        deleteSlide.cancelsTouchesInView = false
        deleteKey.addGestureRecognizer(deleteSlide)
        let holdDelete = UILongPressGestureRecognizer(target: self,
                                                      action: #selector(handleMenuPress(_:)))
        holdDelete.minimumPressDuration = 1.0
        deleteKey.addGestureRecognizer(holdDelete)
        toolbar.addArrangedSubview(deleteKey)

        root.addArrangedSubview(toolbar)
    }

    private func refreshCopyButton() {
        guard let b = copyButton else { return }
        // 蓝色 = 用户开着连续复制（立即生效，不等 App 那边）
        let on = prefs.continuous
        // 整排图标都没有底色，所以「开着」用蓝色图标表示，与其它图标同一个位置、同一个大小
        b.backgroundColor = .clear
        b.tintColor = on ? QPColor.blue : QPColor.ink
        b.layer.cornerRadius = QPTool.radius
        b.clipsToBounds = false

        // ★ 右上角小点，用来回答「到底在不在抓」：
        //   绿 = 主 App 的画中画小窗活着，收起键盘也会继续抓
        //   橙 = 只是键盘自己在抓（键盘一收就停）
        //   不显示 = 没开连续复制
        b.viewWithTag(903)?.removeFromSuperview()
        guard on else { return }
        let dot = UIView()
        dot.tag = 903
        dot.isUserInteractionEnabled = false
        dot.backgroundColor = pipLive
            ? (pipBlocked ? UIColor.rgb(255, 159, 10) : QPColor.green)
            : UIColor.rgb(255, 159, 10)
        dot.layer.cornerRadius = 4.5
        dot.layer.borderWidth = 1.5
        dot.layer.borderColor = QPColor.bg.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
            dot.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: 1),
            dot.topAnchor.constraint(equalTo: b.topAnchor, constant: -1)
        ])
    }

    private func refreshSymbols() {
        symStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 原型 .kbToolbar .spL/.spR：居左/居中/居右由两端弹性占位实现
        let leadSpacer = UIView(), trailSpacer = UIView()
        leadSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if prefs.align != "left" { symStack.addArrangedSubview(leadSpacer) }

        for symbol in prefs.symbols.prefix(prefs.symbolCount) {
            let b = QPHapticButton(type: .system)
            b.setTitle(symbol, for: .normal)
            // 原型 .kbSym：28×32、#D4D6DE、圆角 8、字号 20
            b.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
            b.setTitleColor(QPColor.ink, for: .normal)
            b.backgroundColor = .clear
            b.layer.cornerRadius = QPTool.radius
            b.widthAnchor.constraint(equalToConstant: QPTool.size).isActive = true
            b.heightAnchor.constraint(equalToConstant: QPTool.size).isActive = true
            b.addAction(UIAction { [weak self] _ in
                self?.insertText(symbol)
            }, for: .touchUpInside)
            symStack.addArrangedSubview(b)
        }
        let more = QPHapticButton(type: .system)
        more.setTitle("⋯", for: .normal)
        more.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        more.setTitleColor(QPColor.ink, for: .normal)
        more.backgroundColor = .clear
        more.layer.cornerRadius = QPTool.radius
        more.widthAnchor.constraint(equalToConstant: QPTool.size).isActive = true
        more.heightAnchor.constraint(equalToConstant: QPTool.size).isActive = true
        // 「⋯」现在是完整设置界面的入口，不再只是扁平菜单
        more.addAction(UIAction { [weak self] _ in self?.settings.show(.root) }, for: .touchUpInside)
        symStack.addArrangedSubview(more)

        if prefs.align != "right" { symStack.addArrangedSubview(trailSpacer) }
        if prefs.align == "center" {
            leadSpacer.widthAnchor.constraint(equalTo: trailSpacer.widthAnchor).isActive = true
        }
    }

    // MARK: - Tab

    private func buildTabs() {
        tabBar.axis = .horizontal
        tabBar.distribution = .fillEqually
        tabBar.spacing = 6
        tabBar.isLayoutMarginsRelativeArrangement = true
        tabBar.layoutMargins = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        tabBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        for (index, title) in ["剪贴板（同步）", "常用语"].enumerated() {
            let b = QPHapticButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            b.layer.cornerRadius = 7
            b.tag = 200 + index
            b.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                self.prefs.tab = index == 0 ? "clip" : "phrase"
                self.refreshTabBar()
                self.refreshList()
            }, for: .touchUpInside)
            tabBar.addArrangedSubview(b)
        }
        root.addArrangedSubview(tabBar)
        // 用户要求：去掉「剪贴板（同步）/ 常用语」两个 Tab，位置全留给剪贴板记录
        tabBar.isHidden = true
    }

    private func refreshTabBar() {
        for sub in tabBar.arrangedSubviews {
            guard let b = sub as? UIButton else { continue }
            let on = (b.tag == 200 && prefs.tab == "clip") || (b.tag == 201 && prefs.tab == "phrase")
            b.backgroundColor = on ? QPColor.blueSoft : .clear
            b.setTitleColor(on ? QPColor.blue : QPColor.sub, for: .normal)
        }
    }

    // MARK: - 列表 (.kbList / .kbCard)

    private func buildList() {
        listScroll.showsVerticalScrollIndicator = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listStack.axis = .vertical
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listScroll.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: listScroll.contentLayoutGuide.leadingAnchor, constant: 10),
            listStack.trailingAnchor.constraint(equalTo: listScroll.contentLayoutGuide.trailingAnchor, constant: -10),
            listStack.topAnchor.constraint(equalTo: listScroll.contentLayoutGuide.topAnchor, constant: 4),
            listStack.bottomAnchor.constraint(equalTo: listScroll.contentLayoutGuide.bottomAnchor, constant: -4),
            listStack.widthAnchor.constraint(equalTo: listScroll.frameLayoutGuide.widthAnchor, constant: -20)
        ])
        root.addArrangedSubview(listScroll)
    }

    private func refreshList() {
        // ★ 手指还按在卡片上（正在左右滑 / 长按）时绝不重建列表：
        //   旧版每 3 秒拉一次电脑就整列删掉重建，滑动到一半卡片没了、长按中途被取消，
        //   表现就是「左右滑不出来、长按不弹菜单」。这里改成推迟到松手后再刷。
        if cardBusy {
            pendingListRefresh = true
            return
        }
        pendingListRefresh = false
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // ★ 主列表 = 本机复制历史 + 电脑同步记录，不依赖是否连上电脑
        displayItems = mergedItems()

        guard !displayItems.isEmpty else {
            let msg = !hasFullAccess
                ? "无法读取剪贴板\n请到 设置 → 通用 → 键盘 → QuickPaste\n开启「允许完全访问」"
                : "暂无剪贴板内容\n在任意 App 复制文字后切回键盘，或连接电脑同步"
            listStack.addArrangedSubview(emptyLabel(msg))
            let b = QPHapticButton(type: .system)
            b.setTitle("连接电脑并刷新", for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.backgroundColor = QPColor.blue
            b.layer.cornerRadius = 10
            b.heightAnchor.constraint(equalToConstant: 38).isActive = true
            b.addAction(UIAction { [weak self] _ in self?.pull(showConnecting: true) },
                        for: .touchUpInside)
            listStack.addArrangedSubview(b)
            // 清空后列表为空，这个入口也还在
            listStack.addArrangedSubview(makeClearFooter())
            return
        }

        if prefs.columns == 1 {
            for (i, item) in displayItems.enumerated() {
                listStack.addArrangedSubview(makeSyncCard(item: item, index: i))
            }
            listStack.addArrangedSubview(makeClearFooter())
            return
        }
        var row: UIStackView?
        for (i, item) in displayItems.enumerated() {
            if i % 2 == 0 {
                let r = UIStackView()
                r.axis = .horizontal
                r.spacing = 6
                r.distribution = .fillEqually
                listStack.addArrangedSubview(r)
                row = r
            }
            row?.addArrangedSubview(makeSyncCard(item: item, index: i))
        }
        if displayItems.count % 2 == 1 { row?.addArrangedSubview(UIView()) }
        listStack.addArrangedSubview(makeClearFooter())
    }

    /// 主列表：本机 + 画中画 + 电脑，全部按时间倒序混排（最新的永远在第一格）。
    /// 旧版把本机记录一律排前面、电脑记录全塞在后面 —— 电脑刚推过来的那条会掉到
    /// 5 条手机记录之后，用户原话「其实它应该显示到第一位」。
    private func mergedItems() -> [SyncItem] {
        var all: [SyncItem] = []
        var seen = Set<String>()
        // 老数据缺时间戳的，先补一次并落盘（不能每次渲染都拿 now 现算，否则永远排最前）
        prefs.backfillClipTimes()
        let texts = prefs.clips
        let times = prefs.clipTimes
        let now = Date().timeIntervalSince1970

        for (i, raw) in texts.enumerated() {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !prefs.isMuted(text),
                  seen.insert("t:" + text).inserted else { continue }
            // 兜底（极少走到）：仍然是固定值，绝不随刷新漂移
            let sec = i < times.count ? times[i] : now - Double(i + 1) * 0.5
            all.append(SyncItem(id: "local:" + text, text: text, type: "text",
                                image: "", mime: "", source: "local",
                                ts: sec * 1000))
        }
        // 主 App 画中画期间在别的 App 里复制的内容（多数已经进上面的 clips，这里兜底）。
        // ★ 时间戳必须用收录当时的真实时刻：
        //   旧版在这里写 `now - 0.5`，每刷新一次就变成「刚刚复制」，
        //   于是这几条永久钉在最前面，电脑同步过来的新条目永远上不去。
        let shared = QPSharedHistory.read()
        for (i, raw) in shared.items.enumerated() {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !prefs.isMuted(text),
                  seen.insert("t:" + text).inserted else { continue }
            let ms = shared.timeMS(at: i) ?? prefs.stickyTime(for: text, index: i)
            all.append(SyncItem(id: "pip:" + text, text: text, type: "text",
                                image: "", mime: "", source: "local", ts: ms))
        }
        // 电脑端记录：带真实时间戳（毫秒），参与统一排序。
        // 老版本服务端没写 ts：给个固定兜底（同样不能每刷新现算，否则永远浮在上面）
        for (i, it) in items.enumerated() {
            let key = it.isImage ? "i:" + it.id : "t:" + it.displayText
            guard seen.insert(key).inserted else { continue }
            if it.ts > 0 {
                all.append(it)
            } else {
                all.append(SyncItem(id: it.id, text: it.text, type: it.type,
                                    image: it.image, mime: it.mime,
                                    source: it.source,
                                    ts: prefs.stickyTime(for: "srv:" + it.id, index: i)))
            }
        }

        // ★ 排序方向（v1.8.8 工具条可切）：↑ 最新在上（默认，电脑刚推的那条
        //   就该在第一格）/ ↓ 最旧在上
        if prefs.sortNewestTop {
            all.sort { $0.ts > $1.ts }
        } else {
            all.sort { $0.ts < $1.ts }
        }
        // ★ 清空闸门：清空时记下时刻，比它旧的条目（电脑端回传的历史、画中画旧记录）不再冒出来
        let gate = prefs.clearedAt
        if gate > 0 { all = all.filter { $0.ts > gate } }
        // v1.8.8 类型筛选（工具条漏斗按钮）：text = 文本里去掉链接，
        // link = 整条是网址或含 http(s)/www，image / file 按记录类型。
        let ft = prefs.clipFilter
        if ft != "all" {
            all = all.filter { item in
                switch ft {
                case "link": return Self.isLinkItem(item)
                case "image": return item.isImage
                case "file": return item.type == "file" && !item.isImage
                default: return !item.isImage && item.type != "file" && !Self.isLinkItem(item)
                }
            }
        }
        // 置顶条目排在最前（本机与电脑记录一起参与）
        let pins = prefs.pinned
        if !pins.isEmpty {
            all = all.filter { pins.contains($0.text) } + all.filter { !pins.contains($0.text) }
        }
        return Array(all.prefix(30))
    }

    private func emptyLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 14)
        l.textColor = QPColor.sub
        l.textAlignment = .center
        l.numberOfLines = 3
        l.heightAnchor.constraint(equalToConstant: 56).isActive = true
        return l
    }

    private func makePhraseCard(text: String, index: Int) -> UIView {
        let card = QPHapticButton(type: .custom)
        card.backgroundColor = .white
        card.layer.cornerRadius = 12
        card.clipsToBounds = true
        card.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14)
        label.numberOfLines = 2
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
        card.addAction(UIAction { [weak self] _ in
            self?.insertText(text)
            if self?.prefs.autoCollapse == true { self?.dismissKeyboard() }
        }, for: .touchUpInside)
        return card
    }

    private func makeSyncCard(item: SyncItem, index: Int) -> UIView {
        // 卡片本体（白底圆角）交给 QPSwipeCard 包一层：右滑分词/预览、左滑编辑/删除
        let card = UIView()
        // 卡片内容不接收触摸：所有事件落到 QPSwipeCard 自己身上，
        // touchesBegan 才能在按下的第一帧就置「交互中」，避免长按被列表重建打断。
        card.isUserInteractionEnabled = false
        card.backgroundColor = .white
        card.layer.cornerRadius = 12
        card.clipsToBounds = true

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false

        if item.isImage {
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = 8
            iv.backgroundColor = QPColor.sep
            iv.image = thumbnail(item)
            iv.widthAnchor.constraint(equalToConstant: 36).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 36).isActive = true
            row.addArrangedSubview(iv)
            let tag = UILabel()
            tag.text = "图片 · " + (item.fromPhone ? "手机发来" : "电脑复制")
            tag.font = .systemFont(ofSize: 13)
            tag.textColor = QPColor.sub
            row.addArrangedSubview(tag)
        } else {
            let label = UILabel()
            label.text = item.displayText
            // 原型 .kbCard：字号 16、#111 正文
            label.font = .systemFont(ofSize: 16)
            label.textColor = UIColor.rgb(17, 17, 17)
            label.numberOfLines = 2
            row.addArrangedSubview(label)
        }
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -30),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6)
        ])

        let badge = UILabel()
        let isPinned = prefs.pinned.contains(item.isLocal ? item.text : item.displayText)
        badge.text = isPinned ? "📌" : (item.isLocal ? "✂️" : (item.fromPhone ? "📱" : "💻"))
        badge.font = .systemFont(ofSize: 11)
        badge.textAlignment = .center
        badge.backgroundColor = isPinned
            ? UIColor.rgb(255, 236, 236)
            : (item.isLocal
                ? UIColor.rgb(255, 243, 224)
                : (item.fromPhone ? UIColor.rgb(231, 248, 238) : UIColor.rgb(238, 241, 255)))
        badge.layer.cornerRadius = 7
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            badge.topAnchor.constraint(equalTo: card.topAnchor, constant: 5),
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20)
        ])

        // 轻点插入 / 长按菜单 / 左右滑动操作
        let wrap = QPSwipeCard(content: card, height: 52)
        wrap.tag = index
        wrap.onTap = { [weak self] in
            guard let self = self else { return }
            if item.isImage { self.showImage(item) }
            else {
                self.insertText(item.text)
                if self.prefs.autoCollapse { self.dismissKeyboard() }
            }
        }
        wrap.onLongPress = { [weak self, weak wrap] in
            guard let self = self, let wrap = wrap else { return }
            self.openCardMenu(item, anchor: wrap)
        }
        wrap.onAction = { [weak self] action in
            guard let self = self else { return }
            switch action {
            case .segment: self.openSegment(item)
            case .preview: self.openPreview(item)
            case .edit:    self.openEdit(item)
            case .delete:  self.deleteCard(item)
            }
        }
        wrap.onOpen = { [weak self, weak wrap] in
            guard let self = self else { return }
            if let prev = self.openedCard, prev !== wrap { prev.close() }
            self.openedCard = wrap
        }
        wrap.onBusyChange = { [weak self] busy in
            guard let self = self else { return }
            self.cardBusy = busy
            // 松手后再刷，且放到下一轮事件循环 —— 别在手势收尾的动画里把卡片拆掉
            if !busy, self.pendingListRefresh {
                DispatchQueue.main.async { self.refreshList() }
            }
        }
        // 横向滑动时先关掉列表滚动，方向不会被 ScrollView 抢走
        wrap.onHorizontalSwipe = { [weak self] on in
            self?.listScroll.isScrollEnabled = !on
        }
        return wrap
    }

    private func thumbnail(_ item: SyncItem) -> UIImage? {
        if let cached = thumbCache[item.id] { return cached }
        guard let data = item.imageData,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceThumbnailMaxPixelSize: 120,
                kCGImageSourceCreateThumbnailFromImageAlways: true
              ] as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        thumbCache[item.id] = img
        return img
    }

    // MARK: - 「清空剪贴板」内嵌到列表最下边

    /// 不再单独占一整行：作为列表最后一个随内容滚动的小条目，
    /// 清空之后列表空了它依旧显示，空间全部留给剪贴板记录。
    private func makeClearFooter() -> UIButton {
        let b = QPHapticButton(type: .system)
        b.setTitle("清空剪贴板  🗑", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        b.setTitleColor(QPColor.sub, for: .normal)
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        b.addAction(UIAction { [weak self] _ in self?.clearAllHistory() }, for: .touchUpInside)
        b.isHidden = !prefs.clearBtn
        return b
    }

    // MARK: - 计算器（算式直接写进目标 App 的输入框）

    /// 用户给的样式：4 列数字键盘 + 右侧一列橙色运算符 + 底行「‹返回 / 空格 / 发送」。
    /// 旧版是 5 列 × 4 行塞在列表那点高度里，键又小又挤、老是按错，全部推翻重做。
    /// 行为不变：按 7 就真的在对话框里出现 7，按 = 才把这段算式换成结果（7+8 → 15）。
    private func buildCalc() {
        calcBox.axis = .vertical
        calcBox.spacing = 7
        calcBox.distribution = .fillEqually
        calcBox.isHidden = true
        calcBox.isLayoutMarginsRelativeArrangement = true
        calcBox.layoutMargins = UIEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)

        let rows: [[(title: String, key: String, kind: CalcKeyKind)]] = [
            [("1", "1", .digit), ("2", "2", .digit), ("3", "3", .digit), ("+", "+", .op)],
            [("4", "4", .digit), ("5", "5", .digit), ("6", "6", .digit), ("−", "-", .op)],
            [("7", "7", .digit), ("8", "8", .digit), ("9", "9", .digit), ("×", "×", .op)],
            [(".", ".", .digit), ("0", "0", .digit), ("=", "=", .equal), ("÷", "÷", .op)]
        ]

        for keys in rows {
            let r = UIStackView()
            r.axis = .horizontal
            r.spacing = 7
            r.distribution = .fillEqually
            for k in keys {
                r.addArrangedSubview(calcKeyButton(k.title, key: k.key, kind: k.kind))
            }
            calcBox.addArrangedSubview(r)
        }

        // 底行：‹返回 / 空格 / 发送（跟系统输入框那一行一样，高度略矮）
        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = 7
        bottom.alignment = .center

        let back = QPHapticButton(type: .system)
        back.setTitle("‹ 返回", for: .normal)
        back.titleLabel?.font = .systemFont(ofSize: 17)
        back.setTitleColor(UIColor.rgb(17, 17, 17), for: .normal)
        back.backgroundColor = UIColor.rgb(198, 200, 208)
        back.layer.cornerRadius = 8
        back.addAction(UIAction { [weak self] _ in self?.toggleCalcMode() }, for: .touchUpInside)
        back.widthAnchor.constraint(equalToConstant: 84).isActive = true
        back.heightAnchor.constraint(equalToConstant: 42).isActive = true
        bottom.addArrangedSubview(back)

        let space = QPHapticButton(type: .system)
        space.setTitle("空格", for: .normal)
        space.titleLabel?.font = .systemFont(ofSize: 17)
        space.setTitleColor(UIColor.rgb(17, 17, 17), for: .normal)
        space.backgroundColor = .white
        space.layer.cornerRadius = 8
        space.heightAnchor.constraint(equalToConstant: 42).isActive = true
        space.addAction(UIAction { [weak self] _ in
            self?.insertText(" ")
        }, for: .touchUpInside)
        bottom.addArrangedSubview(space)

        let send = QPHapticButton(type: .system)
        send.setTitle("发送", for: .normal)
        send.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        send.setTitleColor(.white, for: .normal)
        send.backgroundColor = QPColor.blue
        send.layer.cornerRadius = 8
        send.widthAnchor.constraint(equalToConstant: 104).isActive = true
        send.heightAnchor.constraint(equalToConstant: 42).isActive = true
        // 发送 = 真的发送消息（等价于按系统回车键），不是发到电脑
        send.addAction(UIAction { [weak self] _ in
            self?.insertText("\n")
        }, for: .touchUpInside)
        bottom.addArrangedSubview(send)

        calcBox.addArrangedSubview(bottom)
        root.addArrangedSubview(calcBox)
    }

    private enum CalcKeyKind { case digit, op, equal }

    private func calcKeyButton(_ title: String, key: String, kind: CalcKeyKind) -> UIButton {
        let b = QPHapticButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 26, weight: .regular)
        b.setTitleColor(kind == .digit ? UIColor.rgb(17, 17, 17) : .white, for: .normal)
        b.backgroundColor = kind == .digit ? .white : UIColor.rgb(232, 148, 63)
        b.layer.cornerRadius = 8
        b.addAction(UIAction { [weak self] _ in self?.handleCalcKey(key) },
                    for: .touchUpInside)
        return b
    }

    private func toggleCalcMode() {
        isCalcMode.toggle()
        calcBox.isHidden = !isCalcMode
        listScroll.isHidden = isCalcMode
        bottomBar.isHidden = isCalcMode
        // 计算器要放得下 5 行大键，比列表模式高一点；退出时恢复用户设的高度
        heightConstraint.constant = (isCalcMode ? 356 : prefs.height) + kbBarHeight
        UIView.animate(withDuration: 0.18) { self.view.layoutIfNeeded() }
    }

    private func handleCalcKey(_ key: String) {
        if key == "=" {
            evaluateInline()
        } else {
            // 数字 / 运算符 / 小数点：直接写进当前 App 的输入框
            insertText(key)
        }
    }

    /// 点 = ：取光标前最后一段算式（只允许数字与运算符，遇到别的内容就停），
    /// 求值后把这段替换成结果。7+8 → 15，接着按 +2= 就是 17。
    private func evaluateInline() {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let allowed = Set("0123456789.+-−×÷*/() ")
        var expr = ""
        for ch in before.reversed() {
            guard allowed.contains(ch) else { break }
            expr.insert(ch, at: expr.startIndex)
        }
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            showToast("先输入算式，例如 7+8，再点 =")
            return
        }
        guard let value = try? CalcEngine.evaluate(trimmed) else {
            showToast("算式不完整，例如 7+8")
            return
        }
        // expr 只含 ASCII，字符数即 UTF-16 长度，退格次数安全
        for _ in 0..<expr.count { textDocumentProxy.deleteBackward() }
        insertText(value.calcText)
    }

    // MARK: - 底行 (.kbKeys)

    private func buildBottomBar() {
        let bar = bottomBar
        bar.axis = .horizontal
        bar.spacing = 6
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 2, left: 10, bottom: 6, right: 10)
        bar.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let calc = QPHapticButton(type: .system)
        // 原型 .kbKey.calc：f(x) 计算，宽度 68
        calc.setTitle("f(x) 计算", for: .normal)
        calc.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        calc.setTitleColor(.black, for: .normal)
        calc.backgroundColor = QPColor.keyBg
        calc.layer.cornerRadius = 9
        calc.widthAnchor.constraint(equalToConstant: 68).isActive = true
        calc.addAction(UIAction { [weak self] _ in self?.toggleCalcMode() },
                       for: .touchUpInside)
        bar.addArrangedSubview(calc)

        let space = QPHapticButton(type: .system)
        // 原型 .kbKey.space：白底、字号 17
        space.setTitle("空格", for: .normal)
        space.titleLabel?.font = .systemFont(ofSize: 17)
        space.setTitleColor(.black, for: .normal)
        space.backgroundColor = .white
        space.layer.cornerRadius = 9
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleSpace(_:)))
        hold.minimumPressDuration = 0.12
        hold.allowableMovement = .greatestFiniteMagnitude
        space.addGestureRecognizer(hold)
        bar.addArrangedSubview(space)

        let newline = QPHapticButton(type: .system)
        newline.setTitle("换行", for: .normal)
        newline.titleLabel?.font = .systemFont(ofSize: 15)
        newline.setTitleColor(.black, for: .normal)
        newline.backgroundColor = QPColor.keyBg
        newline.layer.cornerRadius = 9
        newline.widthAnchor.constraint(equalToConstant: 64).isActive = true
        newline.addAction(UIAction { [weak self] _ in
            // 「换行」≠「发送」：宿主 App 的「回车发送」只拦截恰好等于 \n 的
            // 替换文本（粘贴多行文本不会触发发送是同一个原理）；前面垫一个
            // 零宽空格让替换文本 != "\n"，宿主不发送、只插入真实换行。
            self?.insertText("\u{200B}\n")
        }, for: .touchUpInside)
        bar.addArrangedSubview(newline)

        let send = QPHapticButton(type: .system)
        send.setTitle("发送", for: .normal)
        // 原型 .kbKey.send：蓝色、白字、宽 66、字重 600
        send.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        send.setTitleColor(.white, for: .normal)
        send.backgroundColor = QPColor.blue
        send.layer.cornerRadius = 9
        send.widthAnchor.constraint(equalToConstant: 66).isActive = true
        // ★ 发送 = 真的发送消息（等价按系统回车），不是「发到电脑」。
        //   之前这里调的是 sendInputTextToPc()，用户一按就把聊天内容推到电脑上去了。
        //   要发到电脑请长按（弹出「发送到电脑」菜单）或从 ⋯ 菜单里选。
        //   与「换行」的区别见上方 newline 注释（零宽空格避开回车发送）。
        send.addAction(UIAction { [weak self] _ in
            self?.insertText("\n")
        }, for: .touchUpInside)
        let longSend = UILongPressGestureRecognizer(target: self,
                                                    action: #selector(sendLongPress(_:)))
        send.addGestureRecognizer(longSend)
        bar.addArrangedSubview(send)

        root.addArrangedSubview(bar)
    }

    /// 长按「发送」= 打开「发到电脑」的菜单（单击已经是发送消息了）。
    @objc private func sendLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        openMenu()
    }

    // MARK: - 浮层菜单

    private func buildMenu() {
        menuOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        menuOverlay.isHidden = true
        menuOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuOverlay)
        NSLayoutConstraint.activate([
            menuOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            menuOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            menuOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            menuOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let outsideTap = UITapGestureRecognizer(target: self, action: #selector(closeMenu))
        outsideTap.cancelsTouchesInView = false
        outsideTap.delegate = self
        menuOverlay.addGestureRecognizer(outsideTap)

        // 键盘只有 300 来点高，菜单 8 行放不下会被挤出屏幕 —— 套一层可滚动容器，限高居中
        menuScroll.translatesAutoresizingMaskIntoConstraints = false
        menuScroll.showsVerticalScrollIndicator = true
        menuScroll.alwaysBounceVertical = false
        menuScroll.backgroundColor = .clear
        menuOverlay.addSubview(menuScroll)

        menuStack.axis = .vertical
        menuStack.spacing = 0
        menuStack.translatesAutoresizingMaskIntoConstraints = false
        menuStack.backgroundColor = .secondarySystemBackground
        menuStack.layer.cornerRadius = 12
        menuStack.clipsToBounds = true
        menuScroll.addSubview(menuStack)
        NSLayoutConstraint.activate([
            menuScroll.leadingAnchor.constraint(equalTo: menuOverlay.leadingAnchor, constant: 14),
            menuScroll.trailingAnchor.constraint(equalTo: menuOverlay.trailingAnchor, constant: -14),
            menuScroll.centerYAnchor.constraint(equalTo: menuOverlay.centerYAnchor),
            menuScroll.heightAnchor.constraint(lessThanOrEqualTo: menuOverlay.heightAnchor, constant: -24),
            menuStack.leadingAnchor.constraint(equalTo: menuScroll.contentLayoutGuide.leadingAnchor),
            menuStack.trailingAnchor.constraint(equalTo: menuScroll.contentLayoutGuide.trailingAnchor),
            menuStack.topAnchor.constraint(equalTo: menuScroll.contentLayoutGuide.topAnchor),
            menuStack.bottomAnchor.constraint(equalTo: menuScroll.contentLayoutGuide.bottomAnchor),
            menuStack.widthAnchor.constraint(equalTo: menuScroll.frameLayoutGuide.widthAnchor)
        ])
        // 只有「<=」没有下界时 UIScrollView 会被压成 0 高，菜单整个看不见；
        // 用一条低优先级的「高度 = 内容」把容器撑起来，超高时仍受上面的限高约束。
        let fitMenu = menuScroll.heightAnchor.constraint(equalTo: menuStack.heightAnchor)
        fitMenu.priority = .defaultHigh
        fitMenu.isActive = true
    }

    private func openMenu() {
        menuStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        view.bringSubviewToFront(menuOverlay)
        menuOverlay.isHidden = false
        menuStack.addArrangedSubview(menuTitle("快捷操作 · v1.8.9 同步"))
        menuStack.addArrangedSubview(menuRow("⚙ 打开完整设置界面") { [weak self] in
            self?.closeMenu()
            self?.settings.show(.root)
        })
        menuStack.addArrangedSubview(menuRow("⟳ 立即同步（\(items.count) 条）") { [weak self] in
            self?.pull(showConnecting: true); self?.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("↑ 发送输入框文字到电脑") { [weak self] in
            self?.sendInputTextToPc(); self?.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("📋 发送剪贴板文字到电脑") { [weak self] in
            self?.sendPasteboardTextToPc(); self?.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("🖼 发送剪贴板图片到电脑") { [weak self] in
            self?.sendPasteboardImageToPc(); self?.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("📥 用剪贴板里的电脑地址") { [weak self] in
            guard let self = self else { return }
            if self.prefs.adoptPasteboardURL() {
                self.showToast("地址已更新：" + self.prefs.syncURL)
                self.pull(showConnecting: true)
            } else {
                self.showToast("剪贴板里没有有效地址（需 http://…:8787）")
            }
            self.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("↺ 重置为默认地址 192.168.1.2") { [weak self] in
            guard let self = self else { return }
            self.prefs.syncURL = KeyboardPrefs.defaultURL
            self.showToast("已重置")
            self.pull(showConnecting: true)
            self.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("自动同步（每 3 秒）：" + (prefs.syncAuto ? "开" : "关")) { [weak self] in
            guard let self = self else { return }
            self.prefs.syncAuto.toggle()
            if self.prefs.syncAuto { self.startPolling() } else { self.stopPolling() }
            self.refreshCopyButton()
            self.openMenu()
        })
        menuStack.addArrangedSubview(menuRow("列数：\(prefs.columns) 列") { [weak self] in
            guard let self = self else { return }
            self.prefs.columns = self.prefs.columns == 1 ? 2 : 1
            self.refreshList()
            self.openMenu()
        })
        menuStack.addArrangedSubview(menuRow("键盘高度：\(Int(prefs.height))") { [weak self] in
            guard let self = self else { return }
            self.prefs.height = self.prefs.height >= 360 ? 240 : self.prefs.height + 20
            self.view.setNeedsLayout()
            self.openMenu()
        })
        menuStack.addArrangedSubview(menuRow("切换系统键盘") { [weak self] in
            self?.advanceToNextInputMode(); self?.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("关闭菜单") { [weak self] in self?.closeMenu() })
    }

    // MARK: - 长按条目菜单 v1.8.5（图二：灰磨砂背景 + 浮起条目 + 4 项小菜单）

    /// 单独一层，不复用「快捷操作」大菜单：后者滚动容器只有高度上限，
    /// 且被后续添加的设置面板压在下面，长按看起来就像没反应。
    private func buildCardMenu() {
        cardMenuOverlay.backgroundColor = .clear
        cardMenuOverlay.isHidden = true
        cardMenuOverlay.frame = view.bounds
        cardMenuOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // ① 整屏灰色磨砂：薄材质模糊 + 一层中性灰，后面内容仍隐约透出（图二）
        cardMenuDim.frame = view.bounds
        cardMenuDim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cardMenuDim.isUserInteractionEnabled = false
        cardMenuOverlay.addSubview(cardMenuDim)
        cardMenuShade.backgroundColor = UIColor(red: 0.38, green: 0.40, blue: 0.45,
                                                 alpha: 0.32)
        cardMenuShade.frame = view.bounds
        cardMenuShade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cardMenuShade.isUserInteractionEnabled = false
        cardMenuOverlay.addSubview(cardMenuShade)

        // ② 浮起的条目：纯白不透明、大圆角、投影，和变暗的灰底拉开层次
        cardMenuLift.backgroundColor = .white
        cardMenuLift.layer.cornerRadius = 18
        cardMenuLift.layer.shadowColor = UIColor.black.cgColor
        cardMenuLift.layer.shadowOpacity = 0.26
        cardMenuLift.layer.shadowRadius = 18
        cardMenuLift.layer.shadowOffset = CGSize(width: 0, height: 7)
        cardMenuLiftText.font = .systemFont(ofSize: 17, weight: .regular)
        cardMenuLiftText.textColor = UIColor.rgb(17, 17, 17)
        cardMenuLiftText.numberOfLines = 3
        cardMenuLiftText.lineBreakMode = .byTruncatingTail
        cardMenuLift.addSubview(cardMenuLiftText)
        cardMenuLiftSub.font = .systemFont(ofSize: 12)
        cardMenuLiftSub.textColor = QPColor.sub
        cardMenuLift.addSubview(cardMenuLiftSub)
        cardMenuLiftThumb.contentMode = .scaleAspectFill
        cardMenuLiftThumb.clipsToBounds = true
        cardMenuLiftThumb.layer.cornerRadius = 8
        cardMenuLiftThumb.backgroundColor = QPColor.sep
        cardMenuLift.addSubview(cardMenuLiftThumb)
        cardMenuOverlay.addSubview(cardMenuLift)

        // ③ 菜单：外壳负责阴影，内部磨砂视图负责圆角；颜色与灰底融合，
        //    不再是刺眼的一整块纯白（用户反馈「白色和背景显示很怪异」）
        cardMenuShell.backgroundColor = .clear
        cardMenuShell.layer.cornerRadius = 22
        cardMenuShell.layer.shadowColor = UIColor.black.cgColor
        cardMenuShell.layer.shadowOpacity = 0.18
        cardMenuShell.layer.shadowRadius = 20
        cardMenuShell.layer.shadowOffset = CGSize(width: 0, height: 8)
        cardMenuOverlay.addSubview(cardMenuShell)

        cardMenuBox.layer.cornerRadius = 22
        cardMenuBox.clipsToBounds = true
        cardMenuBox.contentView.backgroundColor = UIColor(red: 0.88, green: 0.89,
                                                          blue: 0.91, alpha: 0.30)
        cardMenuBox.layer.borderWidth = 0.5
        cardMenuBox.layer.borderColor = UIColor.white.withAlphaComponent(0.38).cgColor
        cardMenuShell.addSubview(cardMenuBox)

        cardMenuScroll.showsVerticalScrollIndicator = false
        cardMenuScroll.alwaysBounceVertical = false
        cardMenuScroll.backgroundColor = .clear
        cardMenuBox.contentView.addSubview(cardMenuScroll)

        cardMenuStack.axis = .vertical
        cardMenuStack.distribution = .fillEqually
        cardMenuStack.spacing = 0
        cardMenuScroll.addSubview(cardMenuStack)

        let cardOutsideTap = UITapGestureRecognizer(target: self,
                                                   action: #selector(closeCardMenu))
        cardOutsideTap.cancelsTouchesInView = false
        cardOutsideTap.delegate = self
        cardMenuOverlay.addGestureRecognizer(cardOutsideTap)
        view.addSubview(cardMenuOverlay)
    }

    @objc private func closeCardMenu() {
        cardMenuAnchorView?.alpha = 1
        cardMenuAnchorView = nil
        cardMenuOverlay.isHidden = true
        cardMenuLift.transform = .identity
        cardMenuShell.alpha = 1
    }

    /// 菜单行：左侧线性图标用约束居中，行高由可用空间动态决定也不会错位
    private func cardMenuRow(_ title: String, icon: String,
                             action: @escaping () -> Void) -> UIButton {
        let color = UIColor.rgb(24, 24, 27)
        let b = QPHapticButton(type: .custom)
        b.backgroundColor = .clear
        b.contentHorizontalAlignment = .leading
        b.setTitle(title, for: .normal)
        b.setTitleColor(color, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 18, weight: .regular)
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 62, bottom: 0, right: 12)
        let iv = UIImageView(image: UIImage(systemName: icon)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)))
        iv.tintColor = color
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 22),
            iv.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 24),
            iv.heightAnchor.constraint(equalToConstant: 24)
        ])
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    /// 浮起卡片右上角的圆形小按钮：承载「发送到电脑 / 置顶 / 删除」，
    /// 让下方主菜单可以严格保持图二的 4 项尺寸
    private func cardLiftButton(_ icon: String, tint: UIColor,
                                action: @escaping () -> Void) -> UIButton {
        let b = QPHapticButton(type: .custom)
        b.backgroundColor = UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        b.layer.cornerRadius = 15
        b.tintColor = tint
        b.setImage(UIImage(systemName: icon)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)),
                    for: .normal)
        b.addAction(UIAction { [weak self] _ in
            self?.closeCardMenu()
            action()
        }, for: .touchUpInside)
        return b
    }

    /// 图二的 4 项主菜单：复制 / 编辑 / 分词 / 预览全文（图片条目少两项）。
    /// 发送到电脑 / 置顶 / 删除挪到浮起卡片的圆形按钮上，功能一项不少，
    /// 但菜单本体不会再变成压住整个键盘的 7 行大白块。
    private func openCardMenu(_ item: SyncItem, anchor: UIView) {
        closeMenu()
        closeFilterMenu()
        closeExportMenu()
        cardMenuAnchorView?.alpha = 1
        anchor.alpha = 0
        cardMenuAnchorView = anchor
        cardMenuStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cardMenuLift.subviews.filter { $0 is UIButton }.forEach { $0.removeFromSuperview() }

        func add(_ title: String, _ icon: String, _ action: @escaping () -> Void) {
            cardMenuStack.addArrangedSubview(
                cardMenuRow(title, icon: icon) { [weak self] in
                    self?.closeCardMenu()
                    action()
                })
        }

        add("复制", "doc.on.doc") { [weak self] in
            guard let self = self else { return }
            if item.isImage, let d = item.imageData, let img = UIImage(data: d) {
                UIPasteboard.general.image = img
            } else {
                UIPasteboard.general.string = item.text
            }
            self.showToast("已复制")
        }
        if !item.isImage {
            add("编辑", "pencil") { [weak self] in self?.openEdit(item) }
            add("分词", "list.bullet") { [weak self] in self?.openSegment(item) }
        }
        add("预览全文", "magnifyingglass") { [weak self] in
            if item.isImage { self?.showImage(item) } else { self?.openPreview(item) }
        }

        let pinKey = item.isLocal ? item.text : item.displayText
        let pinned = prefs.pinned.contains(pinKey)
        let sendBtn = cardLiftButton("desktopcomputer", tint: UIColor.rgb(24, 24, 27)) { [weak self] in
            guard let self = self else { return }
            if item.isImage, let d = item.imageData {
                self.client.pushImage(d, mime: item.mime) { err in
                    DispatchQueue.main.async {
                        self.showToast(err == nil ? "图片已发送到电脑" : ("发图失败：" + (err ?? "")))
                    }
                }
            } else { self.sendTextToPc(item.text) }
        }
        let pinBtn = cardLiftButton(pinned ? "pin.slash" : "pin",
                                    tint: UIColor.rgb(24, 24, 27)) { [weak self] in
            guard let self = self else { return }
            self.prefs.togglePin(pinKey)
            self.refreshList()
            self.showToast(pinned ? "已取消置顶" : "已置顶")
        }
        let delBtn = cardLiftButton("trash", tint: QPColor.red) { [weak self] in
            self?.deleteCard(item)
        }
        let liftButtons = [sendBtn, pinBtn, delBtn]
        liftButtons.forEach { cardMenuLift.addSubview($0) }

        let from = item.isLocal ? "本机复制" : (item.fromPhone ? "手机发来" : "电脑复制")
        cardMenuLiftText.text = item.isImage ? ("图片 · " + from) : item.displayText
        cardMenuLiftSub.text = from + (item.isImage ? " · 图片条目" : " · \(item.displayText.count) 字")
        cardMenuLiftThumb.image = item.isImage ? thumbnail(item) : nil
        cardMenuLiftThumb.isHidden = !item.isImage

        // 高度按键盘实际高度动态分配：默认 300pt 时浮起卡片约 62pt、
        // 菜单 4 行各约 48pt；调到 360pt 时接近截图的宽松行距，240pt 也不越界。
        let bounds = view.bounds
        let avail = max(180, bounds.height - 16)
        let liftW = bounds.width - 28
        let liftH = min(84, max(52, avail * 0.22))
        let gap: CGFloat = 10
        let pad: CGFloat = 10
        let rows = CGFloat(cardMenuStack.arrangedSubviews.count)
        let rowH = max(34, min(54, (avail - liftH - gap - pad * 2) / rows))
        let contentH = rows * rowH
        let menuH = contentH + pad * 2
        let menuW = min(max(bounds.width * 0.62, 220), liftW)

        // 浮起卡片尽量贴住被按住条目的原位，菜单紧跟其下；放不下就整组上移。
        let r = anchor.convert(anchor.bounds, to: view)
        var liftY = r.minY - 4
        var menuY = liftY + liftH + gap
        if menuY + menuH > bounds.height - 8 {
            menuY = bounds.height - menuH - 8
            liftY = menuY - gap - liftH
        }
        if liftY < 8 {
            liftY = 8
            menuY = liftY + liftH + gap
        }
        if menuY + menuH > bounds.height - 8 {
            menuY = max(liftY + liftH + gap, bounds.height - menuH - 8)
        }

        cardMenuLift.frame = CGRect(x: 14, y: liftY, width: liftW, height: liftH)
        let btnD: CGFloat = 30
        let btnGap: CGFloat = 6
        var bx = liftW - 12 - btnD
        for b in liftButtons {
            b.frame = CGRect(x: bx, y: (liftH - btnD) / 2, width: btnD, height: btnD)
            bx -= btnD + btnGap
        }
        let textRight = bx + btnGap + 8
        let textX: CGFloat = item.isImage ? 62 : 14
        let textW = max(40, textRight - textX)
        cardMenuLiftThumb.frame = CGRect(x: 12, y: (liftH - 40) / 2, width: 40, height: 40)
        cardMenuLiftText.frame = CGRect(x: textX, y: 10, width: textW,
                                        height: max(20, liftH - 10 - 22 - 6))
        cardMenuLiftSub.frame = CGRect(x: textX, y: liftH - 20, width: textW, height: 14)

        cardMenuShell.frame = CGRect(x: 14, y: menuY, width: menuW, height: menuH)
        // 外壳本身透明，显式给 shadowPath 才能保证投影真的画出来
        cardMenuShell.layer.shadowPath = UIBezierPath(roundedRect: cardMenuShell.bounds,
                                                      cornerRadius: 22).cgPath
        cardMenuBox.frame = cardMenuShell.bounds
        cardMenuScroll.frame = CGRect(x: 0, y: pad, width: menuW, height: contentH)
        cardMenuStack.frame = CGRect(x: 0, y: 0, width: menuW, height: contentH)
        cardMenuScroll.contentSize = CGSize(width: menuW, height: contentH)

        cardMenuOverlay.frame = bounds
        cardMenuDim.frame = bounds
        cardMenuShade.frame = bounds
        cardMenuOverlay.isHidden = false
        view.bringSubviewToFront(cardMenuOverlay)

        cardMenuLift.alpha = 0.25
        cardMenuLift.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        cardMenuShell.alpha = 0
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut]) {
            self.cardMenuLift.alpha = 1
            self.cardMenuLift.transform = .identity
            self.cardMenuShell.alpha = 1
        }
    }

    /// 删除一条：本机历史进「最近删除」可恢复，电脑记录走 /api/delete。
    /// 无论哪种都先上墓碑，否则这条还在系统剪贴板里，0.5 秒后又被抓回来。
    private func deleteCard(_ item: SyncItem) {
        prefs.mute([item.text])
        prefs.remove(item.text, from: "clip")
        if item.isLocal {
            refreshList()
            showToast("已删除（可在设置 → 最近删除找回）")
        } else {
            refreshList()
            deleteItem(id: item.id)
        }
    }

    /// 一键清空：本地立即生效，不等网络。
    /// 旧版这里弹确认框 → 调 /api/delete → 电脑没开就一直等到超时，
    /// 结果「提示超时、其实一条都没清掉」。现在先清本地，电脑端只在已连上时静默同步。
    private func clearAllHistory() {
        var texts = displayItems.map { $0.text }
        if let s = UIPasteboard.general.string, !s.isEmpty { texts.append(s) }
        prefs.clearAllClips()
        prefs.mute(texts)          // 剪贴板里还留着的那条也不再抓回来
        // 共享通道里还在的条目：没 App Group 时清不掉文件，只能把它们的时间戳抹成 0，
        // 交给下面的清空闸门挡住（否则清完它们又带着「刚刚」的时间戳冒回来）
        prefs.suppressShared(QPSharedHistory.read().items)
        QPSharedHistory.clear()    // 有 App Group 才真清共享；否则不动剪贴板
        items = []                 // 电脑端缓存也清掉，别让旧条目下一轮又被渲染出来
        if syncState == "online" {
            client.delete(id: nil) { _ in }   // 静默：成功失败都不打扰
            syncSig = ""
        }
        displayItems = []
        refreshList()
        showToast("已清空")
    }

    @objc private func closeMenu() { menuOverlay.isHidden = true }

    @objc private func handleMenuPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        // 两个 Tab 已移除；长按工具条按键统一打开完整设置界面
        settings.show(.root)
    }

    // MARK: - 分词 / 预览 / 编辑（右滑与长按菜单共用）

    private func openSegment(_ item: SyncItem) {
        guard !item.isImage else { showToast("图片不支持分词"); return }
        let tokens = segmentTokens(item.text)
        guard !tokens.isEmpty else { showToast("没有可分词的内容"); return }

        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        for t in tokens.prefix(40) {
            let b = QPHapticButton(type: .system)
            b.setTitle(t, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14)
            b.setTitleColor(UIColor.rgb(17, 17, 17), for: .normal)
            b.contentHorizontalAlignment = .left
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            b.backgroundColor = QPColor.blueSoft
            b.layer.cornerRadius = 8
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            b.addAction(UIAction { [weak self] _ in
                self?.insertText(t)
                self?.closeSheet()
            }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        scroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
        showSheet(title: "分词 · 点一项插入", body: scroll)
    }

    /// 中文按词、英文按单词切；切不出来就按空白与标点兜底
    private func segmentTokens(_ text: String) -> [String] {
        var out: [String] = []
        let tk = NLTokenizer(unit: .word)
        tk.string = text
        tk.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let w = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !w.isEmpty, !out.contains(w) { out.append(w) }
            return out.count < 200
        }
        if out.count <= 1 {
            let seps = CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters)
                .union(.symbols)
            let parts = text.components(separatedBy: seps)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { out = parts }
        }
        return out
    }

    private func openPreview(_ item: SyncItem) {
        if item.isImage { showImage(item); return }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = true
        let label = UILabel()
        label.text = item.text
        label.font = .systemFont(ofSize: 14)
        label.textColor = UIColor.rgb(17, 17, 17)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            label.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -20)
        ])
        scroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
        showSheet(title: "预览", body: scroll)
    }

    /// 「编辑」：键盘本身没有字母键（这是剪贴板键盘），所以给出能真正用起来的快捷修改：
    /// 全文可选中复制 + 退格 / 补空格 / 清空，改完保存回历史（原条目进最近删除）。
    private func openEdit(_ item: SyncItem) {
        guard !item.isImage else { showToast("图片不能编辑文字"); return }
        let tv = UITextView()
        tv.text = item.text
        tv.font = .systemFont(ofSize: 14)
        tv.textColor = UIColor.rgb(17, 17, 17)
        tv.backgroundColor = QPColor.bg
        tv.layer.cornerRadius = 8
        tv.isEditable = false          // 不在键盘里伪造输入框，避免「点了打不出字」
        tv.isSelectable = true
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.heightAnchor.constraint(equalToConstant: 92).isActive = true
        editField = tv

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        for (title, kind) in [("⌫ 退格", 0), ("补空格", 1), ("清空", 2)] {
            let b = QPHapticButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            b.setTitleColor(UIColor.rgb(17, 17, 17), for: .normal)
            b.backgroundColor = QPColor.sep
            b.layer.cornerRadius = 8
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            b.tag = kind
            b.addAction(UIAction { [weak self] _ in
                guard let self = self, let tv = self.editField else { return }
                var s = tv.text ?? ""
                switch kind {
                case 0: if !s.isEmpty { s.removeLast() }
                case 1: s += " "
                default: s = ""
                }
                tv.text = s
            }, for: .touchUpInside)
            row.addArrangedSubview(b)
        }

        let hint = UILabel()
        hint.text = "改完点「保存」写回列表；想整段重写可长按上方文字复制后修改"
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = QPColor.sub
        hint.numberOfLines = 2

        let box = UIStackView(arrangedSubviews: [tv, row, hint])
        box.axis = .vertical
        box.spacing = 6

        showSheet(title: "编辑", body: box, confirmTitle: "保存") { [weak self] in
            guard let self = self else { return }
            let new = (self.editField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !new.isEmpty else { self.showToast("内容不能为空"); return }
            if item.isLocal { self.prefs.remove(item.text, from: "clip") }
            self.prefs.capture(new)
            self.refreshList()
            self.closeSheet()
            self.showToast("已保存")
        }
    }

    // MARK: - 通用小面板（分词 / 预览 / 编辑）

    private func buildSheet() {
        sheetOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        sheetOverlay.isHidden = true
        sheetOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetOverlay)
        NSLayoutConstraint.activate([
            sheetOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheetOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            sheetOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let bgTap = UITapGestureRecognizer(target: self, action: #selector(sheetBackgroundTapped(_:)))
        sheetOverlay.addGestureRecognizer(bgTap)

        sheetStack.axis = .vertical
        sheetStack.spacing = 8
        sheetStack.isLayoutMarginsRelativeArrangement = true
        sheetStack.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        sheetStack.backgroundColor = .white
        sheetStack.layer.cornerRadius = 14
        sheetStack.translatesAutoresizingMaskIntoConstraints = false
        sheetOverlay.addSubview(sheetStack)
        NSLayoutConstraint.activate([
            sheetStack.leadingAnchor.constraint(equalTo: sheetOverlay.leadingAnchor, constant: 10),
            sheetStack.trailingAnchor.constraint(equalTo: sheetOverlay.trailingAnchor, constant: -10),
            sheetStack.centerYAnchor.constraint(equalTo: sheetOverlay.centerYAnchor),
            sheetStack.topAnchor.constraint(greaterThanOrEqualTo: sheetOverlay.topAnchor, constant: 8)
        ])
    }

    @objc private func sheetBackgroundTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: sheetOverlay)
        if sheetStack.frame.contains(p) { return }
        closeSheet()
    }

    @objc private func closeSheet() {
        sheetOverlay.isHidden = true
        editField = nil
    }

    private func showSheet(title: String, body: UIView,
                           confirmTitle: String? = nil,
                           confirm: (() -> Void)? = nil) {
        sheetStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let t = UILabel()
        t.text = title
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = QPColor.sub
        t.heightAnchor.constraint(equalToConstant: 20).isActive = true
        sheetStack.addArrangedSubview(t)
        sheetStack.addArrangedSubview(body)

        let bar = UIStackView()
        bar.axis = .horizontal
        bar.spacing = 8
        bar.distribution = .fillEqually
        let cancel = QPHapticButton(type: .system)
        cancel.setTitle("关闭", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        cancel.setTitleColor(QPColor.sub, for: .normal)
        cancel.backgroundColor = QPColor.bg
        cancel.layer.cornerRadius = 10
        cancel.heightAnchor.constraint(equalToConstant: 38).isActive = true
        cancel.addAction(UIAction { [weak self] _ in self?.closeSheet() }, for: .touchUpInside)
        bar.addArrangedSubview(cancel)
        if let title = confirmTitle {
            let ok = QPHapticButton(type: .system)
            ok.setTitle(title, for: .normal)
            ok.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            ok.setTitleColor(.white, for: .normal)
            ok.backgroundColor = QPColor.blue
            ok.layer.cornerRadius = 10
            ok.heightAnchor.constraint(equalToConstant: 38).isActive = true
            ok.addAction(UIAction { _ in confirm?() }, for: .touchUpInside)
            bar.addArrangedSubview(ok)
        }
        sheetStack.addArrangedSubview(bar)
        sheetOverlay.isHidden = false
    }

    private func menuTitle(_ text: String) -> UIView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return l
    }

    private func menuRow(_ title: String, action: @escaping () -> Void) -> UIButton {
        let b = QPHapticButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13)
        b.setTitleColor(.label, for: .normal)
        b.contentHorizontalAlignment = .leading
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    // MARK: - 图片预览

    private func buildImageOverlay() {
        imageOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.9)
        imageOverlay.isHidden = true
        imageOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageOverlay)
        NSLayoutConstraint.activate([
            imageOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            imageOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        imageOverlay.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                                 action: #selector(closeImage)))

        imageBig.contentMode = .scaleAspectFit
        imageBig.translatesAutoresizingMaskIntoConstraints = false
        imageOverlay.addSubview(imageBig)
        NSLayoutConstraint.activate([
            imageBig.leadingAnchor.constraint(equalTo: imageOverlay.leadingAnchor, constant: 12),
            imageBig.trailingAnchor.constraint(equalTo: imageOverlay.trailingAnchor, constant: -12),
            imageBig.topAnchor.constraint(equalTo: imageOverlay.topAnchor, constant: 16),
            imageBig.heightAnchor.constraint(equalToConstant: 170)
        ])

        let bar = UIStackView()
        bar.axis = .horizontal
        bar.spacing = 8
        bar.distribution = .fillEqually
        bar.translatesAutoresizingMaskIntoConstraints = false
        let copyBtn = QPHapticButton(type: .system)
        copyBtn.setTitle("复制到剪贴板", for: .normal)
        copyBtn.setTitleColor(.white, for: .normal)
        copyBtn.backgroundColor = QPColor.blue
        copyBtn.layer.cornerRadius = 9
        copyBtn.addAction(UIAction { [weak self] _ in
            if let it = self?.currentImageItem { self?.copyImageToPasteboard(it) }
            self?.closeImage()
        }, for: .touchUpInside)
        bar.addArrangedSubview(copyBtn)
        let close = QPHapticButton(type: .system)
        close.setTitle("关闭", for: .normal)
        close.setTitleColor(.white, for: .normal)
        close.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        close.layer.cornerRadius = 9
        close.addAction(UIAction { [weak self] _ in self?.closeImage() },
                        for: .touchUpInside)
        imageCloseButton = close
        close.isHidden = !prefs.floatClose
        bar.addArrangedSubview(close)
        imageOverlay.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: imageOverlay.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: imageOverlay.trailingAnchor, constant: -16),
            bar.topAnchor.constraint(equalTo: imageBig.bottomAnchor, constant: 12),
            bar.heightAnchor.constraint(equalToConstant: 38)
        ])

        let tip = UILabel()
        tip.text = "点开即已复制 · 到输入框长按 → 粘贴\n（iOS 不开放键盘直接插图接口）"
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .white
        tip.textAlignment = .center
        tip.numberOfLines = 2
        tip.translatesAutoresizingMaskIntoConstraints = false
        imageOverlay.addSubview(tip)
        NSLayoutConstraint.activate([
            tip.leadingAnchor.constraint(equalTo: imageOverlay.leadingAnchor, constant: 12),
            tip.trailingAnchor.constraint(equalTo: imageOverlay.trailingAnchor, constant: -12),
            tip.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10)
        ])
    }

    private func showImage(_ item: SyncItem, copyToClipboard: Bool = true) {
        guard let d = item.imageData, let img = UIImage(data: d) else {
            showToast("图片解码失败")
            return
        }
        currentImageItem = item
        imageBig.image = img
        imageOverlay.isHidden = false
        // ★ iOS 键盘扩展**没有**插入图片的接口（textDocumentProxy 只有文本），
        //   能做到的极限就是：点一下图就把图片放进系统剪贴板，
        //   用户只需要在输入框里长按 → 粘贴，不用再点进来看一次再点复制。
        if copyToClipboard, hasFullAccess {
            UIPasteboard.general.image = img
            showToast("图片已复制 · 到输入框长按粘贴")
        }
    }

    @objc private func closeImage() { imageOverlay.isHidden = true }

    private func copyImageToPasteboard(_ item: SyncItem) {
        guard hasFullAccess, let d = item.imageData, let img = UIImage(data: d) else {
            showToast("需要开启「允许完全访问」")
            return
        }
        UIPasteboard.general.image = img
        showToast("已复制图片，到输入框长按粘贴")
    }

    // MARK: - 交互

    /// ✕ 键左滑逐字符退删（搜狗同款）：按住后向左滑，每 10pt 删一个字符，
    /// 光标跟着回退；往右回滑不恢复（已删字符无法恢复）。
    /// 与「上滑清空 / 下滑恢复 / 1 秒长按菜单 / 单击删一个字」并存。
    @objc private func handleDeleteSlide(_ g: UILongPressGestureRecognizer) {
        let x = g.location(in: view).x
        switch g.state {
        case .began:
            deleteOriginX = x
            deleteDeletedSteps = 0
        case .changed:
            // 只统计向左的净位移；一次changed最多补删 16 个字符防失控
            let steps = max(0, Int((deleteOriginX - x) / 10))
            let delta = steps - deleteDeletedSteps
            if delta > 0 {
                for _ in 0..<min(delta, 16) { textDocumentProxy.deleteBackward() }
                deleteDeletedSteps = steps
                if prefs.cursorHaptic {
                    let f = UISelectionFeedbackGenerator()
                    for _ in 0..<min(delta, 4) { f.selectionChanged() }
                }
            }
        default:
            break
        }
    }

    @objc private func handleSpace(_ g: UILongPressGestureRecognizer) {
        let x = g.location(in: view).x
        switch g.state {
        case .began:
            spaceOriginX = x
            spaceLastSteps = 0
            // 按下就预热震动器，第一次移动时才不会有延迟
            if prefs.spaceCursor && prefs.cursorHaptic {
                let f = UISelectionFeedbackGenerator()
                f.prepare()
                cursorFeedback = f
            } else {
                cursorFeedback = nil
            }
        case .changed:
            guard prefs.spaceCursor else { return }
            let steps = Int((x - spaceOriginX) / 10)
            let delta = steps - spaceLastSteps
            if delta != 0 {
                textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
                spaceLastSteps = steps
                // 移动一个字符震一下；一次跨了多格就补齐次数，最多 4 次防手麻
                if let f = cursorFeedback {
                    for _ in 0..<min(abs(delta), 4) { f.selectionChanged() }
                    f.prepare()
                }
            }
        case .ended, .cancelled, .failed:
            if spaceLastSteps == 0 { insertText(" ") }
            cursorFeedback = nil
        default:
            break
        }
    }

    @objc private func clearInput() {
        guard let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty else {
            return
        }
        undoStack.append(before)
        for _ in 0..<(before as NSString).length { textDocumentProxy.deleteBackward() }
    }

    @objc private func restoreInput() {
        guard let last = undoStack.popLast() else { return }
        insertText(last)
    }

    /// 原型 .kbTool：38×38、#D4D6DE 灰底、圆角 10。
    /// 宽度约束降到 999，让 .kbTool.dark 的 76 宽能覆盖（两个 required 约束会冲突）。
    /// 工具条图标的统一视觉尺寸：自绘图标画在 24pt 画布里，
    /// SF Symbol 用 pointSize 19 时字形的实际高度也在 24pt 左右，两者看起来一样大。
    private func toolIconConfig() -> UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
    }

    private func toolButton(_ title: String) -> UIButton {
        let b = QPHapticButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        b.setTitleColor(QPColor.ink, for: .normal)
        // 用户要求：整排图标背景统一 —— 一律去掉底色，只留图标本身
        b.backgroundColor = .clear
        b.layer.cornerRadius = QPTool.radius
        let w = b.widthAnchor.constraint(equalToConstant: QPTool.size)
        w.priority = UILayoutPriority(999)
        w.isActive = true
        b.heightAnchor.constraint(equalToConstant: QPTool.size).isActive = true
        // 图标不许被压扁：整排键永远同一个 38×38 网格
        b.imageView?.contentMode = .scaleAspectFit
        return b
    }

    /// HTML symbol i-kbhide：键盘轮廓 + 两排键点 + 下箭头（收起键盘）
    private func kbHideIcon(_ color: UIColor) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        let c = QPTool.iconCanvas
        return UIGraphicsImageRenderer(size: CGSize(width: c, height: c), format: fmt).image { _ in
            color.setStroke()
            let frame = UIBezierPath(roundedRect: CGRect(x: 2, y: 3.5, width: 20, height: 11),
                                     cornerRadius: 2.4)
            frame.lineWidth = 1.7
            frame.stroke()
            let dots = UIBezierPath()
            for i in 0..<5 {
                let x = CGFloat(5.5 + Double(i) * 3.0)
                dots.move(to: CGPoint(x: x, y: 7.5)); dots.addLine(to: CGPoint(x: x + 1, y: 7.5))
                dots.move(to: CGPoint(x: x, y: 10.5)); dots.addLine(to: CGPoint(x: x + 1, y: 10.5))
            }
            dots.lineWidth = 1.6
            dots.lineCapStyle = .round
            dots.stroke()
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: 8, y: 17.4))
            arrow.addLine(to: CGPoint(x: 12, y: 21.1))
            arrow.addLine(to: CGPoint(x: 16, y: 17.4))
            arrow.lineWidth = 2.1
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
        }
    }

    /// HTML symbol i-copy：两个重叠矩形（连续复制）
    private func copyIcon(_ color: UIColor) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        let c = QPTool.iconCanvas
        return UIGraphicsImageRenderer(size: CGSize(width: c, height: c), format: fmt).image { _ in
            color.setStroke()
            let back = UIBezierPath(roundedRect: CGRect(x: 8, y: 3, width: 13, height: 15),
                                    cornerRadius: 2.6)
            back.lineWidth = 1.9
            back.stroke()
            let front = UIBezierPath()
            front.move(to: CGPoint(x: 16, y: 19))
            front.addLine(to: CGPoint(x: 5, y: 19))
            front.addCurve(to: CGPoint(x: 3, y: 17),
                           controlPoint1: CGPoint(x: 3.9, y: 19),
                           controlPoint2: CGPoint(x: 3, y: 18.1))
            front.addLine(to: CGPoint(x: 3, y: 6))
            front.lineWidth = 1.9
            front.lineCapStyle = .round
            front.stroke()
        }
    }

    // MARK: - v1.8.8 筛选 / 排序 / 导出（工具条漏斗 + 箭头按钮）

    /// 自绘「漏斗」筛选图标，24pt 画布、1.9pt 圆头描边，与整排图标统一。
    /// 不用 SF Symbol：旧名 line.3.decrease 已弃用，新系统渲染为空导致按钮隐形。
    private func filterIcon(_ color: UIColor) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        let c = QPTool.iconCanvas
        return UIGraphicsImageRenderer(size: CGSize(width: c, height: c), format: fmt).image { _ in
            color.setStroke()
            let funnel = UIBezierPath()
            funnel.move(to: CGPoint(x: 3.5, y: 4.5))
            funnel.addLine(to: CGPoint(x: 20.5, y: 4.5))
            funnel.addLine(to: CGPoint(x: 13.8, y: 11.8))
            funnel.addLine(to: CGPoint(x: 13.8, y: 18.6))
            funnel.addLine(to: CGPoint(x: 10.2, y: 16.4))
            funnel.addLine(to: CGPoint(x: 10.2, y: 11.8))
            funnel.close()
            funnel.lineWidth = 1.9
            funnel.lineJoinStyle = .round
            funnel.lineCapStyle = .round
            funnel.stroke()
        }
    }

    /// 整条内容是否是链接：纯网址，或包含 http(s):// / www. 开头的片段
    private static func isLinkItem(_ it: SyncItem) -> Bool {
        guard !it.isImage, it.type != "file" else { return false }
        let t = it.displayText
        return t.range(of: "https?://\\S+", options: .regularExpression) != nil
            || t.lowercased().hasPrefix("www.")
    }

    private func toggleSort() {
        prefs.sortNewestTop.toggle()
        refreshSortIcon()
        refreshList()
        showToast(prefs.sortNewestTop ? "已切到最新在上（↑）" : "已切到最旧在上（↓）")
    }

    private func refreshSortIcon() {
        guard let b = sortButton else { return }
        b.setImage(UIImage(systemName: prefs.sortNewestTop ? "arrow.up" : "arrow.down",
                           withConfiguration: toolIconConfig())?
                    .withRenderingMode(.alwaysTemplate), for: .normal)
        b.tintColor = QPColor.ink
    }

    private func refreshFilterTint() {
        filterButton?.tintColor = prefs.clipFilter == "all" ? QPColor.ink : .systemBlue
    }

    private func buildFilterMenu() {
        filterOverlay.isHidden = true
        filterOverlay.frame = view.bounds
        filterOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let tap = UITapGestureRecognizer(target: self, action: #selector(closeFilterMenu))
        tap.cancelsTouchesInView = false
        filterOverlay.addGestureRecognizer(tap)
        view.addSubview(filterOverlay)
        filterBox.layer.cornerRadius = 18
        filterBox.clipsToBounds = true
        filterOverlay.addSubview(filterBox)
        filterStack.axis = .vertical
        filterStack.distribution = .fillEqually
        filterStack.spacing = 0
        filterBox.contentView.addSubview(filterStack)
    }

    private func buildExportMenu() {
        exportOverlay.isHidden = true
        exportOverlay.frame = view.bounds
        exportOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let tap = UITapGestureRecognizer(target: self, action: #selector(closeExportMenu))
        tap.cancelsTouchesInView = false
        exportOverlay.addGestureRecognizer(tap)
        view.addSubview(exportOverlay)
        exportBox.layer.cornerRadius = 18
        exportBox.clipsToBounds = true
        exportOverlay.addSubview(exportBox)
        exportStack.axis = .vertical
        exportStack.distribution = .fillEqually
        exportStack.spacing = 0
        exportBox.contentView.addSubview(exportStack)
    }

    @objc private func closeFilterMenu() { filterOverlay.isHidden = true }
    @objc private func closeExportMenu() { exportOverlay.isHidden = true }

    /// 筛选菜单：磨砂圆角小卡片，贴在漏斗按钮正下方，选中项右侧 ✓（图2 样式）
    private func openFilterMenu(anchor: UIView) {
        closeMenu()
        closeCardMenu()
        closeExportMenu()
        filterStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let options: [(String, String)] = [
            ("all", "全部类型"), ("text", "文本"), ("link", "链接"),
            ("image", "图片"), ("file", "文件"),
        ]
        let current = prefs.clipFilter
        for (key, title) in options {
            filterStack.addArrangedSubview(
                filterRow(title, selected: current == key) { [weak self] in
                    guard let self = self else { return }
                    self.prefs.clipFilter = key
                    self.closeFilterMenu()
                    self.refreshFilterTint()
                    self.refreshList()
                    self.showToast(key == "all" ? "已显示全部类型" : "已筛选：\(title)")
                })
        }
        let bounds = view.bounds
        let w: CGFloat = 170
        let rowH: CGFloat = 42
        let h = CGFloat(options.count) * rowH
        let r = anchor.convert(anchor.bounds, to: view)
        let x = min(max(r.minX - 24, 8), bounds.width - w - 8)
        var y = r.maxY + 4
        if y + h > bounds.height - 8 { y = max(8, r.minY - h - 4) }
        filterOverlay.frame = bounds
        filterBox.frame = CGRect(x: x, y: y, width: w, height: h)
        filterStack.frame = CGRect(x: 0, y: 0, width: w, height: h)
        filterOverlay.isHidden = false
        view.bringSubviewToFront(filterOverlay)
    }

    private func filterRow(_ title: String, selected: Bool,
                           action: @escaping () -> Void) -> UIButton {
        let b = QPHapticButton(type: .custom)
        b.backgroundColor = .clear
        b.contentHorizontalAlignment = .leading
        b.setTitle(title, for: .normal)
        b.setTitleColor(QPColor.ink, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: selected ? .semibold : .regular)
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 40)
        if selected {
            let check = UIImageView(image: UIImage(systemName: "checkmark")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
            check.tintColor = QPColor.ink
            check.contentMode = .scaleAspectFit
            check.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(check)
            NSLayoutConstraint.activate([
                check.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -16),
                check.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            ])
        }
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    /// 长按漏斗按钮弹导出菜单（图3 类似效果）
    @objc private func handleExportPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        openExportMenu()
    }

    private func openExportMenu() {
        closeMenu()
        closeCardMenu()
        closeFilterMenu()
        exportStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        exportStack.addArrangedSubview(exportRow("导出为 TXT", icon: "doc.plaintext") {
            self.exportClipboard(as: "txt")
        })
        exportStack.addArrangedSubview(exportRow("导出为 CSV", icon: "tablecells") {
            self.exportClipboard(as: "csv")
        })
        exportStack.addArrangedSubview(exportRow("导出为图片", icon: "photo.on.rectangle") {
            self.exportClipboard(as: "image")
        })
        let bounds = view.bounds
        let w: CGFloat = 190
        let rowH: CGFloat = 42
        let h = CGFloat(exportStack.arrangedSubviews.count) * rowH
        let r = filterButton?.convert(filterButton!.bounds, to: view)
            ?? CGRect(x: bounds.width - 100, y: 0, width: 38, height: 38)
        let x = min(max(r.minX - 30, 8), bounds.width - w - 8)
        var y = r.maxY + 4
        if y + h > bounds.height - 8 { y = max(8, r.minY - h - 4) }
        exportOverlay.frame = bounds
        exportBox.frame = CGRect(x: x, y: y, width: w, height: h)
        exportStack.frame = CGRect(x: 0, y: 0, width: w, height: h)
        exportOverlay.isHidden = false
        view.bringSubviewToFront(exportOverlay)
    }

    private func exportRow(_ title: String, icon: String,
                           action: @escaping () -> Void) -> UIButton {
        let b = QPHapticButton(type: .custom)
        b.backgroundColor = .clear
        b.contentHorizontalAlignment = .leading
        b.setTitle(title, for: .normal)
        b.setTitleColor(QPColor.ink, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 52, bottom: 0, right: 12)
        let iv = UIImageView(image: UIImage(systemName: icon)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)))
        iv.tintColor = QPColor.ink
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 18),
            iv.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 22),
            iv.heightAnchor.constraint(equalToConstant: 22),
        ])
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    /// 把当前列表（已按筛选/排序，所见即所得）导出成文件发到电脑 sync 服务。
    /// 走 POST /api/file（LocalSend 风格），电脑端落在 sync/files/ 并进列表。
    private func exportClipboard(as format: String) {
        closeExportMenu()
        guard hasFullAccess else { showToast("需要开启「允许完全访问」才能导出"); return }
        let items = displayItems
        guard !items.isEmpty else { showToast("列表为空，没有可导出的内容"); return }
        let texts = items.filter { !$0.isImage && $0.type != "file" }
        let images = items.filter { $0.isImage }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"

        func send(_ data: Data, name: String, mime: String) {
            client.pushFile(data, name: name, mime: mime) { err in
                DispatchQueue.main.async {
                    self.showToast(err == nil ? "已导出到电脑：\(name)"
                                               : "导出失败：\(err ?? "")")
                }
            }
        }

        switch format {
        case "txt":
            let lines = texts.enumerated().map { (i, it) -> String in
                let time = fmt.string(from: Date(timeIntervalSince1970: it.ts / 1000))
                return "【\(i + 1)】\(time)（\(it.fromPhone ? "手机" : "电脑")）\n\(it.text)"
            }
            let head = "QuickPaste 剪贴板导出（\(fmt.string(from: Date()))，共 \(texts.count) 条）"
            let body = head + "\n\n" + lines.joined(separator: "\n\n————\n\n")
            send(body.data(using: .utf8) ?? Data(),
                 name: "QuickPaste-剪贴板-\(stamp.string(from: Date())).txt",
                 mime: "text/plain")
        case "csv":
            var rows = ["序号,时间,来源,类型,内容"]
            for (i, it) in texts.enumerated() {
                let time = fmt.string(from: Date(timeIntervalSince1970: it.ts / 1000))
                let content = it.text
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\"", with: "\"\"")
                rows.append("\(i + 1),\(time),\(it.fromPhone ? "手机" : "电脑"),\(it.type),\"\(content)\"")
            }
            var data = Data([0xEF, 0xBB, 0xBF])   // BOM：Excel 打开中文不乱码
            data.append(rows.joined(separator: "\r\n").data(using: .utf8) ?? Data())
            send(data, name: "QuickPaste-剪贴板-\(stamp.string(from: Date())).csv",
                 mime: "text/csv")
        case "image":
            let text = texts.map { $0.text }.joined(separator: "\n\n")
            guard !text.isEmpty else { showToast("没有可渲染的文字内容"); return }
            let png = renderTextImage(text, title: "QuickPaste 剪贴板导出 · \(fmt.string(from: Date()))")
            guard let data = png.pngData() else { showToast("图片生成失败"); return }
            send(data, name: "QuickPaste-剪贴板-\(stamp.string(from: Date())).png",
                 mime: "image/png")
            // 列表里的图片条目：原图一并推送（最多 5 张）
            for it in images.prefix(5) {
                if let d = it.imageData {
                    client.pushImage(d, mime: it.mime) { err in
                        DispatchQueue.main.async {
                            if err != nil { self.showToast("图片推送失败：\(err ?? "")") }
                        }
                    }
                }
            }
        default:
            break
        }
    }

    /// 文字渲染成白底长图（宽 640pt，@2x），用于「导出为图片」
    private func renderTextImage(_ text: String, title: String) -> UIImage {
        let width: CGFloat = 640
        let inset: CGFloat = 24
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .semibold)
        ]
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5
        let bodyAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15), .paragraphStyle: para
        ]
        let measure = CGSize(width: width - inset * 2, height: .greatestFiniteMagnitude)
        let titleH = (title as NSString).boundingRect(
            with: measure, options: [.usesLineFragmentOrigin],
            attributes: titleAttr, context: nil).height
        let bodyH = (text as NSString).boundingRect(
            with: measure, options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: bodyAttr, context: nil).height
        let height = min(max(titleH + bodyH + inset * 2 + 20, 200), 12000)
        let rfmt = UIGraphicsImageRendererFormat()
        rfmt.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                       format: rfmt).image { ctx in
            UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var y = inset
            (title as NSString).draw(
                in: CGRect(x: inset, y: y, width: width - inset * 2, height: titleH + 8),
                withAttributes: titleAttr)
            y += titleH + 14
            (text as NSString).draw(
                with: CGRect(x: inset, y: y, width: width - inset * 2, height: height - y - inset),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: bodyAttr, context: nil)
        }
    }

    private func showToast(_ text: String) {
        // 「显示新内容已保存提示」只控制这类提示，错误/状态提示不受影响
        if !prefs.savedTip && (text.contains("已保存") || text.contains("已收录")) { return }
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12)
        l.textColor = .white
        l.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        l.textAlignment = .center
        l.numberOfLines = 2
        l.layer.cornerRadius = 14
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -58),
            l.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -30),
            l.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
        UIView.animate(withDuration: 0.25, delay: 1.6, options: [],
                       animations: { l.alpha = 0 }) { _ in l.removeFromSuperview() }
    }

    // MARK: - 设置界面联动：所有开关即时作用到键盘

    private func applySettings() {
        imageCloseButton?.isHidden = !prefs.floatClose
        // refreshSymbols 内部会按 prefs.align 重排工具条符号区
        refreshSymbols()
        refreshTabBar()
        refreshCopyButton()
        refreshCopyOverlay()
        refreshList()
        refreshHead()
        let totalHeight = prefs.height + kbBarHeight
        if heightConstraint.constant != totalHeight {
            heightConstraint.constant = totalHeight
        }
        view.setNeedsLayout()
        if prefs.syncAuto { startPolling() } else { stopPolling() }
        // 设置页里改了「启用连续复制」也要立刻同步浮层与轮询
        syncCaptureState()
    }

}

// MARK: - 「交互补读」手势与按钮、滚动手势共存，不拦截点击

extension KeyboardViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// 菜单遮罩的「点外部关闭」不要吃掉菜单按钮自己的点击
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer.view === cardMenuOverlay ||
              gestureRecognizer.view === menuOverlay else { return true }
        var v: UIView? = touch.view
        while let cur = v {
            if cur is UIButton { return false }
            v = cur.superview
        }
        return true
    }
}

// MARK: - KeyboardSettingsDelegate

extension KeyboardViewController: KeyboardSettingsDelegate {

    func settingsStatus() -> (title: String, count: Int, url: String, backend: String) {
        let title: String
        switch syncState {
        case "online": title = "已连接"
        case "connecting": title = "连接中"
        case "error": title = "连接失败"
        default: title = "未连接"
        }
        return (title, displayItems.count, prefs.syncURL, backend)
    }

    func settingsDidChange() { applySettings() }

    func settingsSyncNow() { pull(showConnecting: true) }

    func settingsSendInputText() { sendInputTextToPc() }

    func settingsSendPasteboardText() { sendPasteboardTextToPc() }

    func settingsSendPasteboardImage() { sendPasteboardImageToPc() }

    func settingsAdoptURL() -> Bool {
        let changed = prefs.adoptPasteboardURL()
        if changed { refreshHead() }
        return changed
    }

    func settingsResetURL() {
        prefs.syncURL = KeyboardPrefs.defaultURL
        showToast("已重置为默认地址")
        refreshHead()
    }

    func settingsClearAll() { clearAllHistory() }

    func settingsSwitchKeyboard() { advanceToNextInputMode() }

    func settingsInsertText(_ text: String) {
        insertText(text)
        showToast("已插入到输入框")
    }

    func settingsToast(_ text: String) { showToast(text) }
}

// MARK: - v1.6 原型配色

/// 按键震动（v1.8.6）：键盘里所有按钮共用这一个子类，
/// 按下（touchesBegan）就轻震一下，不等抬起，跟手感最好。
/// 开关沿用「按键震动」（qp.cursorHaptic，默认开），关掉后所有按钮都不震。
final class QPHapticButton: UIButton {
    private static let feedback = UIImpactFeedbackGenerator(style: .light)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if (UserDefaults.standard.object(forKey: "qp.cursorHaptic") as? Bool) ?? true {
            Self.feedback.impactOccurred()
        }
    }
}

enum QPColor {
    static let bg = UIColor.rgb(243, 244, 249)
    /// 自适应“墨色”：浅色模式近黑、深色模式近白 —— 键盘根视图透明后
    /// 图标/文字直接画在系统玻璃底上，深色模式下深色图标会看不见
    static let ink = UIColor { tc in
        tc.userInterfaceStyle == .dark ? UIColor.rgb(240, 241, 245) : UIColor.rgb(17, 17, 17)
    }
    static let blue = UIColor.rgb(10, 124, 255)
    static let blueSoft = UIColor.rgb(232, 241, 255)
    static let green = UIColor.rgb(52, 199, 89)
    static let orange = UIColor.rgb(255, 149, 0)
    static let red = UIColor.rgb(255, 59, 48)
    static let sub = UIColor.rgb(138, 138, 143)
    static let sep = UIColor.rgb(230, 230, 235)
    static let keyBg = UIColor.rgb(212, 214, 222)
}

private extension UIColor {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
}

/// 工具条上所有按钮共用同一套尺寸，避免「大小不一」：
/// 收起键盘 / 地球 / 连续复制 / 符号 / ⋯ 全部 38×38、圆角 10、图标 24pt 画布；
/// 删除键按用户要求保留 76×38 的横条（高度与其它键一致）。
enum QPTool {
    static let size: CGFloat = 38
    static let radius: CGFloat = 10
    static let iconCanvas: CGFloat = 24
}

private enum QPTime {
    static func string(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }
}
