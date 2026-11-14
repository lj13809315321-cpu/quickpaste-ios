import UIKit
import AVFoundation

enum KBMode {
    case chinese9, chinese26, shuangpin, english, number, symbol, clipboard
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
    private let bufferLabel = UILabel()

    // 设置页
    private let settingsOverlay = UIView()
    private var soundSwitch = UISwitch()
    private var hapticSwitch = UISwitch()
    private var volumeSlider = UISlider()

    // 反馈（音/震）
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private var audioEngine: AVAudioEngine?
    private var clickPlayer: AVAudioPlayerNode?
    private var clickBuffer: AVAudioPCMBuffer?

    private var engine = PinyinEngine.shared

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

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        buildSettingsOverlay()
        updateKeyArea()
        refresh()
        applyKeyboardHeight()
    }

    /// 强制键盘有一个确定的总高度，避免某些时机高度塌成 0（整片空白）
    private func applyKeyboardHeight() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let isLandscape = w > h
        let kbH: CGFloat = isLandscape ? 220 : 300
        let c = view.heightAnchor.constraint(equalToConstant: kbH)
        c.priority = .required
        c.isActive = true
    }

    private func setupUI() {
        // 候选条
        candidateStack.axis = .horizontal
        candidateStack.spacing = 8
        candidateStack.alignment = .center
        candidateStack.layoutMargins = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        candidateStack.isLayoutMarginsRelativeArrangement = true
        candidateScroll.addSubview(candidateStack)
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.backgroundColor = .secondarySystemBackground
        view.addSubview(candidateScroll)

        // 缓冲提示（证明按键已响应）
        bufferLabel.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        bufferLabel.textColor = .systemBlue
        bufferLabel.setContentHuggingPriority(.required, for: .horizontal)
        bufferLabel.isHidden = true

        // 键盘区域（自适应填充，不溢出）
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

        // 模式栏
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
            modeBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            modeBar.heightAnchor.constraint(equalToConstant: 40),
        ])
        NSLayoutConstraint.activate([
            candidateStack.topAnchor.constraint(equalTo: candidateScroll.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScroll.bottomAnchor),
            candidateStack.leadingAnchor.constraint(equalTo: candidateScroll.leadingAnchor),
            candidateStack.trailingAnchor.constraint(greaterThanOrEqualTo: candidateScroll.trailingAnchor),
        ])
    }

    private func buildModeBar() {
        let items: [(String, KBMode?)] = [
            ("中", .chinese9), ("双拼", .shuangpin), ("EN", .english), ("123", .number),
            ("#", .symbol), ("剪贴板", .clipboard), ("⚙", nil),
        ]
        for (title, m) in items {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.setTitleColor(.label, for: .normal)
            b.backgroundColor = .systemFill
            b.layer.cornerRadius = 6
            b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
            if let m = m {
                b.addAction(UIAction { [weak self] _ in self?.switchMode(m) }, for: .touchUpInside)
            } else {
                b.addAction(UIAction { [weak self] _ in self?.toggleSettings() }, for: .touchUpInside)
            }
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

    private var isComposeMode: Bool { mode == .chinese9 || mode == .chinese26 || mode == .shuangpin }

    private func spScheme() -> String {
        return UserDefaults.standard.string(forKey: "kb_sp_scheme") ?? "小鹤"
    }

    // MARK: - 候选刷新
    private func refresh() {
        displayCandidates = []
        candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if isComposeMode {
            if !compose.isEmpty {
                if mode == .shuangpin {
                    displayCandidates = engine.candidatesForShuangpin(compose, scheme: spScheme())
                } else {
                    displayCandidates = engine.candidates(for: compose, is9Key: mode == .chinese9)
                }
            } else if !lastCommitted.isEmpty {
                displayCandidates = engine.associations(for: lastCommitted)
            }
        }
        for c in displayCandidates {
            let b = UIButton(type: .system)
            b.setTitle(c, for: .normal)
            b.setTitleColor(.label, for: .normal)
            b.contentHorizontalAlignment = .left
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 17)
            b.backgroundColor = .secondarySystemBackground
            b.layer.cornerRadius = 8
            b.addAction(UIAction { [weak self] _ in self?.commit(c) }, for: .touchUpInside)
            candidateStack.addArrangedSubview(b)
        }
        if isComposeMode && !compose.isEmpty {
            bufferLabel.isHidden = false
            bufferLabel.text = "  ⟨\(compose)⟩  "
        } else {
            bufferLabel.isHidden = true
        }
        if !bufferLabel.isHidden { candidateStack.insertArrangedSubview(bufferLabel, at: 0) }
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
        case .shuangpin: rows = qwerty(insertDirectly: false)
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
        b.heightAnchor.constraint(equalToConstant: 48).isActive = true   // 保底高度，防止键盘塌成空白
        b.addAction(UIAction { [weak self] _ in
            self?.feedback()
            action()
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

    // MARK: - 反馈（震动 + 按键音）
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
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let fmt = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch { }
        engine.prepare()
        do { try engine.start() } catch { }
        audioEngine = engine
        clickPlayer = player
        clickBuffer = makeClickBuffer(format: fmt)
    }

    private func makeClickBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let dur = 0.03
        let n = Int(sr * dur)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        guard let ch = buf.floatChannelData else { return nil }
        let data = ch[0]
        for i in 0..<n {
            let t = Double(i) / sr
            let env = exp(-t * 70.0)
            data[i] = Float(sin(2.0 * .pi * 1500.0 * t) * env * 0.5)
        }
        return buf
    }

    // MARK: - 设置页
    private func buildSettingsOverlay() {
        settingsOverlay.translatesAutoresizingMaskIntoConstraints = false
        settingsOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        settingsOverlay.isHidden = true
        view.addSubview(settingsOverlay)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 14
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.25
        card.layer.shadowRadius = 10
        settingsOverlay.addSubview(card)

        let title = UILabel()
        title.text = "键盘设置"
        title.font = UIFont.boldSystemFont(ofSize: 18)
        title.textColor = .label

        let l1 = UILabel(); l1.text = "按键音"; l1.textColor = .label; l1.font = .systemFont(ofSize: 16)
        let l2 = UILabel(); l2.text = "音量"; l2.textColor = .label; l2.font = .systemFont(ofSize: 16)
        let l3 = UILabel(); l3.text = "震动反馈"; l3.textColor = .label; l3.font = .systemFont(ofSize: 16)
        let l4 = UILabel(); l4.text = "双拼方案"; l4.textColor = .label; l4.font = .systemFont(ofSize: 16)

        soundSwitch.isOn = soundOn()
        hapticSwitch.isOn = hapticOn()
        volumeSlider.value = soundVol()
        volumeSlider.minimumValue = 0; volumeSlider.maximumValue = 1
        soundSwitch.addTarget(self, action: #selector(onSound(_:)), for: .valueChanged)
        hapticSwitch.addTarget(self, action: #selector(onHaptic(_:)), for: .valueChanged)
        volumeSlider.addTarget(self, action: #selector(onVol(_:)), for: .valueChanged)

        // 双拼方案选择
        let schemes = engine.availableShuangpinSchemes()
        let spSeg = UISegmentedControl(items: schemes)
        spSeg.selectedSegmentIndex = max(0, schemes.firstIndex(of: spScheme()) ?? 0)
        spSeg.addTarget(self, action: #selector(onScheme(_:)), for: .valueChanged)
        let spBox = UIStackView(arrangedSubviews: [l4, spSeg])
        spBox.axis = .vertical; spBox.spacing = 8; spBox.alignment = .fill

        let close = UIButton(type: .system)
        close.setTitle("完成", for: .normal)
        close.titleLabel?.font = .boldSystemFont(ofSize: 17)
        close.backgroundColor = .systemFill
        close.layer.cornerRadius = 8
        close.addAction(UIAction { [weak self] _ in self?.toggleSettings() }, for: .touchUpInside)

        let vstack = UIStackView(arrangedSubviews: [title, rowSettings(l1, soundSwitch), rowSettings(l2, volumeSlider), rowSettings(l3, hapticSwitch), spBox, close])
        vstack.axis = .vertical
        vstack.spacing = 16
        vstack.translatesAutoresizingMaskIntoConstraints = false
        vstack.layoutMargins = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        vstack.isLayoutMarginsRelativeArrangement = true
        card.addSubview(vstack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            settingsOverlay.topAnchor.constraint(equalTo: guide.topAnchor),
            settingsOverlay.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            settingsOverlay.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            settingsOverlay.bottomAnchor.constraint(equalTo: guide.bottomAnchor),

            card.centerXAnchor.constraint(equalTo: settingsOverlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: settingsOverlay.centerYAnchor),
            card.leadingAnchor.constraint(equalTo: settingsOverlay.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: settingsOverlay.trailingAnchor, constant: -24),

            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    private func rowSettings(_ left: UIView, _ right: UIView) -> UIStackView {
        let s = UIStackView(arrangedSubviews: [left, right])
        s.axis = .horizontal; s.spacing = 12; s.alignment = .center
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        right.setContentHuggingPriority(.required, for: .horizontal)
        return s
    }

    private func toggleSettings() {
        settingsOverlay.isHidden.toggle()
    }

    @objc private func onSound(_ s: UISwitch) { UserDefaults.standard.set(s.isOn, forKey: "kb_sound_on") }
    @objc private func onHaptic(_ s: UISwitch) { UserDefaults.standard.set(s.isOn, forKey: "kb_haptic_on") }
    @objc private func onVol(_ s: UISlider) { UserDefaults.standard.set(Double(s.value), forKey: "kb_sound_vol") }
    @objc private func onScheme(_ s: UISegmentedControl) {
        let schemes = engine.availableShuangpinSchemes()
        guard s.selectedSegmentIndex >= 0, s.selectedSegmentIndex < schemes.count else { return }
        UserDefaults.standard.set(schemes[s.selectedSegmentIndex], forKey: "kb_sp_scheme")
        if mode == .shuangpin { refresh() }
    }
}
