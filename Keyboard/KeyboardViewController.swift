import UIKit

/// 自定义键盘主控制器。
/// 结构对照 quickpaste-ios-prototype.html 的 renderKeyboard()：
///   工具条（收起 / 地球键 / 连续复制 / 快捷符号 / ✕ 键）
///   Tab 条（剪贴板 / 常用语）
///   内容区（列表 1～2 列，或计算器）
///   底行（ƒ(x) 计算 / 空格滑动移光标 / 换行 / 发送）
/// 原型里的「宿主聊天区」属于网页演示，真机由系统提供输入框，故不移植。
final class KeyboardViewController: UIInputViewController {

    private var prefs = KeyboardPrefs()

    // 运行期状态
    private var undoStack: [String] = []
    private var clipboardTimer: Timer?
    private var spaceOriginX: CGFloat = 0
    private var spaceLastSteps = 0
    private var calcExpression = ""
    private var isCalcMode = false

    // 视图
    private let root = UIStackView()
    private let toolbar = UIStackView()
    private let symScroll = UIScrollView()
    private let symStack = UIStackView()
    private let deleteKey = UIButton(type: .system)
    private let tabBar = UIStackView()
    private let listScroll = UIScrollView()
    private let listStack = UIStackView()
    private let calcBox = UIStackView()
    private let calcExprLabel = UILabel()
    private let calcResultLabel = UILabel()
    private let menuOverlay = UIView()
    private let menuStack = UIStackView()
    private var heightConstraint: NSLayoutConstraint!

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        heightConstraint = view.heightAnchor.constraint(equalToConstant: prefs.height)
        heightConstraint.priority = .required
        heightConstraint.isActive = true

        buildRoot()
        buildToolbar()
        buildTabs()
        buildList()
        buildCalc()
        buildBottomBar()
        buildMenu()

        refreshTabBar()
        refreshCopyButton()
        refreshSymbols()
        refreshList()
        if hasFullAccess {
            prefs.capture(UIPasteboard.general.string)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasFullAccess {
            prefs.capture(UIPasteboard.general.string)
            refreshList()
        }
        startClipboardPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopClipboardPolling()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let target = prefs.height
        if heightConstraint.constant != target {
            heightConstraint.constant = target
        }
    }

    // MARK: - 布局

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

    private func buildToolbar() {
        toolbar.axis = .horizontal
        toolbar.spacing = 4
        toolbar.alignment = .center
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.layoutMargins = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        toolbar.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let collapse = toolButton("⌄")
        collapse.addAction(UIAction { [weak self] _ in
            self?.dismissKeyboard()
        }, for: .touchUpInside)
        let holdCollapse = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleMenuPress(_:))
        )
        holdCollapse.minimumPressDuration = 2
        collapse.addGestureRecognizer(holdCollapse)
        toolbar.addArrangedSubview(collapse)

        let globe = toolButton("🌐")
        globe.addAction(UIAction { [weak self] _ in
            self?.advanceToNextInputMode()
        }, for: .touchUpInside)
        toolbar.addArrangedSubview(globe)

        let copy = toolButton("⧉")
        copy.tag = 101
        copy.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.prefs.continuousCopy.toggle()
            self.refreshCopyButton()
            if self.prefs.continuousCopy {
                self.startClipboardPolling()
            } else {
                self.stopClipboardPolling()
            }
        }, for: .touchUpInside)
        toolbar.addArrangedSubview(copy)

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

        deleteKey.setTitle("✕", for: .normal)
        deleteKey.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        deleteKey.backgroundColor = .secondarySystemBackground
        deleteKey.layer.cornerRadius = 8
        deleteKey.widthAnchor.constraint(equalToConstant: 40).isActive = true
        deleteKey.heightAnchor.constraint(equalToConstant: 32).isActive = true
        deleteKey.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.deleteBackward()
        }, for: .touchUpInside)
        toolbar.addArrangedSubview(deleteKey)

        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(clearInput))
        swipeUp.direction = .up
        deleteKey.addGestureRecognizer(swipeUp)

        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(restoreInput))
        swipeDown.direction = .down
        deleteKey.addGestureRecognizer(swipeDown)

        let holdDelete = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleMenuPress(_:))
        )
        holdDelete.minimumPressDuration = 2
        deleteKey.addGestureRecognizer(holdDelete)

        root.addArrangedSubview(toolbar)
    }

    private func buildTabs() {
        tabBar.axis = .horizontal
        tabBar.distribution = .fillEqually
        tabBar.spacing = 6
        tabBar.isLayoutMarginsRelativeArrangement = true
        tabBar.layoutMargins = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        tabBar.heightAnchor.constraint(equalToConstant: 28).isActive = true

        for (index, title) in ["剪贴板", "常用语"].enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            button.layer.cornerRadius = 7
            button.tag = 200 + index
            button.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                self.prefs.tab = (index == 0) ? "clip" : "phrase"
                self.refreshTabBar()
                self.refreshList()
            }, for: .touchUpInside)
            tabBar.addArrangedSubview(button)
        }
        root.addArrangedSubview(tabBar)
    }

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

    private func buildCalc() {
        calcBox.axis = .vertical
        calcBox.spacing = 4
        calcBox.isHidden = true
        calcBox.isLayoutMarginsRelativeArrangement = true
        calcBox.layoutMargins = UIEdgeInsets(top: 4, left: 10, bottom: 2, right: 10)

        calcExprLabel.font = .systemFont(ofSize: 12)
        calcExprLabel.textColor = .secondaryLabel
        calcExprLabel.textAlignment = .right
        calcResultLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        calcResultLabel.textAlignment = .right
        let display = UIStackView(arrangedSubviews: [calcExprLabel, calcResultLabel])
        display.axis = .vertical
        display.spacing = 0
        calcBox.addArrangedSubview(display)

        let rows: [[String]] = [
            ["7", "8", "9", "÷", "⌫"],
            ["4", "5", "6", "×", "("],
            ["1", "2", "3", "−", ")"],
            ["0", ".", "=", "+", "输入"]
        ]
        for keys in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 4
            row.distribution = .fillEqually
            for key in keys {
                let button = UIButton(type: .system)
                button.setTitle(key, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
                button.layer.cornerRadius = 6
                button.backgroundColor = (key == "输入")
                    ? UIColor.systemBlue.withAlphaComponent(0.15)
                    : UIColor.secondarySystemBackground
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
                button.addAction(UIAction { [weak self] _ in
                    self?.handleCalcKey(key)
                }, for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            calcBox.addArrangedSubview(row)
        }
        root.addArrangedSubview(calcBox)
    }

    private func buildBottomBar() {
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.spacing = 6
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 2, left: 10, bottom: 6, right: 10)
        bar.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let calc = UIButton(type: .system)
        calc.setTitle("ƒ(x)", for: .normal)
        calc.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        calc.backgroundColor = .secondarySystemBackground
        calc.layer.cornerRadius = 8
        calc.widthAnchor.constraint(equalToConstant: 60).isActive = true
        calc.addAction(UIAction { [weak self] _ in
            self?.toggleCalcMode()
        }, for: .touchUpInside)
        bar.addArrangedSubview(calc)

        let space = UIButton(type: .system)
        space.setTitle("空格", for: .normal)
        space.titleLabel?.font = .systemFont(ofSize: 13)
        space.backgroundColor = .secondarySystemBackground
        space.layer.cornerRadius = 8
        let spaceHold = UILongPressGestureRecognizer(target: self, action: #selector(handleSpace(_:)))
        spaceHold.minimumPressDuration = 0.12
        spaceHold.allowableMovement = .greatestFiniteMagnitude
        space.addGestureRecognizer(spaceHold)
        bar.addArrangedSubview(space)

        let newline = UIButton(type: .system)
        newline.setTitle("换行", for: .normal)
        newline.titleLabel?.font = .systemFont(ofSize: 14)
        newline.backgroundColor = .secondarySystemBackground
        newline.layer.cornerRadius = 8
        newline.widthAnchor.constraint(equalToConstant: 52).isActive = true
        newline.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText("\n")
        }, for: .touchUpInside)
        bar.addArrangedSubview(newline)

        let send = UIButton(type: .system)
        send.setTitle("发送", for: .normal)
        send.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        send.setTitleColor(.white, for: .normal)
        send.backgroundColor = .systemBlue
        send.layer.cornerRadius = 8
        send.widthAnchor.constraint(equalToConstant: 52).isActive = true
        send.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.textDocumentProxy.insertText("\n")
            if self.prefs.autoCollapse { self.dismissKeyboard() }
        }, for: .touchUpInside)
        bar.addArrangedSubview(send)

        root.addArrangedSubview(bar)
    }

    private func buildMenu() {
        menuOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        menuOverlay.isHidden = true
        menuOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuOverlay)
        NSLayoutConstraint.activate([
            menuOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            menuOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            menuOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            menuOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        menuOverlay.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(closeMenu))
        )

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

    private func toolButton(_ title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    // MARK: - 刷新

    private func refreshTabBar() {
        for sub in tabBar.arrangedSubviews {
            guard let button = sub as? UIButton else { continue }
            let isOn = (button.tag == 200 && prefs.tab == "clip")
                || (button.tag == 201 && prefs.tab == "phrase")
            button.backgroundColor = isOn ? UIColor.systemBlue.withAlphaComponent(0.14) : .clear
            button.setTitleColor(isOn ? .systemBlue : .secondaryLabel, for: .normal)
        }
    }

    private func refreshCopyButton() {
        guard let copy = toolbar.arrangedSubviews.first(where: { $0.tag == 101 }) as? UIButton else {
            return
        }
        copy.backgroundColor = prefs.continuousCopy
            ? UIColor.systemBlue.withAlphaComponent(0.14)
            : .clear
        copy.setTitleColor(prefs.continuousCopy ? .systemBlue : .label, for: .normal)
    }

    private func refreshSymbols() {
        symStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for symbol in prefs.symbols.prefix(prefs.symbolCount) {
            let button = UIButton(type: .system)
            button.setTitle(symbol, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
            button.addAction(UIAction { [weak self] _ in
                self?.textDocumentProxy.insertText(symbol)
            }, for: .touchUpInside)
            symStack.addArrangedSubview(button)
        }
        let more = UIButton(type: .system)
        more.setTitle("⋯", for: .normal)
        more.titleLabel?.font = .systemFont(ofSize: 15)
        more.widthAnchor.constraint(equalToConstant: 28).isActive = true
        more.addAction(UIAction { [weak self] _ in
            self?.openMenu()
        }, for: .touchUpInside)
        symStack.addArrangedSubview(more)
    }

    private func refreshList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let items = prefs.items(for: prefs.tab)
        guard !items.isEmpty else {
            let empty = UILabel()
            empty.text = (prefs.tab == "clip") ? "暂无剪贴板记录" : "暂无常用语"
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .tertiaryLabel
            empty.textAlignment = .center
            empty.heightAnchor.constraint(equalToConstant: 36).isActive = true
            listStack.addArrangedSubview(empty)
            return
        }

        if prefs.columns == 1 {
            for (index, text) in items.enumerated() {
                listStack.addArrangedSubview(makeCard(text: text, index: index))
            }
            return
        }

        var currentRow: UIStackView?
        for (index, text) in items.enumerated() {
            if index % 2 == 0 {
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 6
                row.distribution = .fillEqually
                listStack.addArrangedSubview(row)
                currentRow = row
            }
            currentRow?.addArrangedSubview(makeCard(text: text, index: index))
        }
        if items.count % 2 == 1, let row = currentRow {
            row.addArrangedSubview(UIView())
        }
    }

    private func makeCard(text: String, index: Int) -> UIView {
        let button = UIButton(type: .system)
        button.setTitle(text, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13.5)
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.contentHorizontalAlignment = .leading
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 9
        button.tag = index
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        button.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            let items = self.prefs.items(for: self.prefs.tab)
            guard index >= 0, index < items.count else { return }
            self.textDocumentProxy.insertText(items[index])
        }, for: .touchUpInside)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(cardLongPress(_:)))
        button.addGestureRecognizer(press)
        return button
    }

    // MARK: - 剪贴板

    private func startClipboardPolling() {
        stopClipboardPolling()
        guard prefs.continuousCopy, hasFullAccess else { return }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.prefs.capture(UIPasteboard.general.string) {
                self.refreshList()
            }
        }
    }

    private func stopClipboardPolling() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }

    // MARK: - 交互

    @objc private func handleMenuPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        openMenu()
    }

    @objc private func handleSpace(_ gesture: UILongPressGestureRecognizer) {
        let x = gesture.location(in: view).x
        switch gesture.state {
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
            if spaceLastSteps == 0 {
                textDocumentProxy.insertText(" ")
            }
        default:
            break
        }
    }

    @objc private func clearInput() {
        guard let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty else {
            return
        }
        undoStack.append(before)
        for _ in 0..<(before as NSString).length {
            textDocumentProxy.deleteBackward()
        }
    }

    @objc private func restoreInput() {
        guard let last = undoStack.popLast() else { return }
        textDocumentProxy.insertText(last)
    }

    @objc private func cardLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let card = gesture.view else { return }
        let items = prefs.items(for: prefs.tab)
        guard card.tag >= 0, card.tag < items.count else { return }
        presentCardMenu(for: items[card.tag])
    }

    @objc private func closeMenu() {
        menuOverlay.isHidden = true
    }

    // MARK: - 菜单

    private func openMenu() {
        menuStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        menuOverlay.isHidden = false

        menuStack.addArrangedSubview(menuTitle("键盘设置"))

        menuStack.addArrangedSubview(menuRow("剪贴板", value: prefs.tab == "clip" ? "当前" : nil) { [weak self] in
            guard let self = self else { return }
            self.prefs.tab = "clip"
            self.refreshTabBar()
            self.refreshList()
            self.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("常用语", value: prefs.tab == "phrase" ? "当前" : nil) { [weak self] in
            guard let self = self else { return }
            self.prefs.tab = "phrase"
            self.refreshTabBar()
            self.refreshList()
            self.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("列数", value: "\(prefs.columns) 列") { [weak self] in
            guard let self = self else { return }
            self.prefs.columns = (self.prefs.columns == 1) ? 2 : 1
            self.refreshList()
            self.openMenu()
        })
        menuStack.addArrangedSubview(menuRow("键盘高度", value: "\(Int(prefs.height))") { [weak self] in
            guard let self = self else { return }
            self.prefs.height = self.prefs.height >= 300 ? 220 : self.prefs.height + 20
            self.view.setNeedsLayout()
            self.openMenu()
        })
        menuStack.addArrangedSubview(menuRow("空格滑动移光标", value: prefs.spaceCursor ? "开" : "关") { [weak self] in
            guard let self = self else { return }
            self.prefs.spaceCursor.toggle()
            self.openMenu()
        })
        menuStack.addArrangedSubview(menuRow("发送后收起键盘", value: prefs.autoCollapse ? "开" : "关") { [weak self] in
            guard let self = self else { return }
            self.prefs.autoCollapse.toggle()
            self.openMenu()
        })
        menuStack.addArrangedSubview(menuRow("清空输入框") { [weak self] in
            guard let self = self else { return }
            self.clearInput()
            self.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("切换系统键盘") { [weak self] in
            guard let self = self else { return }
            self.advanceToNextInputMode()
            self.closeMenu()
        })

        if !prefs.symbols.isEmpty {
            menuStack.addArrangedSubview(menuTitle("快捷符号（点按插入）"))
            menuStack.addArrangedSubview(symbolGrid())
        }
    }

    private func presentCardMenu(for text: String) {
        menuStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        menuOverlay.isHidden = false
        let preview = text.count > 24 ? String(text.prefix(24)) + "…" : text
        menuStack.addArrangedSubview(menuTitle(preview))
        menuStack.addArrangedSubview(menuRow("插入到输入框") { [weak self] in
            guard let self = self else { return }
            self.textDocumentProxy.insertText(text)
            self.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("置顶 / 取消置顶") { [weak self] in
            guard let self = self else { return }
            self.prefs.togglePin(text)
            self.refreshList()
            self.closeMenu()
        })
        menuStack.addArrangedSubview(menuRow("删除这条", danger: true) { [weak self] in
            guard let self = self else { return }
            self.prefs.remove(text, from: self.prefs.tab)
            self.refreshList()
            self.closeMenu()
        })
    }

    private func menuTitle(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return label
    }

    private func menuRow(
        _ title: String,
        value: String? = nil,
        danger: Bool = false,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(value == nil ? title : "\(title)　\(value!)", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15)
        button.contentHorizontalAlignment = .leading
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        button.setTitleColor(danger ? .systemRed : .label, for: .normal)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func symbolGrid() -> UIView {
        let grid = UIStackView()
        grid.axis = .horizontal
        grid.spacing = 4
        grid.distribution = .fillEqually
        grid.isLayoutMarginsRelativeArrangement = true
        grid.layoutMargins = UIEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)
        for symbol in prefs.symbols.prefix(5) {
            let button = UIButton(type: .system)
            button.setTitle(symbol, for: .normal)
            button.backgroundColor = .systemBackground
            button.layer.cornerRadius = 6
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.addAction(UIAction { [weak self] _ in
                self?.textDocumentProxy.insertText(symbol)
                self?.closeMenu()
            }, for: .touchUpInside)
            grid.addArrangedSubview(button)
        }
        return grid
    }

    // MARK: - 计算器

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
            if !calcExpression.isEmpty {
                calcExpression.removeLast()
            }
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
            calcResultLabel.textColor = .label
        } else {
            calcResultLabel.text = "—"
            calcResultLabel.textColor = .tertiaryLabel
        }
    }
}
