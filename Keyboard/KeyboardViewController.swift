import UIKit

enum KBMode {
    case chinese9, chinese26, english, number, symbol, clipboard
}

class KeyboardViewController: UIInputViewController {

    private var mode: KBMode = .chinese9
    private var compose: String = ""            // 中文输入缓冲（26键=字母，9键=数字）
    private var lastCommitted: String = ""      // 最近提交的词，用于语境联想
    private var displayCandidates: [String] = []// 当前候选条（拼音候选 or 联想）
    private var shiftOn = false

    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private let keyArea = UIView()
    private let contentHost = UIView()
    private let keyStack = UIStackView()
    private let modeBar = UIStackView()

    private var engine = PinyinEngine.shared

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        setupUI()
        updateKeyArea()
        refresh()
    }

    private func setupUI() {
        candidateStack.axis = .horizontal
        candidateStack.spacing = 8
        candidateStack.alignment = .center
        candidateStack.layoutMargins = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        candidateStack.isLayoutMarginsRelativeArrangement = true
        candidateScroll.addSubview(candidateStack)
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.showsHorizontalScrollIndicator = false
        view.addSubview(candidateScroll)

        keyStack.axis = .vertical
        keyStack.spacing = 6
        keyStack.translatesAutoresizingMaskIntoConstraints = false

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        keyArea.addSubview(contentHost)
        keyArea.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyArea)

        modeBar.axis = .horizontal
        modeBar.spacing = 4
        modeBar.distribution = .fillEqually
        modeBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeBar)
        buildModeBar()

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            candidateScroll.topAnchor.constraint(equalTo: guide.topAnchor),
            candidateScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            candidateScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            candidateScroll.heightAnchor.constraint(equalToConstant: 44),

            keyArea.topAnchor.constraint(equalTo: candidateScroll.bottomAnchor),
            keyArea.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            keyArea.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            keyArea.bottomAnchor.constraint(equalTo: modeBar.topAnchor),

            contentHost.topAnchor.constraint(equalTo: keyArea.topAnchor),
            contentHost.leadingAnchor.constraint(equalTo: keyArea.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: keyArea.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: keyArea.bottomAnchor),

            modeBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            modeBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            modeBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            modeBar.heightAnchor.constraint(equalToConstant: 38),
        ])
        NSLayoutConstraint.activate([
            candidateStack.topAnchor.constraint(equalTo: candidateScroll.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScroll.bottomAnchor),
            candidateStack.leadingAnchor.constraint(equalTo: candidateScroll.leadingAnchor),
            candidateStack.trailingAnchor.constraint(greaterThanOrEqualTo: candidateScroll.trailingAnchor),
        ])
    }

    private func buildModeBar() {
        let items: [(String, KBMode)] = [
            ("中", .chinese9), ("EN", .english), ("123", .number),
            ("#", .symbol), ("剪贴板", .clipboard),
        ]
        for (title, m) in items {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.setTitleColor(.label, for: .normal)
            b.backgroundColor = .systemFill
            b.layer.cornerRadius = 6
            b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
            b.addAction(UIAction { [weak self] _ in self?.switchMode(m) }, for: .touchUpInside)
            modeBar.addArrangedSubview(b)
        }
    }

    // MARK: - 模式切换
    private func switchMode(_ m: KBMode) {
        var target = m
        if m == .chinese9 && (mode == .chinese9 || mode == .chinese26) {
            target = (mode == .chinese9) ? .chinese26 : .chinese9
        }
        mode = target
        compose = ""
        lastCommitted = ""
        shiftOn = false
        updateKeyArea()
        refresh()
    }

    private var isComposeMode: Bool { mode == .chinese9 || mode == .chinese26 }

    // MARK: - 候选刷新
    private func refresh() {
        displayCandidates = []
        candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if isComposeMode {
            if !compose.isEmpty {
                displayCandidates = engine.candidates(for: compose, is9Key: mode == .chinese9)
            } else if !lastCommitted.isEmpty {
                displayCandidates = engine.associations(for: lastCommitted)
            }
        }
        for c in displayCandidates {
            let b = UIButton(type: .system)
            b.setTitle(c, for: .normal)
            b.setTitleColor(.darkText, for: .normal)
            b.contentHorizontalAlignment = .left
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 17)
            b.backgroundColor = .secondarySystemBackground
            b.layer.cornerRadius = 8
            b.addAction(UIAction { [weak self] _ in self?.commit(c) }, for: .touchUpInside)
            candidateStack.addArrangedSubview(b)
        }
        candidateScroll.layoutIfNeeded()
    }

    private func commit(_ text: String) {
        textDocumentProxy.insertText(text)
        if isComposeMode {
            engine.learn(text)
            lastCommitted = text
            compose = ""
        }
        refresh()
    }

    private func backspace() {
        if isComposeMode && !compose.isEmpty {
            compose.removeLast()
            refresh()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    private func confirm() {
        if let first = displayCandidates.first {
            commit(first)
        } else {
            textDocumentProxy.insertText(" ")
        }
    }

    // MARK: - 键盘区域（按模式重建）
    private func updateKeyArea() {
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let rows: [UIStackView]
        switch mode {
        case .chinese9:  rows = nineKeys()
        case .chinese26: rows = qwerty(insertDirectly: false)
        case .english:   rows = qwerty(insertDirectly: true)
        case .number:    rows = numberKeys()
        case .symbol:    rows = symbolKeys()
        case .clipboard:
            let scroll = clipboardScroll()
            contentHost.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: contentHost.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
            return
        }
        contentHost.addSubview(keyStack)
        NSLayoutConstraint.activate([
            keyStack.topAnchor.constraint(equalTo: contentHost.topAnchor),
            keyStack.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 6),
            keyStack.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -6),
        ])
        for r in rows { keyStack.addArrangedSubview(r) }
    }

    // MARK: - 通用构件
    private func key(_ title: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .secondarySystemBackground
        b.layer.cornerRadius = 6
        b.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        b.titleLabel?.numberOfLines = 0
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func row(_ buttons: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: buttons)
        s.axis = .horizontal; s.spacing = 6; s.distribution = .fillEqually
        return s
    }

    // MARK: - 9键（T9拼音）
    private func nineKeys() -> [UIStackView] {
        let map: [(String, String)] = [
            ("1", ""), ("2", "abc"), ("3", "def"),
            ("4", "ghi"), ("5", "jkl"), ("6", "mno"),
            ("7", "pqrs"), ("8", "tuv"), ("9", "wxyz"),
        ]
        func k(_ i: Int) -> UIButton {
            let (n, l) = map[i]
            let t = l.isEmpty ? n : "\(n)\n\(l)"
            return key(t) { [weak self] in
                guard let self = self else { return }
                if !n.isEmpty { self.compose += n; self.refresh() }
            }
        }
        let r1 = row([k(0), k(1), k(2)])
        let r2 = row([k(3), k(4), k(5)])
        let r3 = row([k(6), k(7), k(8)])
        let r4 = row([
            key("⌫") { [weak self] in self?.backspace() },
            key("0 空格") { [weak self] in
                if self?.isComposeMode == true { self?.confirm() } else { self?.textDocumentProxy.insertText(" ") }
            },
            key("⏎") { [weak self] in self?.textDocumentProxy.insertText("\n") },
        ])
        return [r1, r2, r3, r4]
    }

    // MARK: - QWERTY（中文26 / 英文26）
    private func qwerty(insertDirectly: Bool) -> [UIStackView] {
        let lines = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        var rows: [UIStackView] = []
        for (idx, line) in lines.enumerated() {
            var btns: [UIButton] = []
            for ch in line {
                let s = String(ch)
                let label = (insertDirectly && shiftOn) ? s.uppercased() : s
                btns.append(key(label) { [weak self] in
                    guard let self = self else { return }
                    if insertDirectly {
                        self.textDocumentProxy.insertText((self.shiftOn ? s.uppercased() : s))
                    } else {
                        self.compose += s; self.refresh()
                    }
                })
            }
            if idx == 2 {
                btns.insert(key("⇧") { [weak self] in
                    self?.shiftOn.toggle(); self?.updateKeyArea()
                }, at: 0)
                btns.append(key("⌫") { [weak self] in self?.backspace() })
            }
            rows.append(row(btns))
        }
        let r4 = row([
            key("空格/确认") { [weak self] in
                if self?.isComposeMode == true { self?.confirm() } else { self?.textDocumentProxy.insertText(" ") }
            },
            key("⏎") { [weak self] in self?.textDocumentProxy.insertText("\n") },
        ])
        rows.append(r4)
        return rows
    }

    // MARK: - 数字
    private func numberKeys() -> [UIStackView] {
        let r1 = row((1...3).map { n in key("\(n)") { [weak self] in self?.textDocumentProxy.insertText("\(n)") } })
        let r2 = row((4...6).map { n in key("\(n)") { [weak self] in self?.textDocumentProxy.insertText("\(n)") } })
        let r3 = row((7...9).map { n in key("\(n)") { [weak self] in self?.textDocumentProxy.insertText("\(n)") } })
        let r4 = row([
            key("⌫") { [weak self] in self?.textDocumentProxy.deleteBackward() },
            key("0") { [weak self] in self?.textDocumentProxy.insertText("0") },
            key(".") { [weak self] in self?.textDocumentProxy.insertText(".") },
            key("⏎") { [weak self] in self?.textDocumentProxy.insertText("\n") },
        ])
        return [r1, r2, r3, r4]
    }

    // MARK: - 符号
    private func symbolKeys() -> [UIStackView] {
        let sets = [
            ["@", "#", "&", "*", "(", ")", "_", "-", "+"],
            [",", ".", "?", "!", "\"", "'", ":", ";"],
            ["/", "\\", "|", "~", "`", "%", "^", "="],
        ]
        var rows: [UIStackView] = []
        for set in sets {
            rows.append(row(set.map { ch in key(ch) { [weak self] in self?.textDocumentProxy.insertText(ch) } }))
        }
        rows.append(row([
            key("⌫") { [weak self] in self?.textDocumentProxy.deleteBackward() },
            key("空格") { [weak self] in self?.textDocumentProxy.insertText(" ") },
            key("⏎") { [weak self] in self?.textDocumentProxy.insertText("\n") },
        ]))
        return rows
    }

    // MARK: - 剪贴板
    private func clipboardScroll() -> UIScrollView {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = true
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.isLayoutMarginsRelativeArrangement = true
        scroll.addSubview(stack)

        var items: [String] = []
        if let cur = UIPasteboard.general.string, !cur.isEmpty { items.append(cur) }
        if let hist = UserDefaults.standard.stringArray(forKey: "kb_clip") { items.append(contentsOf: hist) }

        if items.isEmpty {
            let label = UILabel()
            label.text = "剪贴板为空。\n（iOS 需在「设置 › 键盘 › 你的键盘 › 完全访问」中开启后，才能读取系统剪贴板。）"
            label.numberOfLines = 0
            label.font = UIFont.systemFont(ofSize: 14)
            label.textColor = .secondaryLabel
            stack.addArrangedSubview(label)
        }
        for it in items.prefix(40) {
            let preview = it.replacingOccurrences(of: "\n", with: " ")
            let b = UIButton(type: .system)
            b.setTitle(preview, for: .normal)
            b.setTitleColor(.darkText, for: .normal)
            b.contentHorizontalAlignment = .left
            b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 15)
            b.backgroundColor = .secondarySystemBackground
            b.layer.cornerRadius = 8
            b.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                self.textDocumentProxy.insertText(it)
                var h = UserDefaults.standard.stringArray(forKey: "kb_clip") ?? []
                h.removeAll { $0 == it }
                h.insert(it, at: 0)
                UserDefaults.standard.set(Array(h.prefix(50)), forKey: "kb_clip")
            }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return scroll
    }
}
