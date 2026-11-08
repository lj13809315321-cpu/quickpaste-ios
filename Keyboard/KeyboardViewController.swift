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
    /// 当前滑开的卡片，滑开新的就把旧的收回去
    private weak var openedCard: QPSwipeCard?
    /// 键盘可见期间【常驻】的剪贴板轮询，与「连续复制 / 画中画」开关完全解耦。
    /// 旧版只在连续复制开启时才轮询，导致弹起键盘后复制第二段必须收起再弹。
    private var pasteboardTimer: Timer?
    /// 本次呼出键盘后抓到的新条数（浮层上显示，用户能一眼看出到底有没有在抓）
    private var capturedCount = 0
    /// 连续复制浮层
    private var copyOverlay: UIView?
    /// 主 App 的系统画中画是否正在后台监控
    private var pipRunning = false
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
    private let menuOverlay = UIView()
    private let menuStack = UIStackView()
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
    private var currentImageItem: SyncItem?

    private var client: SyncClient {
        SyncClient(url: prefs.syncURL, pair: prefs.syncPair)
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = QPColor.bg

        heightConstraint = view.heightAnchor.constraint(equalToConstant: prefs.height)
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
        startPasteboardTimer()
        checkClipboard(force: true)
        refreshHead()
        refreshTabBar()
        refreshCopyButton()
        refreshCopyOverlay()
        refreshSymbols()
        refreshList()
        pull(showConnecting: true)
        startPolling()
        syncCaptureState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        stopPolling()
        stopPasteboardTimer()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if heightConstraint.constant != prefs.height {
            heightConstraint.constant = prefs.height
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
        guard force || changed else { return false }

        prefs.refreshMute()

        var dirty = false

        // ① 主 App 画中画抓到的（可选增强；读不到也不影响键盘自己抓）
        let shared = QPSharedHistory.read()
        if pipRunning != shared.pip {
            pipRunning = shared.pip
            refreshCopyOverlay()
        }
        for text in shared.items.reversed() where !text.isEmpty {
            if !prefs.isMuted(text) && prefs.capture(text) { dirty = true }
        }

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
            }
            prefs.lastSeenChange = change
        }

        if dirty {
            refreshList()
            refreshCopyOverlay()
        }
        return dirty
    }

    // MARK: - 连续复制（键盘内监听 + 可选画中画）

    private func toggleContinuous() {
        guard hasFullAccess else {
            showToast("请先在 设置 → 键盘 → QuickPaste 开启「允许完全访问」")
            return
        }
        prefs.continuous.toggle()
        capturedCount = 0
        refreshCopyButton()
        refreshCopyOverlay()
        if prefs.continuous {
            showToast("连续复制已开启")
            // 键盘扩展自己起不了画中画，试着拉起主 App；失败也不影响键盘内抓取
            if !pipRunning { _ = openMainApp("pip/start") }
        } else {
            showToast("已结束连续复制")
        }
    }

    /// 键盘扩展里 UIApplication.shared 不可用，沿响应链找 openURL: 打开主 App。
    @discardableResult
    private func openMainApp(_ path: String) -> Bool {
        guard let url = URL(string: "quickpaste://" + path) else { return false }
        let sel = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: sel) {
                _ = r.perform(sel, with: url)
                return true
            }
            responder = r.next
        }
        extensionContext?.open(url, completionHandler: nil)
        return false
    }

    @objc private func openContinuousSettings(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        settings.show(.continuous)
    }

    private func syncCaptureState() {
        refreshCopyButton()
        refreshCopyOverlay()
    }

    /// 键盘内浮层（HTML 原型 floatwin）：绿点 + 「连续复制中… 已收 N 条」+ 结束。
    /// 它只是状态反馈，真正的抓取在 checkClipboard 里，收起键盘前一直有效。
    private func refreshCopyOverlay() {
        guard prefs.continuous else {
            copyOverlay?.isHidden = true
            return
        }
        let v: UIView
        if let exist = copyOverlay {
            v = exist
        } else {
            v = buildCopyOverlay()
            view.addSubview(v)
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                v.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -56),
                v.widthAnchor.constraint(equalToConstant: 228)
            ])
            copyOverlay = v
        }
        v.isHidden = false
        (v.viewWithTag(401) as? UILabel)?.text = "连续复制中… 已收 \(capturedCount) 条"
        // 画中画没开时提示：键盘收起后就会停
        (v.viewWithTag(402) as? UIButton)?.isHidden = pipRunning
    }

    private func buildCopyOverlay() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor.rgb(32, 33, 38)
        v.layer.cornerRadius = 15
        v.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 10)

        let dot = UIView()
        dot.backgroundColor = QPColor.green
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        row.addArrangedSubview(dot)

        let label = UILabel()
        label.tag = 401
        label.text = "连续复制中… 已收 0 条"
        label.textColor = .white
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        row.addArrangedSubview(label)

        let stop = UIButton(type: .system)
        stop.setTitle("结束", for: .normal)
        stop.setTitleColor(UIColor.rgb(120, 190, 255), for: .normal)
        stop.titleLabel?.font = .systemFont(ofSize: 12.5, weight: .semibold)
        stop.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.prefs.continuous = false
            self.refreshCopyButton()
            self.refreshCopyOverlay()
            self.showToast("已结束连续复制")
        }, for: .touchUpInside)
        row.addArrangedSubview(stop)

        let hint = UIButton(type: .system)
        hint.tag = 402
        hint.setTitle("收起键盘后要继续抓 → 打开 App 开画中画", for: .normal)
        hint.titleLabel?.font = .systemFont(ofSize: 10.5)
        hint.setTitleColor(UIColor.rgb(255, 214, 102), for: .normal)
        hint.contentHorizontalAlignment = .left
        hint.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 5, right: 10)
        hint.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            if !self.openMainApp("pip/start") {
                self.showToast("请打开 QuickPaste →「连续复制」→ 开启画中画")
            }
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [row, hint])
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        ])
        return v
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
        let sig = r.items.prefix(10).map { "\($0.id):\($0.ts)" }.joined(separator: "|")
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
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// 状态头整块已删掉：连接提示只占工具条上一个 9pt 小圆点，
    /// 省下的 68px 全给剪贴板列表。小圆点插在「⋯」和右边黑色 ✕ 之间。
    private func buildStatusDot() {
        let holder = UIView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.widthAnchor.constraint(equalToConstant: 14).isActive = true
        holder.heightAnchor.constraint(equalToConstant: 32).isActive = true

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
        collapse.setImage(kbHideIcon(UIColor.rgb(17, 17, 17)).withRenderingMode(.alwaysOriginal),
                          for: .normal)
        collapse.backgroundColor = .clear
        collapse.addAction(UIAction { [weak self] _ in self?.dismissKeyboard() },
                           for: .touchUpInside)
        let holdCollapse = UILongPressGestureRecognizer(target: self,
                                                        action: #selector(handleMenuPress(_:)))
        holdCollapse.minimumPressDuration = 1.0
        collapse.addGestureRecognizer(holdCollapse)
        toolbar.addArrangedSubview(collapse)

        // 地球键用 SF Symbols 的单色「globe」而不是 🌐 emoji：
        // emoji 一定是彩色的，用户要求跟其它图标一个颜色（黑），像系统键盘那样。
        let globe = toolButton("")
        let globeCfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        globe.setImage(UIImage(systemName: "globe", withConfiguration: globeCfg)?
                        .withRenderingMode(.alwaysTemplate), for: .normal)
        globe.tintColor = UIColor.rgb(17, 17, 17)
        globe.addAction(UIAction { [weak self] _ in self?.advanceToNextInputMode() },
                        for: .touchUpInside)
        // 无 SF Symbols 时退回文字（极少见），同样是单色
        if globe.image(for: .normal) == nil {
            globe.setTitle("🌐", for: .normal)
        }
        toolbar.addArrangedSubview(globe)

        // HTML 原型 .kbTool.copyBtn：连续复制一级开关，蓝色=开启；与「同步」无关
        let copyBtn = toolButton("")
        copyBtn.tag = 101
        copyBtn.setImage(copyIcon(.black).withRenderingMode(.alwaysTemplate), for: .normal)
        copyButton = copyBtn
        copyBtn.addAction(UIAction { [weak self] _ in self?.toggleContinuous() },
                          for: .touchUpInside)
        let holdCopy = UILongPressGestureRecognizer(target: self,
                                                    action: #selector(openContinuousSettings(_:)))
        holdCopy.minimumPressDuration = 0.6
        copyBtn.addGestureRecognizer(holdCopy)
        toolbar.addArrangedSubview(copyBtn)

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
        // 原型 .kbTool.dark：76 宽、#2B2C31 黑底、白字
        deleteKey.backgroundColor = UIColor.rgb(43, 44, 49)
        deleteKey.setTitleColor(.white, for: .normal)
        deleteKey.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        // HTML .kbTool.dark：宽 76（与底行「发送」同级），图标靠右、右内边距 8
        deleteKey.widthAnchor.constraint(equalToConstant: 76).isActive = true
        deleteKey.contentHorizontalAlignment = .right
        deleteKey.contentEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        deleteKey.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.deleteBackward()
        }, for: .touchUpInside)
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(clearInput))
        swipeUp.direction = .up
        deleteKey.addGestureRecognizer(swipeUp)
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(restoreInput))
        swipeDown.direction = .down
        deleteKey.addGestureRecognizer(swipeDown)
        let holdDelete = UILongPressGestureRecognizer(target: self,
                                                      action: #selector(handleMenuPress(_:)))
        holdDelete.minimumPressDuration = 1.0
        deleteKey.addGestureRecognizer(holdDelete)
        toolbar.addArrangedSubview(deleteKey)

        root.addArrangedSubview(toolbar)
    }

    private func refreshCopyButton() {
        guard let b = copyButton else { return }
        // 蓝色 = 键盘自己的连续复制开关（立即生效，不再读画中画状态，
        // 否则主 App 写共享通道时颜色会自己跳来跳去）
        let on = prefs.continuous
        b.backgroundColor = on ? QPColor.blue : QPColor.keyBg
        b.tintColor = on ? .white : UIColor.rgb(17, 17, 17)
        b.layer.cornerRadius = 10
    }

    private func refreshSymbols() {
        symStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 原型 .kbToolbar .spL/.spR：居左/居中/居右由两端弹性占位实现
        let leadSpacer = UIView(), trailSpacer = UIView()
        leadSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if prefs.align != "left" { symStack.addArrangedSubview(leadSpacer) }

        for symbol in prefs.symbols.prefix(prefs.symbolCount) {
            let b = UIButton(type: .system)
            b.setTitle(symbol, for: .normal)
            // 原型 .kbSym：28×32、#D4D6DE、圆角 8、字号 20
            b.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
            b.setTitleColor(.black, for: .normal)
            b.backgroundColor = QPColor.keyBg
            b.layer.cornerRadius = 8
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            b.addAction(UIAction { [weak self] _ in
                self?.textDocumentProxy.insertText(symbol)
            }, for: .touchUpInside)
            symStack.addArrangedSubview(b)
        }
        let more = UIButton(type: .system)
        more.setTitle("⋯", for: .normal)
        more.titleLabel?.font = .systemFont(ofSize: 15)
        more.setTitleColor(.black, for: .normal)
        more.backgroundColor = QPColor.keyBg
        more.layer.cornerRadius = 8
        more.widthAnchor.constraint(equalToConstant: 26).isActive = true
        more.heightAnchor.constraint(equalToConstant: 32).isActive = true
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
            let b = UIButton(type: .system)
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
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // ★ 主列表 = 本机复制历史 + 电脑同步记录，不依赖是否连上电脑
        displayItems = mergedItems()

        guard !displayItems.isEmpty else {
            let msg = !hasFullAccess
                ? "无法读取剪贴板\n请到 设置 → 通用 → 键盘 → QuickPaste\n开启「允许完全访问」"
                : "暂无剪贴板内容\n在任意 App 复制文字后切回键盘，或连接电脑同步"
            listStack.addArrangedSubview(emptyLabel(msg))
            let b = UIButton(type: .system)
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

    /// 本机复制历史在前，电脑同步记录在后；按文字去重，最多 30 条。
    private func mergedItems() -> [SyncItem] {
        var all: [SyncItem] = []
        var seen = Set<String>()
        for text in prefs.items(for: "clip") {
            guard !prefs.isMuted(text),
                  seen.insert("t:" + text).inserted else { continue }
            all.append(SyncItem(id: "local:" + text, text: text, type: "text",
                                image: "", mime: "", source: "local",
                                ts: Date().timeIntervalSince1970 * 1000))
        }
        // 主 App 画中画期间，在别的 App 里复制的内容
        for text in QPSharedHistory.read().items {
            guard !text.isEmpty, !prefs.isMuted(text),
                  seen.insert("t:" + text).inserted else { continue }
            all.append(SyncItem(id: "pip:" + text, text: text, type: "text",
                                image: "", mime: "", source: "local",
                                ts: Date().timeIntervalSince1970 * 1000))
        }
        for it in items {
            let key = it.isImage ? "i:" + it.id : "t:" + it.displayText
            guard seen.insert(key).inserted else { continue }
            all.append(it)
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
        let card = UIButton(type: .custom)
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
            self?.textDocumentProxy.insertText(text)
            if self?.prefs.autoCollapse == true { self?.dismissKeyboard() }
        }, for: .touchUpInside)
        return card
    }

    private func makeSyncCard(item: SyncItem, index: Int) -> UIView {
        // 卡片本体（白底圆角）交给 QPSwipeCard 包一层：右滑分词/预览、左滑编辑/删除
        let card = UIView()
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
                self.textDocumentProxy.insertText(item.text)
                if self.prefs.autoCollapse { self.dismissKeyboard() }
            }
        }
        wrap.onLongPress = { [weak self] in
            self?.openCardMenu(item)
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
        let b = UIButton(type: .system)
        b.setTitle("清空剪贴板  🗑", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        b.setTitleColor(QPColor.sub, for: .normal)
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        b.addAction(UIAction { [weak self] _ in self?.clearAllHistory() }, for: .touchUpInside)
        b.isHidden = !prefs.clearBtn
        return b
    }

    // MARK: - 计算器（算式直接写进目标 App 的输入框）

    /// 用户要的行为：按 7 就真的在对话框里出现 7，按 + 出现 +，
    /// 按 = 时才把光标前这段算式换成结果（7+8 → 15）。键盘自己不显示算式。
    private func buildCalc() {
        calcBox.axis = .vertical
        calcBox.spacing = 8
        calcBox.alignment = .fill
        calcBox.isHidden = true
        calcBox.isLayoutMarginsRelativeArrangement = true
        calcBox.layoutMargins = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let hint = UILabel()
        hint.text = "按键直接输入到输入框，点 = 出结果"
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = QPColor.sub
        hint.textAlignment = .center
        calcBox.addArrangedSubview(hint)

        // HTML .calcKeys：gap 8、键高 44、字号 19、圆角 9；「=」与「收起」为蓝色主按钮
        let rows: [[String]] = [
            ["7", "8", "9", "÷", "⌫"],
            ["4", "5", "6", "×", "("],
            ["1", "2", "3", "−", ")"],
            ["0", ".", "=", "+", "收起"]
        ]
        for keys in rows {
            let r = UIStackView()
            r.axis = .horizontal
            r.spacing = 8
            r.distribution = .fillEqually
            for key in keys {
                let primary = (key == "=" || key == "收起")
                let b = UIButton(type: .system)
                b.setTitle(key, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
                b.setTitleColor(primary ? .white : UIColor.rgb(17, 17, 17), for: .normal)
                b.layer.cornerRadius = 9
                b.backgroundColor = primary ? QPColor.blue : QPColor.keyBg
                let h = b.heightAnchor.constraint(equalToConstant: 40)
                h.priority = UILayoutPriority(999)
                h.isActive = true
                b.addAction(UIAction { [weak self] _ in self?.handleCalcKey(key) },
                            for: .touchUpInside)
                r.addArrangedSubview(b)
            }
            calcBox.addArrangedSubview(r)
        }
        root.addArrangedSubview(calcBox)
    }

    private func toggleCalcMode() {
        isCalcMode.toggle()
        calcBox.isHidden = !isCalcMode
        listScroll.isHidden = isCalcMode
    }

    private func handleCalcKey(_ key: String) {
        switch key {
        case "收起":
            toggleCalcMode()
        case "⌫":
            textDocumentProxy.deleteBackward()
        case "=":
            evaluateInline()
        default:
            // 数字 / 运算符 / 括号 / 小数点：直接写进当前 App 的输入框
            textDocumentProxy.insertText(key)
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
        textDocumentProxy.insertText(value.calcText)
    }

    // MARK: - 底行 (.kbKeys)

    private func buildBottomBar() {
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.spacing = 6
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 2, left: 10, bottom: 6, right: 10)
        bar.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let calc = UIButton(type: .system)
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

        let space = UIButton(type: .system)
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

        let newline = UIButton(type: .system)
        newline.setTitle("换行", for: .normal)
        newline.titleLabel?.font = .systemFont(ofSize: 15)
        newline.setTitleColor(.black, for: .normal)
        newline.backgroundColor = QPColor.keyBg
        newline.layer.cornerRadius = 9
        newline.widthAnchor.constraint(equalToConstant: 64).isActive = true
        newline.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText("\n")
        }, for: .touchUpInside)
        bar.addArrangedSubview(newline)

        let send = UIButton(type: .system)
        send.setTitle("发送", for: .normal)
        // 原型 .kbKey.send：蓝色、白字、宽 66、字重 600
        send.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        send.setTitleColor(.white, for: .normal)
        send.backgroundColor = QPColor.blue
        send.layer.cornerRadius = 9
        send.widthAnchor.constraint(equalToConstant: 66).isActive = true
        send.addAction(UIAction { [weak self] _ in self?.sendInputTextToPc() },
                       for: .touchUpInside)
        let longSend = UILongPressGestureRecognizer(target: self,
                                                    action: #selector(sendLongPress(_:)))
        send.addGestureRecognizer(longSend)
        bar.addArrangedSubview(send)

        root.addArrangedSubview(bar)
    }

    @objc private func sendLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        textDocumentProxy.insertText("\n")
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
        menuOverlay.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                                action: #selector(closeMenu)))

        menuStack.axis = .vertical
        menuStack.spacing = 0
        menuStack.translatesAutoresizingMaskIntoConstraints = false
        menuStack.backgroundColor = .secondarySystemBackground
        menuStack.layer.cornerRadius = 12
        menuStack.clipsToBounds = true
        menuOverlay.addSubview(menuStack)
        NSLayoutConstraint.activate([
            menuStack.leadingAnchor.constraint(equalTo: menuOverlay.leadingAnchor, constant: 14),
            menuStack.trailingAnchor.constraint(equalTo: menuOverlay.trailingAnchor, constant: -14),
            menuStack.centerYAnchor.constraint(equalTo: menuOverlay.centerYAnchor)
        ])
    }

    private func openMenu() {
        menuStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        menuOverlay.isHidden = false
        menuStack.addArrangedSubview(menuTitle("快捷操作 · v1.6 同步"))
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

    /// 长按条目的菜单：分词 / 置顶 / 预览 / 编辑 / 删除（对齐用户第 6 张截图）
    private func openCardMenu(_ item: SyncItem?) {
        menuStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        menuOverlay.isHidden = false
        guard let item = item else { return }
        let preview = item.isImage ? "图片" : String(item.displayText.prefix(24))
        menuStack.addArrangedSubview(menuTitle(preview))

        if !item.isImage {
            menuStack.addArrangedSubview(menuRow("✂️ 分词") { [weak self] in
                self?.closeMenu(); self?.openSegment(item)
            })
        }
        let pinKey = item.isLocal ? item.text : item.displayText
        let pinned = prefs.pinned.contains(pinKey)
        menuStack.addArrangedSubview(menuRow(pinned ? "📌 取消置顶" : "📌 置顶") { [weak self] in
            guard let self = self else { return }
            self.prefs.togglePin(pinKey)
            self.refreshList(); self.closeMenu()
            self.showToast(pinned ? "已取消置顶" : "已置顶")
        })
        menuStack.addArrangedSubview(menuRow(item.isImage ? "👁 放大查看" : "👁 预览") { [weak self] in
            self?.closeMenu()
            if item.isImage { self?.showImage(item) } else { self?.openPreview(item) }
        })
        if !item.isImage {
            menuStack.addArrangedSubview(menuRow("✏️ 编辑") { [weak self] in
                self?.closeMenu(); self?.openEdit(item)
            })
        }
        menuStack.addArrangedSubview(menuRow("🗑 删除") { [weak self] in
            self?.closeMenu(); self?.deleteCard(item)
        })
        menuStack.addArrangedSubview(menuRow("↑ 发送到电脑") { [weak self] in
            guard let self = self else { return }
            if item.isImage, let d = item.imageData {
                self.client.pushImage(d, mime: item.mime) { err in
                    DispatchQueue.main.async {
                        self.showToast(err == nil ? "图片已发送到电脑" : ("发图失败：" + (err ?? "")))
                    }
                }
            } else { self.sendTextToPc(item.text) }
            self.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("关闭菜单") { [weak self] in self?.closeMenu() })
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
        QPSharedHistory.clear()    // 有 App Group 才真清共享；否则不动剪贴板
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
            let b = UIButton(type: .system)
            b.setTitle(t, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14)
            b.setTitleColor(UIColor.rgb(17, 17, 17), for: .normal)
            b.contentHorizontalAlignment = .left
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            b.backgroundColor = QPColor.blueSoft
            b.layer.cornerRadius = 8
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            b.addAction(UIAction { [weak self] _ in
                self?.textDocumentProxy.insertText(t)
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
            let b = UIButton(type: .system)
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
        let cancel = UIButton(type: .system)
        cancel.setTitle("关闭", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        cancel.setTitleColor(QPColor.sub, for: .normal)
        cancel.backgroundColor = QPColor.bg
        cancel.layer.cornerRadius = 10
        cancel.heightAnchor.constraint(equalToConstant: 38).isActive = true
        cancel.addAction(UIAction { [weak self] _ in self?.closeSheet() }, for: .touchUpInside)
        bar.addArrangedSubview(cancel)
        if let title = confirmTitle {
            let ok = UIButton(type: .system)
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
        let b = UIButton(type: .system)
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
        let copyBtn = UIButton(type: .system)
        copyBtn.setTitle("复制到剪贴板", for: .normal)
        copyBtn.setTitleColor(.white, for: .normal)
        copyBtn.backgroundColor = QPColor.blue
        copyBtn.layer.cornerRadius = 9
        copyBtn.addAction(UIAction { [weak self] _ in
            if let it = self?.currentImageItem { self?.copyImageToPasteboard(it) }
            self?.closeImage()
        }, for: .touchUpInside)
        bar.addArrangedSubview(copyBtn)
        let close = UIButton(type: .system)
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
        tip.text = "iOS 键盘不能直接插入图片，复制后到输入框长按粘贴"
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .white
        tip.textAlignment = .center
        tip.translatesAutoresizingMaskIntoConstraints = false
        imageOverlay.addSubview(tip)
        NSLayoutConstraint.activate([
            tip.leadingAnchor.constraint(equalTo: imageOverlay.leadingAnchor, constant: 12),
            tip.trailingAnchor.constraint(equalTo: imageOverlay.trailingAnchor, constant: -12),
            tip.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10)
        ])
    }

    private func showImage(_ item: SyncItem) {
        guard let d = item.imageData, let img = UIImage(data: d) else {
            showToast("图片解码失败")
            return
        }
        currentImageItem = item
        imageBig.image = img
        imageOverlay.isHidden = false
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

    @objc private func handleSpace(_ g: UILongPressGestureRecognizer) {
        let x = g.location(in: view).x
        switch g.state {
        case .began:
            spaceOriginX = x
            spaceLastSteps = 0
        case .changed:
            guard prefs.spaceCursor else { return }
            let steps = Int((x - spaceOriginX) / 10)
            let delta = steps - spaceLastSteps
            if delta != 0 {
                textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
                spaceLastSteps = steps
            }
        case .ended, .cancelled, .failed:
            if spaceLastSteps == 0 { textDocumentProxy.insertText(" ") }
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
        textDocumentProxy.insertText(last)
    }

    /// 原型 .kbTool：38×38、#D4D6DE 灰底、圆角 10。
    /// 宽度约束降到 999，让 .kbTool.dark 的 76 宽能覆盖（两个 required 约束会冲突）。
    private func toolButton(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        b.setTitleColor(.black, for: .normal)
        b.backgroundColor = QPColor.keyBg
        b.layer.cornerRadius = 10
        let w = b.widthAnchor.constraint(equalToConstant: 38)
        w.priority = UILayoutPriority(999)
        w.isActive = true
        b.heightAnchor.constraint(equalToConstant: 38).isActive = true
        return b
    }

    /// HTML symbol i-kbhide：键盘轮廓 + 两排键点 + 下箭头（收起键盘）
    private func kbHideIcon(_ color: UIColor) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: fmt).image { _ in
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
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: fmt).image { _ in
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
        if heightConstraint.constant != prefs.height {
            heightConstraint.constant = prefs.height
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
        textDocumentProxy.insertText(text)
        showToast("已插入到输入框")
    }

    func settingsToast(_ text: String) { showToast(text) }
}

// MARK: - v1.6 原型配色

enum QPColor {
    static let bg = UIColor.rgb(243, 244, 249)
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

private enum QPTime {
    static func string(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }
}
