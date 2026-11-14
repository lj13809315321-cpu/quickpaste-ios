import UIKit

// 模式：只保留搜狗式的基础布局（中文9键/中文26键/英文/数字/符号/剪贴板），不再有双拼。
enum KBMode {
    case chinese9, chinese26, english, number, symbol, clipboard
}

// 主 App ↔ 键盘的设置同步通道。
// 不依赖 App Group（手机端重签工具通常不会保留自定义 entitlement），
// 改用系统剪贴板里追加一个自定义 item；键盘开启「完全访问」后读取并移除。
private let kSettingsPBKey = "app.mulberry6323.mozhi.kbcfg"
private let kDiagPBKey = "app.mulberry6323.mozhi.kbdiag"

class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {

    /// Apple 给自定义键盘的官方按键音开关。playInputClick() 由系统播放，
    /// 不需要完全访问、不需要 AVAudioSession，音色就是系统键盘音。
    var enableInputClicksWhenVisible: Bool { true }

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

    // 反馈（音 / 震），开关由主 App 设置页同步过来。
    // 上一版用「自写 WAV + 自定义 SystemSound」实测在扩展里完全不出声；
    // 现改用 UIDevice.playInputClick()（官方键盘音 API），保证一定响。
    // 音量跟随系统音量键 /「设置 › 声音与触感 › 键盘反馈」，
    // 主 App 的滑杆改作震动强度（这是扩展里唯一能自己调的反馈量）。
    private lazy var impactSoft = UIImpactFeedbackGenerator(style: .soft)
    private lazy var impactLight = UIImpactFeedbackGenerator(style: .light)
    private lazy var impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private func currentImpact() -> UIImpactFeedbackGenerator {
        let v = soundVol()
        return v < 0.34 ? impactSoft : (v < 0.67 ? impactLight : impactMedium)
    }

    private var pinnedSyllable: String? = nil      // 点选搜狗式音节候选后锁定
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
        var found: Data?
        for item in items {
            if let s = item[kSettingsPBKey] as? String { found = s.data(using: .utf8); break }
            if let d = item[kSettingsPBKey] as? Data { found = d; break }
        }
        guard let data = found,
              let sig = String(data: data, encoding: .utf8),
              sig != (UserDefaults.standard.string(forKey: "kb_last_cfg") ?? ""),
              let cfg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        UserDefaults.standard.set(sig, forKey: "kb_last_cfg")
        if let v = cfg["sound"] as? Bool { UserDefaults.standard.set(v, forKey: "kb_sound_on") }
        if let v = cfg["haptic"] as? Bool { UserDefaults.standard.set(v, forKey: "kb_haptic_on") }
        if let v = cfg["vol"] as? Double { UserDefaults.standard.set(v, forKey: "kb_sound_vol") }
        if let ph = cfg["phrases"] as? [String: String] {
            UserDefaults.standard.set(ph, forKey: "kb_custom_phrases")
            engine.setCustomPhrases(ph)
        }
        // 只读不写回：键盘扩展写 UIPasteboard.items 既可能触发异常，
        // 也会把用户刚复制的内容清掉。配置本身是幂等的，重复读到无副作用。
    }

    /// 启动里程碑。键盘扩展和主 App 不共享 UserDefaults（没有 App Group），
    /// 所以用剪贴板里一个独立 item 把状态递出去，主 App 设置页能显示「停在第几步」。
    private func mark(_ step: String) {
        UserDefaults.standard.set(step, forKey: "kb_diag")
        UIPasteboard.general.addItems([[kDiagPBKey: step]])
    }

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        mark("1:init")
        if let ph = UserDefaults.standard.dictionary(forKey: "kb_custom_phrases") as? [String: String] {
            engine.setCustomPhrases(ph)
        }
        syncSettingsFromApp()
        setupUI()
        updateKeyArea()
        applyKeyboardHeight()
        currentImpact().prepare()
        mark("2:ui-ready")

        // 关键修复：UI 先完整呈现，再把词库分两帧加载。
        // 旧版在 UIInputViewController 构造时同步解析 11 个 JSON（PinyinEngine.shared），
        // 又在键盘刚弹出的第一帧启动 AVAudioEngine + 激活 AVAudioSession，
        // 两个重活叠在一起 → 扩展被 watchdog / jetsam 杀掉，表现就是「弹一下就没了，
        // 自动回退到系统英文键盘」。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.engine.loadCore()
            self.mark("3:core")
            self.refresh()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.engine.loadExtras()
                self.mark("4:extras")
                self.refresh()
                // 苹果官方补充词库 API（UILexicon）：系统「文本替换」+ 通讯录姓名。
                // 这是苹果唯一开放给第三方键盘的官方词库接口；异步获取，不占启动时间。
                self.requestSupplementaryLexicon { [weak self] lexicon in
                    let entries = lexicon.entries.map {
                        (input: $0.userInput, document: $0.document)
                    }
                    self?.engine.ingestAppleLexicon(entries)
                    self?.mark("5:lexicon")
                }
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncSettingsFromApp()
        applyKeyboardHeight()
        currentImpact().prepare()
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
        pinnedSyllable = nil
        updateModeBarTitles()
        updateKeyArea()
        refresh()
    }

    private var isComposeMode: Bool { mode == .chinese9 || mode == .chinese26 }

    // MARK: - 候选刷新（按钮复用，不重建）
    private func refresh() {
        // 点选了搜狗式音节候选（ming / ning / min / nin）后锁定该音节，
        // 候选栏直接给它的常用字词 —— 按错数字也能一键改回来。
        if let pin = pinnedSyllable {
            currentDecode = DecodeResult(display: pin, candidates: [], key: "")
            displayCandidates = engine.candidates(forSyllable: pin)
            pinyinBar.text = pin + " · 选字上屏，再按数字键重新输入"
            updateCandidateButtons()
            return
        }
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
            let t = btn.tag
            if t >= 1000 {                    // 音节候选（蓝色）
                let alts = self.currentDecode.alternates
                let idx = t - 1000
                guard idx < alts.count else { return }
                self.pinnedSyllable = alts[idx]
                self.compose = ""
                self.refresh()
                return
            }
            if t < self.displayCandidates.count { self.commit(self.displayCandidates[t]) }
        }, for: .touchUpInside)
        return b
    }

    private func updateCandidateButtons() {
        // 9 键：把音节候选放在最前面（对应搜狗左侧 wen/zen/ye/ze 那一列）
        let alts: [String] = (mode == .chinese9 && pinnedSyllable == nil)
            ? Array(currentDecode.alternates.prefix(6)) : []
        let words = Array(displayCandidates.prefix(max(4, 20 - alts.count)))
        let items: [(String, Bool)] = alts.map { ($0, true) } + words.map { ($0, false) }
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
            let (text, isSyl) = items[i]
            b.tag = isSyl ? (1000 + i) : (i - alts.count)
            b.setTitle(isSyl ? "⌜\(text)⌝" : text, for: .normal)
            b.setTitleColor(isSyl ? .systemBlue : .label, for: .normal)
            b.backgroundColor = isSyl ? UIColor.systemBlue.withAlphaComponent(0.12) : .tertiarySystemFill
            let len = text.count
            b.titleLabel?.font = isSyl
                ? UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
                : UIFont.systemFont(ofSize: len > 8 ? 14 : (len > 4 ? 16 : 18))
        }
        for i in items.count..<candidateButtons.count { candidateButtons[i].isHidden = true }
        candidateScroll.contentOffset = .zero
        candidateScroll.setNeedsLayout()
    }

    private func commit(_ text: String) {
        textDocumentProxy.insertText(text)
        pinnedSyllable = nil
        if isComposeMode {
            engine.learn(text, pinyinKey: currentDecode.key, boost: didBackspace ? 3 : 1)
            lastCommitted = text
            compose = ""
            didBackspace = false
        }
        refresh()
    }

    private func backspace() {
        pinnedSyllable = nil
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
                self.pinnedSyllable = nil
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
            let g = currentImpact()
            g.impactOccurred()
            g.prepare()               // 为下一次按键预准备，连打零延迟
        }
        guard soundOn() else { return }
        // 官方键盘音：系统进程播放，键盘扩展里唯一确定出声的方式。
        // 音量由系统音量键与「设置 › 声音与触感 › 键盘反馈 › 声音」控制。
        UIDevice.current.playInputClick()
    }
}
