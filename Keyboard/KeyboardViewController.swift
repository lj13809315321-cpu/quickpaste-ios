import UIKit
import AVFoundation
import AudioToolbox

// 模式：只保留搜狗式的基础布局（中文9键/中文26键/英文/数字/符号/剪贴板），不再有双拼。
enum KBMode {
    case chinese9, chinese26, english, number, symbol, clipboard
}

// 主 App ↔ 键盘的设置同步通道。
// 不依赖 App Group（手机端重签工具通常不会保留自定义 entitlement），
// 改用系统剪贴板里追加一个自定义 item；键盘开启「完全访问」后读取并移除。
private let kSettingsPBKey = "app.mulberry6323.mozhi.kbcfg"

class KeyboardViewController: UIInputViewController {

    private var mode: KBMode = .chinese9
    private var compose: String = ""            // 中文输入缓冲（26键=字母，9键=数字）
    private var lastCommitted: String = ""      // 最近提交的词，用于语境联想
    private var displayCandidates: [String] = []
    private var currentDecode = DecodeResult(display: "", candidates: [], key: "")
    private var didBackspace = false            // 退格改选后给自学习更大权重
    private var shiftOn = false

    private let pinyinBar = UILabel()           // 独立拼音串行（9键也显示拼音，不是数字）
    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private let keyArea = UIView()
    private let contentHost = UIView()
    private let keyStack = UIStackView()
    private let modeBar = UIStackView()

    // 候选按钮复用：每次按键不再重建几十个 UIButton（这是「打字卡顿」的主因之一）
    private var candidateButtons: [UIButton] = []

    // 反馈（音 / 震），开关由主 App 设置页同步过来
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private var audioEngine: AVAudioEngine?
    private var clickPlayer: AVAudioPlayerNode?
    private var clickBuffer: AVAudioPCMBuffer?

    private let engine = PinyinEngine.shared

    // MARK: - 设置项
    private func soundOn() -> Bool {
        if UserDefaults.standard.object(forKey: "kb_sound_on") == nil { return true }
        return UserDefaults.standard.bool(forKey: "kb_sound_on")
    }
    private func hapticOn() -> Bool {
        if UserDefaults.standard.object(forKey: "kb_haptic_on") == nil { return true }
        return UserDefaults.standard.bool(forKey: "kb_haptic_on")
    }
    private func soundVol() -> Float {
        if UserDefaults.standard.object(forKey: "kb_sound_vol") == nil { return 0.6 }
        return Float(UserDefaults.standard.double(forKey: "kb_sound_vol"))
    }

    private func syncSettingsFromApp() {
        let pb = UIPasteboard.general
        let items = pb.items
        guard !items.isEmpty else { return }
        var found: String?
        var kept: [[String: Any]] = []
        for item in items {
            if let s = item[kSettingsPBKey] as? String { found = s; continue }
            if let d = item[kSettingsPBKey] as? Data,
               let s = String(data: d, encoding: .utf8) { found = s; continue }
            kept.append(item)
        }
        guard let json = found,
              let data = json.data(using: .utf8),
              let cfg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let v = cfg["sound"] as? Bool { UserDefaults.standard.set(v, forKey: "kb_sound_on") }
        if let v = cfg["haptic"] as? Bool { UserDefaults.standard.set(v, forKey: "kb_haptic_on") }
        if let v = cfg["vol"] as? Double { UserDefaults.standard.set(v, forKey: "kb_sound_vol") }
        if let ph = cfg["phrases"] as? [String: String] {
            UserDefaults.standard.set(ph, forKey: "kb_custom_phrases")
            engine.setCustomPhrases(ph)
        }
        UserDefaults.standard.synchronize()
        pb.items = kept
    }

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // 先读本地缓存，再用主 App 刚放进剪贴板的新配置覆盖
        if let ph = UserDefaults.standard.dictionary(forKey: "kb_custom_phrases") as? [String: String] {
            engine.setCustomPhrases(ph)
        }
        syncSettingsFromApp()
        setupUI()
        updateKeyArea()
        refresh()
        applyKeyboardHeight()
        impact.prepare()
        // 音频预热：不让第一次按键去等 AVAudioEngine 启动
        DispatchQueue.main.async { [weak self] in self?.ensureAudio() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncSettingsFromApp()
        applyKeyboardHeight()
        impact.prepare()
    }

    private func applyKeyboardHeight() {
        guard view.constraints.first(where: { $0.identifier == "kbHeight" }) == nil else { return }
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let kbH: CGFloat = (w > h) ? 220 : 300
        let c = view.heightAnchor.constraint(equalToConstant: kbH)
        c.identifier = "kbHeight"
        c.priority = .required
        c.isActive = true
    }

    // MARK: - 界面骨架
    private func setupUI() {
        // ---- 独立拼音串行 ----
        pinyinBar.translatesAutoresizingMaskIntoConstraints = false
        pinyinBar.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        pinyinBar.textColor = .systemBlue
        pinyinBar.backgroundColor = .secondarySystemBackground
        pinyinBar.textAlignment = .left
        pinyinBar.adjustsFontSizeToFitWidth = true
        pinyinBar.minimumScaleFactor = 0.72
        pinyinBar.lineBreakMode = .byTruncatingHead
        view.addSubview(pinyinBar)

        // ---- 候选条（只放汉字候选，拼音串不再挤进来） ----
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.alwaysBounceHorizontal = true
        candidateScroll.backgroundColor = .secondarySystemBackground
        view.addSubview(candidateScroll)

        candidateStack.axis = .horizontal
        candidateStack.spacing = 8
        candidateStack.alignment = .center
        candidateStack.distribution = .fill
        candidateStack.layoutMargins = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        candidateStack.isLayoutMarginsRelativeArrangement = true
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.addSubview(candidateStack)

        // ---- 按键区 ----
        keyStack.axis = .vertical
        keyStack.spacing = 6
        keyStack.distribution = .fillEqually
        keyStack.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(keyStack)
        NSLayoutConstraint.activate([
            keyStack.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 4),
            keyStack.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 6),
            keyStack.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -6),
            keyStack.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -4),
        ])
        keyArea.addSubview(contentHost)
        keyArea.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyArea)

        // ---- 模式栏 ----
        modeBar.axis = .horizontal
        modeBar.spacing = 4
        modeBar.distribution = .fillEqually
        modeBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeBar)
        buildModeBar()

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            pinyinBar.topAnchor.constraint(equalTo: guide.topAnchor),
            pinyinBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 10),
            pinyinBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -10),
            pinyinBar.heightAnchor.constraint(equalToConstant: 24),

            candidateScroll.topAnchor.constraint(equalTo: pinyinBar.bottomAnchor),
            candidateScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            candidateScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            candidateScroll.heightAnchor.constraint(equalToConstant: 46),

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
            modeBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            modeBar.heightAnchor.constraint(equalToConstant: 40),
        ])

        NSLayoutConstraint.activate([
            candidateStack.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor),
            candidateStack.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateScroll.frameLayoutGuide.heightAnchor),
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
            b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
            b.tag = modeBarTag(m)
            b.addAction(UIAction { [weak self] _ in self?.switchMode(m) }, for: .touchUpInside)
            modeBar.addArrangedSubview(b)
        }
        updateModeBarTitles()
    }

    private func modeBarTag(_ m: KBMode) -> Int {
        switch m {
        case .chinese9, .chinese26: return 1
        case .english: return 2
        case .number: return 3
        case .symbol: return 4
        case .clipboard: return 5
        }
    }

    private func updateModeBarTitles() {
        for v in modeBar.arrangedSubviews {
            guard let b = v as? UIButton else { continue }
            if b.tag == 1 {
                b.setTitle((mode == .chinese26) ? "中26" : "中9", for: .normal)
                b.backgroundColor = (mode == .chinese9 || mode == .chinese26) ? .systemGray4 : .systemFill
            } else {
                let active: Bool
                switch mode {
                case .english: active = b.tag == 2
                case .number: active = b.tag == 3
                case .symbol: active = b.tag == 4
                case .clipboard: active = b.tag == 5
                default: active = false
                }
                b.backgroundColor = active ? .systemGray4 : .systemFill
            }
        }
    }

    // MARK: - 模式切换
    private func switchMode(_ m: KBMode) {
        var target = m
        if m == .chinese9 { target = (mode == .chinese9) ? .chinese26 : .chinese9 }
        mode = target
        compose = ""
        lastCommitted = ""
        didBackspace = false
        shiftOn = false
        updateModeBarTitles()
        updateKeyArea()
        refresh()
    }

    private var isComposeMode: Bool { mode == .chinese9 || mode == .chinese26 }

    // MARK: - 候选刷新（按钮复用，不重建）
    private func refresh() {
        if isComposeMode, !compose.isEmpty {
            let r = engine.decode(compose, is9Key: mode == .chinese9, context: lastCommitted)
            currentDecode = r
            displayCandidates = r.candidates
            pinyinBar.text = r.display.isEmpty ? compose : r.display
            if !engine.isLoaded { pinyinBar.text = "⚠ 词库未加载 · " + (pinyinBar.text ?? "") }
        } else {
            currentDecode = DecodeResult(display: "", candidates: [], key: "")
            displayCandidates = isComposeMode ? engine.associations(for: lastCommitted) : []
            pinyinBar.text = isComposeMode && !engine.isLoaded ? "⚠ 词库未加载，请重装" : ""
        }
        updateCandidateButtons()
    }

    private func makeCandidateButton() -> UIButton {
        let b = UIButton(type: .system)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .tertiarySystemFill
        b.layer.cornerRadius = 8
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.8
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        b.addAction(UIAction { [weak self] a in
            guard let self = self, let btn = a.sender as? UIButton else { return }
            let idx = btn.tag
            if idx < self.displayCandidates.count { self.commit(self.displayCandidates[idx]) }
        }, for: .touchUpInside)
        return b
    }

    private func updateCandidateButtons() {
        let items = Array(displayCandidates.prefix(20))
        for i in 0..<items.count {
            let b: UIButton
            if i < candidateButtons.count {
                b = candidateButtons[i]
            } else {
                b = makeCandidateButton()
                candidateButtons.append(b)
                candidateStack.addArrangedSubview(b)
            }
            b.isHidden = false
            b.tag = i
            b.setTitle(items[i], for: .normal)
            let len = items[i].count
            b.titleLabel?.font = UIFont.systemFont(ofSize: len > 8 ? 14 : (len > 4 ? 16 : 18))
        }
        for i in items.count..<candidateButtons.count { candidateButtons[i].isHidden = true }
        candidateScroll.contentOffset = .zero
        candidateScroll.setNeedsLayout()
    }

    private func commit(_ text: String) {
        textDocumentProxy.insertText(text)
        if isComposeMode {
            engine.learn(text, pinyinKey: currentDecode.key, boost: didBackspace ? 3 : 1)
            lastCommitted = text
            compose = ""
            didBackspace = false
        }
        refresh()
    }

    private func backspace() {
        if isComposeMode && !compose.isEmpty {
            compose.removeLast()
            didBackspace = true
            refresh()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    /// 中文标点键：先把当前首选上屏，再插标点（搜狗式连贯，不打断长句输入）
    private func punctuationCommit(_ p: String) {
        if isComposeMode, !compose.isEmpty, let first = displayCandidates.first {
            commit(first)
        }
        textDocumentProxy.insertText(p)
        lastCommitted = p
        refresh()
    }

    private func confirm() {
        if let first = displayCandidates.first {
            commit(first)
        } else if isComposeMode && !compose.isEmpty {
            textDocumentProxy.insertText(currentDecode.display.isEmpty ? compose : currentDecode.display)
            lastCommitted = compose
            compose = ""
            refresh()
        } else {
            textDocumentProxy.insertText(" ")
        }
    }

    // MARK: - 键盘区域
    private func updateKeyArea() {
        contentHost.subviews.forEach { if $0 !== keyStack { $0.removeFromSuperview() } }
        keyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
        for r in rows { keyStack.addArrangedSubview(r) }
    }

    // MARK: - 通用构件
    /// 关键手感改动：输入在 touchDown 触发（系统键盘就是按下即响应），
    /// 不再等 touchUpInside；并带回弹动画。快速连打不丢键、不拖沓。
    private func key(_ title: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .secondarySystemBackground
        b.layer.cornerRadius = 6
        b.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        b.titleLabel?.numberOfLines = 0
        b.titleLabel?.textAlignment = .center
        b.contentVerticalAlignment = .center
        b.contentHorizontalAlignment = .center
        b.heightAnchor.constraint(equalToConstant: 48).isActive = true

        b.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            action()
            self.feedback()
        }, for: .touchDown)
        b.addAction(UIAction { a in
            guard let btn = a.sender as? UIButton else { return }
            UIView.animate(withDuration: 0.05) {
                btn.transform = CGAffineTransform(scaleX: 0.93, y: 0.93)
                btn.alpha = 0.72
            }
        }, for: .touchDown)
        b.addAction(UIAction { a in
            guard let btn = a.sender as? UIButton else { return }
            UIView.animate(withDuration: 0.16, delay: 0,
                           usingSpringWithDamping: 0.45, initialSpringVelocity: 0.9,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                btn.transform = .identity
                btn.alpha = 1
            }
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
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
            if n == "1" {
                // 9 键的 1 不再往拼音缓冲里塞无效数字，改成中文标点键
                return key("1\n，") { [weak self] in self?.punctuationCommit("，") }
            }
            let t = l.isEmpty ? n : "\(n)\n\(l)"
            return key(t) { [weak self] in
                guard let self = self else { return }
                self.compose += n
                self.refresh()
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
        let r4: UIStackView
        if insertDirectly {
            r4 = row([
                key("空格") { [weak self] in self?.textDocumentProxy.insertText(" ") },
                key("⏎") { [weak self] in self?.textDocumentProxy.insertText("\n") },
            ])
        } else {
            r4 = row([
                key("，") { [weak self] in self?.punctuationCommit("，") },
                key("空格/确认") { [weak self] in self?.confirm() },
                key("。") { [weak self] in self?.punctuationCommit("。") },
                key("⏎") { [weak self] in self?.textDocumentProxy.insertText("\n") },
            ])
        }
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
        if let cur = safePasteboardString(), !cur.isEmpty { items.append(cur) }
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
            b.setTitleColor(.label, for: .normal)
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

    private func safePasteboardString() -> String? {
        let pb = UIPasteboard.general
        guard pb.hasStrings else { return nil }
        return pb.string
    }

    // MARK: - 反馈（震动 + 按键音）
    private func feedback() {
        if hapticOn() {
            impact.impactOccurred()
            impact.prepare()          // 为下一次按键预准备，连打零延迟
        }
        guard soundOn() else { return }
        if let p = clickPlayer, let b = clickBuffer, audioEngine?.isRunning == true {
            p.volume = soundVol()
            p.scheduleBuffer(b, at: nil, options: .interrupts)
            if !p.isPlaying { p.play() }
        } else {
            // 音频引擎还没热好就用系统按键音兜底，绝不阻塞输入
            AudioServicesPlaySystemSound(1104)
        }
    }

    private func ensureAudio() {
        guard audioEngine == nil else { return }
        let av = AVAudioEngine()
        let player = AVAudioPlayerNode()
        av.attach(player)
        let fmt = av.outputNode.inputFormat(forBus: 0)
        av.connect(player, to: av.mainMixerNode, format: fmt)
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch { }
        av.prepare()
        do { try av.start() } catch { }
        audioEngine = av
        clickPlayer = player
        clickBuffer = makeClickBuffer(format: fmt)
    }

    private func makeClickBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let dur = 0.024
        let n = Int(sr * dur)
        guard n > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let data = ch[0]
        for i in 0..<n {
            let t = Double(i) / sr
            let env = exp(-t * 95.0)
            // 短促清脆的「嗒」：基频 + 一点高频泛音，接近系统按键音
            data[i] = Float((sin(2.0 * .pi * 1250.0 * t) * 0.75 +
                             sin(2.0 * .pi * 2500.0 * t) * 0.25) * env * 0.5)
        }
        return buf
    }
}
