import UIKit
import AVFoundation

// 模式：只保留搜狗式的基础布局（中文9键/中文26键/英文/数字/符号/剪贴板），不再有双拼。
enum KBMode {
    case chinese9, chinese26, english, number, symbol, clipboard
}

// 主 App ↔ 键盘的设置同步通道。
// 不依赖 App Group（手机端重签工具通常不会保留自定义 entitlement），
// 改用系统剪贴板里追加一个自定义 item；键盘开启「完全访问」后读取并移除，
// 不覆盖用户复制的文字。重签后依然可用。
private let kSettingsPBKey = "app.mulberry6323.mozhi.kbcfg"

class KeyboardViewController: UIInputViewController {

    private var mode: KBMode = .chinese9
    private var compose: String = ""            // 中文输入缓冲（26键=字母，9键=数字）
    private var lastCommitted: String = ""      // 最近提交的词，用于语境联想
    private var displayCandidates: [String] = []
    private var shiftOn = false

    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private let keyArea = UIView()
    private let contentHost = UIView()
    private let keyStack = UIStackView()
    private let modeBar = UIStackView()
    private let bufferLabel = UILabel()

    // 反馈（音 / 震），开关由主 App 设置页同步过来
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private var audioEngine: AVAudioEngine?
    private var clickPlayer: AVAudioPlayerNode?
    private var clickBuffer: AVAudioPCMBuffer?

    private let engine = PinyinEngine.shared

    // MARK: - 设置项（键盘读自己的 UserDefaults；主 App 通过剪贴板写入后同步）
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

    /// 读取主 App 放在剪贴板里的配置；读到后写进键盘自己的 UserDefaults 并移除该 item。
    /// 没有「完全访问」时 items 为空，直接跳过（用默认设置，不影响打字）。
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
        UserDefaults.standard.synchronize()
        // 只移除我们自己的配置 item，用户复制的内容原样保留
        pb.items = kept
    }

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        syncSettingsFromApp()
        setupUI()
        updateKeyArea()
        refresh()
        applyKeyboardHeight()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncSettingsFromApp()
        applyKeyboardHeight()
    }

    /// 强制键盘有确定总高，避免某些时机高度塌成 0（整片空白）
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
        // ---- 候选条 ----
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
        // 【关键修复】之前漏了这一句：autoresizing mask 与手动约束冲突，
        // 候选栏尺寸会塌成 0，导致候选词看不见也点不到 —— 英文不经过候选栏所以照样能打。
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.addSubview(candidateStack)

        // 拼音缓冲提示（证明按键已响应）
        bufferLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        bufferLabel.textColor = .systemBlue
        bufferLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.10)
        bufferLabel.layer.cornerRadius = 6
        bufferLabel.clipsToBounds = true
        bufferLabel.setContentHuggingPriority(.required, for: .horizontal)

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

        // ---- 模式栏（无双拼、无设置） ----
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

        // 【关键修复】UIScrollView + UIStackView 的标准约束：
        // 上下左右钉到 contentLayoutGuide，高度钉到 frameLayoutGuide，
        // 这样候选区宽度由内容撑开、可横向滚动，且尺寸绝不为 0。
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
        case .chinese9: return 1
        case .chinese26: return 1
        case .english: return 2
        case .number: return 3
        case .symbol: return 4
        case .clipboard: return 5
        }
    }

    /// 「中」按钮上直接显示当前是 9 键还是 26 键，点一下互切（搜狗式）
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
        if m == .chinese9 {
            target = (mode == .chinese9) ? .chinese26 : .chinese9
        }
        mode = target
        compose = ""
        lastCommitted = ""
        shiftOn = false
        updateModeBarTitles()
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

        // 【兜底 1】只要缓冲非空，候选栏永远至少有一个可点项。
        // 即使词库加载失败 / 引擎返回空，用户也能点它把输入原串上屏 —— 绝不「打不了字」。
        if isComposeMode && !compose.isEmpty && displayCandidates.isEmpty {
            displayCandidates = [compose]
        }

        // 拼音串提示（放最左，证明按键已响应）
        if isComposeMode && !compose.isEmpty {
            bufferLabel.text = "  \(compose)  "
            candidateStack.addArrangedSubview(bufferLabel)
        }

        // 词库没加载到时直接说明，不再一片空白让人猜
        if isComposeMode && !engine.isLoaded {
            let warn = UILabel()
            warn.text = "⚠ 词库未加载，请重装"
            warn.textColor = .systemRed
            warn.font = UIFont.systemFont(ofSize: 13)
            warn.setContentHuggingPriority(.required, for: .horizontal)
            candidateStack.addArrangedSubview(warn)
        }

        for c in displayCandidates.prefix(40) {
            let b = UIButton(type: .system)
            b.setTitle(c, for: .normal)
            b.setTitleColor(.label, for: .normal)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 18)
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.backgroundColor = .tertiarySystemFill
            b.layer.cornerRadius = 8
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
            b.translatesAutoresizingMaskIntoConstraints = false
            // 固定可点尺寸，避免被 stack 压成 0
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            b.addAction(UIAction { [weak self] _ in self?.commit(c) }, for: .touchUpInside)
            candidateStack.addArrangedSubview(b)
        }
        candidateScroll.layoutIfNeeded()
        candidateScroll.contentOffset = .zero
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

    /// 空格 / 确认：有候选上屏首选；没有就把拼音串原样上屏（保证一定出字）
    private func confirm() {
        if let first = displayCandidates.first {
            commit(first)
        } else if isComposeMode && !compose.isEmpty {
            textDocumentProxy.insertText(compose)
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
            // 先执行输入，再给声音/震动反馈：音频初始化万一卡住也不影响打字
            action()
            self?.feedback()
        }, for: .touchUpInside)
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

    // MARK: - 剪贴板（需完全访问；无访问时安全降级）
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

    // MARK: - 反馈（震动 + 按键音），开关来自主 App 设置
    private func feedback() {
        if hapticOn() { impact.impactOccurred() }
        if soundOn() {
            ensureAudio()
            if let p = clickPlayer, let b = clickBuffer {
                p.volume = soundVol()
                p.scheduleBuffer(b, at: nil, options: .interrupts)
                p.play()
            }
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
        let dur = 0.03
        let n = Int(sr * dur)
        guard n > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let data = ch[0]
        for i in 0..<n {
            let t = Double(i) / sr
            let env = exp(-t * 70.0)
            data[i] = Float(sin(2.0 * .pi * 1500.0 * t) * env * 0.5)
        }
        return buf
    }
}
