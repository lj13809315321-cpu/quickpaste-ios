import UIKit
import ImageIO

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
    /// 主列表实际渲染的数据：本机复制历史 + 电脑同步记录（不依赖联网）
    private var displayItems: [SyncItem] = []
    /// 连续复制：键盘可见期间轮询系统剪贴板 + 「连续复制中…」浮层
    private var captureTimer: Timer?
    private var floatingView: UIView?
    private weak var copyButton: UIButton?

    private let root = UIStackView()
    private let head = UIView()
    private let toolbar = UIStackView()
    private let symScroll = UIScrollView()
    private let symStack = UIStackView()
    private let tabBar = UIStackView()
    private let listScroll = UIScrollView()
    private let listStack = UIStackView()
    private let calcBox = UIStackView()
    private let calcExprLabel = UILabel()
    private let calcResultLabel = UILabel()
    private let menuOverlay = UIView()
    private let menuStack = UIStackView()
    private let imageOverlay = UIView()
    private let imageBig = UIImageView()
    private var clearRowButton: UIButton?
    private var imageCloseButton: UIButton?
    /// v1.6 完整多页设置界面（设置首页 / 键盘设置 / 快捷符号 / 连续复制 /
    /// 局域网同步 / 6 篇教程 / 历史 / 最近删除 / 引导 / 关于）
    private let settings = KeyboardSettings()

    private var heightConstraint: NSLayoutConstraint!
    private var calcExpression = ""
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
        buildHead()
        buildToolbar()
        buildTabs()
        buildList()
        buildCalc()
        buildClearRow()
        buildBottomBar()
        buildMenu()
        buildImageOverlay()
        settings.delegate = self
        settings.install(in: view)

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
        // ★ 每次呼出键盘都读取系统剪贴板，与是否联网、是否开启连续复制无关。
        // iOS 16+ 首次读取会弹「是否允许粘贴」，用户点允许后由 viewDidAppear 补读。
        adoptClipboardText()
        refreshHead()
        refreshTabBar()
        refreshCopyButton()
        refreshSymbols()
        refreshList()
        pull(showConnecting: true)
        startPolling()
        syncCaptureState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 系统粘贴授权弹窗关闭后补读一次；连续复制开启时轮询会持续补读
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            if self.adoptClipboardText() { self.refreshList() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPolling()
        stopCaptureTimer()
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
        // http://IP:8787 形式的内容优先当作电脑地址，不占剪贴板历史
        if prefs.adoptPasteboardURL() { return true }
        return prefs.capture(s)
    }

    // MARK: - 连续复制（HTML 原型 copyBtn + floatwin）

    private func toggleContinuous() {
        prefs.continuous.toggle()
        syncCaptureState()
        showToast(prefs.continuous ? "连续复制已开启" : "已结束连续复制")
    }

    @objc private func openContinuousSettings(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        settings.show(.continuous)
    }

    private func syncCaptureState() {
        if prefs.continuous && !hasFullAccess {
            prefs.continuous = false
            showToast("请先开启「允许完全访问」才能连续复制")
        }
        refreshCopyButton()
        if prefs.continuous {
            if floatingView == nil {
                let f = buildFloatingView()
                view.addSubview(f)
                NSLayoutConstraint.activate([
                    f.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    f.topAnchor.constraint(equalTo: view.topAnchor, constant: 108),
                    f.widthAnchor.constraint(equalToConstant: 212)
                ])
                floatingView = f
            }
            floatingView?.isHidden = false
            startCaptureTimer()
        } else {
            floatingView?.isHidden = true
            stopCaptureTimer()
        }
    }

    private func startCaptureTimer() {
        stopCaptureTimer()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.adoptClipboardText() { self.refreshList() }
        }
    }

    private func stopCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = nil
    }

    /// HTML 原型 floatwin：圆角深色小窗 + 绿点 + 「连续复制中…」+ 结束
    private func buildFloatingView() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor.rgb(32, 33, 38)
        v.layer.cornerRadius = 16
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.22
        v.layer.shadowRadius = 8
        v.layer.shadowOffset = CGSize(width: 0, height: 3)
        v.translatesAutoresizingMaskIntoConstraints = false

        let dot = UIView()
        dot.backgroundColor = QPColor.green
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(dot)

        let label = UILabel()
        label.text = "连续复制中…"
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)

        let stop = UIButton(type: .system)
        stop.setTitle("结束", for: .normal)
        stop.setTitleColor(UIColor.rgb(120, 190, 255), for: .normal)
        stop.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        stop.translatesAutoresizingMaskIntoConstraints = false
        stop.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.prefs.continuous = false
            self.syncCaptureState()
            self.showToast("已结束连续复制")
        }, for: .touchUpInside)
        v.addSubview(stop)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            stop.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            stop.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            stop.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.heightAnchor.constraint(equalToConstant: 34)
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
        client.delete(id: id) { [weak self] error in
            DispatchQueue.main.async {
                if let e = error { self?.showToast("删除失败：" + e) }
                else {
                    self?.showToast("已删除")
                    self?.syncSig = ""
                    self?.pull(showConnecting: false)
                }
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

    private func buildHead() {
        head.backgroundColor = .white
        head.layer.cornerRadius = 18
        head.translatesAutoresizingMaskIntoConstraints = false
        head.heightAnchor.constraint(equalToConstant: 60).isActive = true
        head.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                        action: #selector(headTapped)))
        head.addGestureRecognizer(UILongPressGestureRecognizer(target: self,
                                                              action: #selector(headLongPressed)))

        let dot = UIView()
        dot.tag = 301
        dot.layer.cornerRadius = 6.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        head.addSubview(dot)

        let title = UILabel()
        title.tag = 302
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        head.addSubview(title)

        let desc = UILabel()
        desc.tag = 303
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = QPColor.sub
        desc.numberOfLines = 2
        desc.translatesAutoresizingMaskIntoConstraints = false
        head.addSubview(desc)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 13),
            dot.heightAnchor.constraint(equalToConstant: 13),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: head.topAnchor, constant: 10),
            desc.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            desc.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            desc.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
        ])

        let wrapper = UIView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(head)
        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            head.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
            head.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 6),
            head.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -2),
            wrapper.heightAnchor.constraint(equalToConstant: 68)
        ])
        root.addArrangedSubview(wrapper)
    }

    @objc private func headTapped() {
        pull(showConnecting: true)
    }

    /// 打开 v1.6 完整设置界面（长按状态头可直接进「局域网同步」页）
    @objc private func headLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        settings.show(.sync)
    }

    private func refreshHead() {
        guard let dot = head.viewWithTag(301),
              let title = head.viewWithTag(302) as? UILabel,
              let desc = head.viewWithTag(303) as? UILabel else { return }

        if !hasFullAccess {
            dot.backgroundColor = QPColor.orange
            title.text = "需要「允许完全访问」"
            desc.text = "设置 → 通用 → 键盘 → QuickPaste → 允许完全访问，才能读取剪贴板、联网同步"
            return
        }

        switch syncState {
        case "online":
            dot.backgroundColor = QPColor.green
            title.text = "已连接 · " + (backend == "copyq" ? "CopyQ 历史" : "电脑")
            let when = lastSync.map { QPTime.string($0) } ?? "—"
            desc.text = "共 \(syncCount) 条 · 最近同步 \(when) · \(prefs.syncURL)"
        case "connecting":
            dot.backgroundColor = QPColor.orange
            title.text = "正在连接…"
            desc.text = prefs.syncURL
        case "error":
            dot.backgroundColor = QPColor.red
            title.text = "连接失败"
            desc.text = syncError + " · 点这里重试"
        default:
            dot.backgroundColor = UIColor.rgb(199, 199, 206)
            title.text = "未连接"
            desc.text = "点此连接 · 或长按工具条按键打开设置"
        }
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

        let globe = toolButton("🌐")
        globe.addAction(UIAction { [weak self] _ in self?.advanceToNextInputMode() },
                        for: .touchUpInside)
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
            return
        }

        if prefs.columns == 1 {
            for (i, item) in displayItems.enumerated() {
                listStack.addArrangedSubview(makeSyncCard(item: item, index: i))
            }
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
    }

    /// 本机复制历史在前，电脑同步记录在后；按文字去重，最多 30 条。
    private func mergedItems() -> [SyncItem] {
        var all: [SyncItem] = []
        var seen = Set<String>()
        for text in prefs.items(for: "clip") {
            guard seen.insert("t:" + text).inserted else { continue }
            all.append(SyncItem(id: "local:" + text, text: text, type: "text",
                                image: "", mime: "", source: "local",
                                ts: Date().timeIntervalSince1970 * 1000))
        }
        for it in items {
            let key = it.isImage ? "i:" + it.id : "t:" + it.displayText
            guard seen.insert(key).inserted else { continue }
            all.append(it)
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
        let card = UIButton(type: .custom)
        card.backgroundColor = .white
        card.layer.cornerRadius = 12
        // 原型 .kbCard 带浅阴影；卡片本身不裁切，否则阴影会被切掉
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.06
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        card.layer.shadowRadius = 2
        card.heightAnchor.constraint(equalToConstant: 52).isActive = true
        card.tag = index

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
        badge.text = item.isLocal ? "✂️" : (item.fromPhone ? "📱" : "💻")
        badge.font = .systemFont(ofSize: 11)
        badge.textAlignment = .center
        badge.backgroundColor = item.isLocal
            ? UIColor.rgb(255, 243, 224)
            : (item.fromPhone ? UIColor.rgb(231, 248, 238) : UIColor.rgb(238, 241, 255))
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

        card.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            if item.isImage { self.showImage(item) }
            else {
                self.textDocumentProxy.insertText(item.text)
                if self.prefs.autoCollapse { self.dismissKeyboard() }
            }
        }, for: .touchUpInside)

        let longPress = UILongPressGestureRecognizer(target: self,
                                                     action: #selector(cardLongPress(_:)))
        card.addGestureRecognizer(longPress)
        return card
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

    // MARK: - 清空行 (.kbClear)

    private func buildClearRow() {
        let b = UIButton(type: .system)
        // 原型 .kbClear：蓝色 17px 居中，带垃圾桶图标
        b.setTitle("清空剪贴板  🗑", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        b.setTitleColor(QPColor.blue, for: .normal)
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        b.addAction(UIAction { [weak self] _ in self?.openClearConfirm() },
                    for: .touchUpInside)
        clearRowButton = b
        b.isHidden = !prefs.clearBtn
        root.addArrangedSubview(b)
    }

    // MARK: - 计算器

    private func buildCalc() {
        calcBox.axis = .vertical
        calcBox.spacing = 8
        calcBox.alignment = .fill
        calcBox.isHidden = true
        calcBox.isLayoutMarginsRelativeArrangement = true
        calcBox.layoutMargins = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        // HTML .calcExpr 24px 居中 / .calcRes 32px 蓝色居中
        calcExprLabel.font = .systemFont(ofSize: 20, weight: .medium)
        calcExprLabel.textColor = QPColor.sub
        calcExprLabel.textAlignment = .center
        calcResultLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        calcResultLabel.textColor = QPColor.blue
        calcResultLabel.textAlignment = .center
        let display = UIStackView(arrangedSubviews: [calcExprLabel, calcResultLabel])
        display.axis = .vertical
        display.spacing = 2
        calcBox.addArrangedSubview(display)

        // HTML .calcKeys：gap 8、键高 44、字号 19、圆角 9；「输入」为蓝色主按钮
        let rows: [[String]] = [
            ["7", "8", "9", "÷", "⌫"],
            ["4", "5", "6", "×", "("],
            ["1", "2", "3", "−", ")"],
            ["0", ".", "=", "+", "输入"]
        ]
        for keys in rows {
            let r = UIStackView()
            r.axis = .horizontal
            r.spacing = 8
            r.distribution = .fillEqually
            for key in keys {
                let b = UIButton(type: .system)
                b.setTitle(key, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
                b.setTitleColor(key == "输入" ? .white : UIColor.rgb(17, 17, 17),
                                for: .normal)
                b.layer.cornerRadius = 9
                b.backgroundColor = key == "输入" ? QPColor.blue : QPColor.keyBg
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
        // tabBar 始终隐藏（已按用户要求移除两个 Tab）
        if isCalcMode {
            calcExpression = ""
            updateCalcDisplay()
        }
    }

    private func handleCalcKey(_ key: String) {
        switch key {
        case "输入":
            if let value = try? CalcEngine.evaluate(calcExpression) {
                textDocumentProxy.insertText(value.calcText)
                toggleCalcMode()
            }
        case "⌫":
            if !calcExpression.isEmpty { calcExpression.removeLast() }
            updateCalcDisplay()
        case "=":
            updateCalcDisplay()
        default:
            calcExpression.append(key)
            updateCalcDisplay()
        }
    }

    private func updateCalcDisplay() {
        calcExprLabel.text = calcExpression.isEmpty ? "输入算式，例如 128×3" : calcExpression
        guard !calcExpression.isEmpty else {
            calcResultLabel.text = ""
            return
        }
        if let value = try? CalcEngine.evaluate(calcExpression) {
            calcResultLabel.text = "= " + value.calcText
            calcResultLabel.textColor = QPColor.blue
        } else {
            calcResultLabel.text = "—"
            calcResultLabel.textColor = QPColor.sub
        }
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

    private func openCardMenu(_ item: SyncItem?) {
        menuStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        menuOverlay.isHidden = false
        guard let item = item else { return }
        let preview = item.isImage ? "图片" : String(item.displayText.prefix(24))
        menuStack.addArrangedSubview(menuTitle(preview))

        menuStack.addArrangedSubview(menuRow("插入到输入框") { [weak self] in
            guard let self = self else { return }
            if item.isImage { self.copyImageToPasteboard(item) }
            else { self.textDocumentProxy.insertText(item.text) }
            self.closeMenu()
        })
        if item.isImage {
            menuStack.addArrangedSubview(menuRow("放大查看") { [weak self] in
                self?.closeMenu(); self?.showImage(item)
            })
        }
        menuStack.addArrangedSubview(menuRow("复制到手机剪贴板") { [weak self] in
            guard let self = self else { return }
            if item.isImage { self.copyImageToPasteboard(item) }
            else { UIPasteboard.general.string = item.text; self.showToast("已复制") }
            self.closeMenu()
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
        if item.isLocal {
            menuStack.addArrangedSubview(menuRow("🗑 从本机历史删除") { [weak self] in
                guard let self = self else { return }
                self.prefs.remove(item.text, from: "clip")
                self.refreshList(); self.closeMenu()
            })
        } else {
            menuStack.addArrangedSubview(menuRow("🗑 从电脑删除这条") { [weak self] in
                self?.deleteItem(id: item.id); self?.closeMenu()
            })
        }
        menuStack.addArrangedSubview(menuRow("关闭菜单") { [weak self] in self?.closeMenu() })
    }

    private func openClearConfirm() {
        menuStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        menuOverlay.isHidden = false
        menuStack.addArrangedSubview(menuTitle("清空电脑上的全部同步记录？"))
        menuStack.addArrangedSubview(menuRow("确认清空") { [weak self] in
            self?.deleteItem(id: nil); self?.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("取消") { [weak self] in self?.closeMenu() })
    }

    @objc private func closeMenu() { menuOverlay.isHidden = true }

    @objc private func handleMenuPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        // 两个 Tab 已移除；长按工具条按键统一打开完整设置界面
        settings.show(.root)
    }

    @objc private func cardLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let card = g.view,
              card.tag >= 0, card.tag < displayItems.count else { return }
        openCardMenu(displayItems[card.tag])
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
        clearRowButton?.isHidden = !prefs.clearBtn
        imageCloseButton?.isHidden = !prefs.floatClose
        // refreshSymbols 内部会按 prefs.align 重排工具条符号区
        refreshSymbols()
        refreshTabBar()
        refreshCopyButton()
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

    func settingsClearAll() { deleteItem(id: nil) }

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
