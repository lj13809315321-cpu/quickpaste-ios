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
        refreshAutoButton()
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
        // 「连续复制」开关：控制呼出时是否自动收录系统剪贴板
        if hasFullAccess && prefs.continuous {
            if prefsAdoptClipboardText() && prefs.savedTip {
                showToast("新内容已保存")
            }
        }
        refreshHead()
        refreshTabBar()
        refreshAutoButton()
        refreshSymbols()
        pull(showConnecting: true)
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPolling()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if heightConstraint.constant != prefs.height {
            heightConstraint.constant = prefs.height
        }
    }

    private func prefsAdoptClipboardText() -> Bool {
        guard hasFullAccess, let s = UIPasteboard.general.string else { return false }
        return prefs.capture(s)
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
            desc.text = "设置 → 通用 → 键盘 → QuickPaste → 允许完全访问，才能联网同步"
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
            desc.text = "点此连接 · 或长按工具条 ⧉ 打开设置"
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

        let collapse = toolButton("⌄")
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

        let autoBtn = toolButton("⧉")
        autoBtn.tag = 101
        autoBtn.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.prefs.syncAuto.toggle()
            if self.prefs.syncAuto { self.startPolling() } else { self.stopPolling() }
            self.refreshAutoButton()
            self.showToast(self.prefs.syncAuto ? "自动同步已开启" : "自动同步已关闭")
        }, for: .touchUpInside)
        let holdAuto = UILongPressGestureRecognizer(target: self,
                                                    action: #selector(handleMenuPress(_:)))
        holdAuto.minimumPressDuration = 1.0
        autoBtn.addGestureRecognizer(holdAuto)
        toolbar.addArrangedSubview(autoBtn)

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
        deleteKey.widthAnchor.constraint(equalToConstant: 66).isActive = true
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

    private func refreshAutoButton() {
        guard let b = toolbar.arrangedSubviews.first(where: { $0.tag == 101 }) as? UIButton else {
            return
        }
        b.backgroundColor = prefs.syncAuto ? QPColor.blue : QPColor.keyBg
        b.setTitleColor(prefs.syncAuto ? .white : .label, for: .normal)
        b.layer.cornerRadius = 9
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

        if prefs.tab == "phrase" {
            let list = prefs.items(for: "phrase")
            if list.isEmpty {
                listStack.addArrangedSubview(emptyLabel("暂无常用语"))
                return
            }
            for (i, text) in list.enumerated() {
                listStack.addArrangedSubview(makePhraseCard(text: text, index: i))
            }
            return
        }

        guard !items.isEmpty else {
            let msg = syncState == "error"
                ? "连接失败\n点上方状态栏重试，或长按 ⧉ 检查地址"
                : "暂无同步记录\n在电脑上复制文字或截图，会自动出现在这里"
            listStack.addArrangedSubview(emptyLabel(msg))
            let b = UIButton(type: .system)
            b.setTitle("连接并刷新", for: .normal)
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
            for (i, item) in items.enumerated() {
                listStack.addArrangedSubview(makeSyncCard(item: item, index: i))
            }
            return
        }
        var row: UIStackView?
        for (i, item) in items.enumerated() {
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
        if items.count % 2 == 1 { row?.addArrangedSubview(UIView()) }
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
        badge.text = item.fromPhone ? "📱" : "💻"
        badge.font = .systemFont(ofSize: 11)
        badge.textAlignment = .center
        badge.backgroundColor = item.fromPhone
            ? UIColor.rgb(231, 248, 238) : UIColor.rgb(238, 241, 255)
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
        calcBox.spacing = 4
        calcBox.isHidden = true
        calcBox.isLayoutMarginsRelativeArrangement = true
        calcBox.layoutMargins = UIEdgeInsets(top: 4, left: 10, bottom: 2, right: 10)

        calcExprLabel.font = .systemFont(ofSize: 12)
        calcExprLabel.textColor = .secondaryLabel
        calcExprLabel.textAlignment = .right
        calcResultLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        calcResultLabel.textColor = QPColor.blue
        calcResultLabel.textAlignment = .right
        let display = UIStackView(arrangedSubviews: [calcExprLabel, calcResultLabel])
        display.axis = .vertical
        calcBox.addArrangedSubview(display)

        let rows: [[String]] = [
            ["7", "8", "9", "÷", "⌫"],
            ["4", "5", "6", "×", "("],
            ["1", "2", "3", "−", ")"],
            ["0", ".", "=", "+", "输入"]
        ]
        for keys in rows {
            let r = UIStackView()
            r.axis = .horizontal
            r.spacing = 4
            r.distribution = .fillEqually
            for key in keys {
                let b = UIButton(type: .system)
                b.setTitle(key, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
                b.layer.cornerRadius = 6
                b.backgroundColor = QPColor.keyBg
                b.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
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
        tabBar.isHidden = isCalcMode
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
            self.refreshAutoButton()
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
        menuStack.addArrangedSubview(menuRow("🗑 从电脑删除这条") { [weak self] in
            self?.deleteItem(id: item.id); self?.closeMenu()
        })
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
        // 长按工具条按键：开启「点击直接切换」时直接切 Tab，否则打开设置界面
        if prefs.directSwitch {
            prefs.tab = prefs.tab == "clip" ? "phrase" : "clip"
            refreshTabBar(); refreshList()
            showToast(prefs.tab == "clip" ? "已切到剪贴板" : "已切到常用语")
        } else {
            settings.show(.root)
        }
    }

    @objc private func cardLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let card = g.view,
              card.tag >= 0, card.tag < items.count else { return }
        openCardMenu(items[card.tag])
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

    /// 原型 .kbTool：38×38、#D4D6DE 灰底、圆角 10
    private func toolButton(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        b.setTitleColor(.black, for: .normal)
        b.backgroundColor = QPColor.keyBg
        b.layer.cornerRadius = 10
        b.widthAnchor.constraint(equalToConstant: 38).isActive = true
        b.heightAnchor.constraint(equalToConstant: 38).isActive = true
        return b
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
        refreshAutoButton()
        refreshList()
        refreshHead()
        if heightConstraint.constant != prefs.height {
            heightConstraint.constant = prefs.height
        }
        view.setNeedsLayout()
        if prefs.syncAuto { startPolling() } else { stopPolling() }
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
        return (title, items.count, prefs.syncURL, backend)
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
