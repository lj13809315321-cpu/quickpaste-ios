import UIKit
import AVFoundation

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

    private var lockedSylls: [String] = []         // 已锁定的音节（左列点选 / 分词键），连贯组词
    private var sylButtons: [UIButton] = []        // 9 键左列音节候选按钮（动态刷新）
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
        view.backgroundColor = .systemGray5
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
                        (input: $0.userInput, document: $0.documentText)
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
        let kbH: CGFloat = (w > h) ? 230 : 330
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
        pinyinBar.backgroundColor = .clear
        pinyinBar.textAlignment = .left
        pinyinBar.adjustsFontSizeToFitWidth = true
        pinyinBar.minimumScaleFactor = 0.72
        pinyinBar.lineBreakMode = .byTruncatingHead
        view.addSubview(pinyinBar)

        // ---- 候选条（只放汉字候选，拼音串不再挤进来） ----
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.alwaysBounceHorizontal = true
        candidateScroll.backgroundColor = .clear
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
        // 精简（用户反馈：底部一排冗余）：剪贴板页移除，保留 中/EN/123/符号
        let items: [(String, KBMode)] = [
            ("中", .chinese9), ("EN", .english), ("123", .number), ("#", .symbol),
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
        lockedSylls = []
        updateModeBarTitles()
        updateKeyArea()
        refresh()
    }

    private var isComposeMode: Bool { mode == .chinese9 || mode == .chinese26 }

    // MARK: - 音节锁定（搜狗式连贯输入的核心）
    /// 点左列音节候选 / 蓝色音节块：锁定该音节，剩余数字继续输入，跨音节组词。
    private func lockSyllable(_ syl: String) {
        guard isComposeMode else { return }
        lockedSylls.append(syl)
        let n = min(syl.count, compose.count)
        compose = String(compose.dropFirst(n))   // 音节字母数 == 消耗的数字/字母数
        refresh()
    }

    /// 分词键：锁定当前最佳切分的第一个音节（xian → 锁 xi 继续打 an = 西安）
    private func lockFirstSyllable() {
        guard isComposeMode, !compose.isEmpty else { return }
        let first = currentDecode.key.split(separator: " ").map(String.init).first
        guard let syl = first, !syl.isEmpty else { return }
        lockSyllable(syl)
    }

    /// 拼音音节 → 9 键数字串（退格还原锁定音节用）
    private func t9Digits(_ syl: String) -> String {
        let map: [Character: Character] = [
            "a":"2","b":"2","c":"2","d":"3","e":"3","f":"3","g":"4","h":"4","i":"4",
            "j":"5","k":"5","l":"5","m":"6","n":"6","o":"6","p":"7","q":"7","r":"7",
            "s":"7","t":"8","u":"8","v":"8","w":"9","x":"9","y":"9","z":"9",
        ]
        return String(syl.map { map[$0] ?? "2" })
    }

    // MARK: - 候选刷新（按钮复用，不重建）
    /// deep=true：停顿 0.3s 后的深度纠错重算（9键四类按键纠错全位扫描 +
    /// 整词直查，真机体感：打完停一下，候选自动变好——搜狗同款）。
    private var deepTimer: Timer?
    private var deepAppliedKey = ""

    private func refresh(deep: Bool = false) {
        if isComposeMode, (!compose.isEmpty || !lockedSylls.isEmpty) {
            let key = compose + "|" + lockedSylls.joined(separator: " ")
            if deep && key == deepAppliedKey { return }   // 已应用过，不重复算
            let r = engine.decode(compose, is9Key: mode == .chinese9,
                                  context: lastCommitted, locked: lockedSylls,
                                  deep: deep && mode == .chinese9)
            currentDecode = r
            displayCandidates = r.candidates
            if deep { deepAppliedKey = key }
            // 引擎 display 已含锁定音节（best.seq = locked + 新切分），这里只需
            // 给锁定段画下划线区分（竞品 PreeditStyle::Pinned 同款），不要重复拼接
            let rest = r.display.isEmpty ? compose : r.display
            if lockedSylls.isEmpty || rest.isEmpty {
                pinyinBar.text = rest
            } else {
                let lockLen = lockedSylls.reduce(0) { $0 + $1.count } + max(0, lockedSylls.count - 1)
                let safe = min(lockLen, rest.count)
                let m = NSMutableAttributedString(string: String(rest.prefix(safe)),
                    attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
                m.append(NSAttributedString(string: String(rest.dropFirst(safe))))
                pinyinBar.attributedText = m
            }
            if !engine.isLoaded {
                pinyinBar.text = "⚠ 词库未加载 · " + (pinyinBar.text ?? "")
            }
        } else {
            currentDecode = DecodeResult(display: "", candidates: [], key: "")
            displayCandidates = isComposeMode ? engine.associations(for: lastCommitted) : []
            pinyinBar.text = isComposeMode && !engine.isLoaded ? "⚠ 词库未加载，请重装" : ""
        }
        updateCandidateButtons()
        updateSyllableColumn()
        scheduleDeepRefresh()
    }

    /// 每次按键刷新后重置停顿计时：0.3s 无新输入 → 9键深度纠错重算一轮
    /// （换位全位扫描 + 漏键插入 + 整词直查），搜狗「打完停一下变好」的体感。
    private func scheduleDeepRefresh() {
        deepTimer?.invalidate()
        guard isComposeMode, mode == .chinese9, !compose.isEmpty || !lockedSylls.isEmpty else { return }
        deepTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.refresh(deep: true)
        }
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
            if t >= 1000 {                    // 音节候选（蓝色）：锁定后继续打字组词
                let alts = self.currentDecode.alternates
                let idx = t - 1000
                guard idx < alts.count else { return }
                self.lockSyllable(alts[idx])
                return
            }
            if t < self.displayCandidates.count { self.commit(self.displayCandidates[t]) }
        }, for: .touchUpInside)
        return b
    }

    private func updateCandidateButtons() {
        // 汉字候选永远在前 —— 正常打字绝不能被音节块挡住；
        // 音节候选（hao/gao/han…）是 9 键纠错的辅助入口，放最后、只留 4 个，
        // 向左滑到底才看得到，对应搜狗把它放侧栏的做法。
        let words = Array(displayCandidates.prefix(20))
        // 蓝色音节块与左列同源（前缀音节，点选锁定第一个未定位置），保证两处交互一致
        let alts: [String] = (mode == .chinese9 && words.count >= 4 && engine.isLoaded)
            ? Array(engine.t9SyllableOptions(compose).map { $0.0 }.prefix(4)) : []
        let items: [(String, Bool)] = words.map { ($0, false) } + alts.map { ($0, true) }
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
            b.tag = isSyl ? (1000 + i - words.count) : i
            b.setTitle(text, for: .normal)
            b.setTitleColor(isSyl ? .systemBlue : .label, for: .normal)
            b.backgroundColor = isSyl ? UIColor.systemBlue.withAlphaComponent(0.10) : .tertiarySystemFill
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
        lockedSylls = []
        if isComposeMode {
            engine.learn(text, pinyinKey: currentDecode.key, boost: didBackspace ? 3 : 1)
            lastCommitted = text
            compose = ""
            didBackspace = false
        }
        refresh()
    }

    private func backspace() {
        if isComposeMode {
            if !compose.isEmpty {
                compose.removeLast()
            } else if let last = lockedSylls.popLast() {
                // 锁定的音节先退回数字串（可以重选音节）
                compose = (mode == .chinese9 ? t9Digits(last) : last) + compose
            } else {
                // 关键修复（用户实测：中文模式下缓冲一空 ⌫ 就"按不动了"）：
                // 缓冲删完后必须继续删宿主 App 里已上屏的正文
                textDocumentProxy.deleteBackward()
            }
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
    /// triggerOnDown=false 仅供带手势的键（⌫/清空/空格）：必须等 touchUpInside，
    /// 否则手指刚按下就先执行了点按动作，上滑/下滑/滑行手势全被抢先触发。
    private func key(_ title: String, height: CGFloat = 48, triggerOnDown: Bool = true, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.label, for: .normal)
        // 搜狗质感：灰底上浮白键 + 轻投影，暗色模式自动取反
        b.backgroundColor = .secondarySystemGroupedBackground
        b.layer.cornerRadius = 8
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.10
        b.layer.shadowRadius = 1
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        b.titleLabel?.numberOfLines = 0
        b.titleLabel?.textAlignment = .center
        b.contentVerticalAlignment = .center
        b.contentHorizontalAlignment = .center
        let hc = b.heightAnchor.constraint(equalToConstant: height)
        hc.priority = UILayoutPriority(995)   // 空间不足时允许压缩，避免约束冲突
        hc.isActive = true

        b.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            action()
            self.feedback()
        }, for: triggerOnDown ? .touchDown : .touchUpInside)
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

    // MARK: - 长按连删（搜狗同款，逐字带震动+键音）
    // ⌫ / 清空 长按：先删完候选缓冲，再连续删备忘录里已上屏的文字（backspace 内已打通正文）。
    private var holdTimer: Timer?
    private var holdBlocks: [ObjectIdentifier: () -> Void] = [:]

    /// 给按钮挂长按连发。tap 行为照旧（手势键已改为 touchUpInside 触发）。
    private func attachHold(_ b: UIButton, _ block: @escaping () -> Void) {
        holdBlocks[ObjectIdentifier(b)] = block
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(holdGesture(_:)))
        lp.minimumPressDuration = 0.35
        lp.cancelsTouchesInView = true   // 长按连删开始后吞掉点按，抬起时不再多删一个
        b.addGestureRecognizer(lp)
    }

    @objc private func holdGesture(_ g: UILongPressGestureRecognizer) {
        guard let btn = g.view as? UIButton, let block = holdBlocks[ObjectIdentifier(btn)] else { return }
        switch g.state {
        case .began:
            block()
            tick()
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { [weak self] _ in
                block()
                self?.tick()          // 每删一个字：轻震一下 + 键音一声（用户点名要的逐字震动）
            }
        case .ended, .cancelled, .failed:
            holdTimer?.invalidate()
            holdTimer = nil
        default:
            break
        }
    }

    // MARK: - 9键（T9拼音）—— 竞品通用布局（搜狗/百度/讯飞/豆包）
    // 左列：4 个常用音节候选（动态，点选锁定，搜狗官方帮助文档同款交互）；
    // 中间：3×3 大字母格，首行「分词 | ABC | DEF」，底行「123 | 空格 | 中英」；
    // 右列：⌫ / 清空 / 符号 / 确认（蓝底白字，讯飞式）。
    private func nineKeys() -> [UIStackView] {
        func letterKey(_ n: String, _ l: String) -> UIButton {
            let b = key(l, height: 50) { [weak self] in
                guard let self = self else { return }
                self.compose += n
                self.refresh()
            }
            b.titleLabel?.font = UIFont.systemFont(ofSize: 19, weight: .medium)
            return b
        }
        func funcKey(_ t: String, height: CGFloat = 50, triggerOnDown: Bool = true, _ a: @escaping () -> Void) -> UIButton {
            // key() 本身在触发时会调 feedback()，这里不再叠加（旧版功能键按一次响两声震两下）
            let b = key(t, height: height, triggerOnDown: triggerOnDown) { a() }
            // 功能键字体小一号、灰一点，突出字母键
            b.setTitleColor(.secondaryLabel, for: .normal)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 14)
            return b
        }

        // 左列：打字时=前缀音节候选(点选锁定)，空闲时=常用标点。
        // 建槽时挂唯一一个 action，点按时按 accessibilityIdentifier 分派
        // （"syl:gui" 锁音节 / "p:，" 上屏标点），不反复增删 action。
        var sylBtns: [UIButton] = []
        for _ in 0..<4 {
            let b = UIButton(type: .system)
            b.setTitle(" ", for: .normal)
            b.setTitleColor(.label, for: .normal)
            b.backgroundColor = .clear
            b.layer.cornerRadius = 8
            b.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            b.isEnabled = false
            b.translatesAutoresizingMaskIntoConstraints = false
            b.addAction(UIAction { [weak self] a in
                guard let self = self, let btn = a.sender as? UIButton,
                      let tag = btn.accessibilityIdentifier, !tag.isEmpty else { return }
                if tag.hasPrefix("syl:") {
                    self.lockSyllable(String(tag.dropFirst(4)))
                } else if tag.hasPrefix("p:") {
                    self.punctuationCommit(String(tag.dropFirst(2)))
                }
            }, for: .touchUpInside)
            sylBtns.append(b)
        }
        sylButtons = sylBtns
        let leftCol = UIStackView(arrangedSubviews: sylBtns)
        leftCol.axis = .vertical; leftCol.spacing = 6; leftCol.distribution = .fillEqually
        leftCol.translatesAutoresizingMaskIntoConstraints = false
        leftCol.widthAnchor.constraint(equalToConstant: 44).isActive = true

        // 中间字母区
        let fen = funcKey("分词") { [weak self] in self?.lockFirstSyllable() }
        let g1 = row([fen, letterKey("2", "ABC"), letterKey("3", "DEF")])
        let g2 = row([letterKey("4", "GHI"), letterKey("5", "JKL"), letterKey("6", "MNO")])
        let g3 = row([letterKey("7", "PQRS"), letterKey("8", "TUV"), letterKey("9", "WXYZ")])
        // 空格：点按=确认首选；滑行=移动光标（逐字带震感，搜狗同款）
        let sp9 = funcKey("空格", triggerOnDown: false) { [weak self] in
            guard let self = self else { return }
            if self.isComposeMode { self.confirm() } else { self.textDocumentProxy.insertText(" ") }
        }
        attachSpacePan(sp9)
        let g4 = row([
            funcKey("123") { [weak self] in self?.switchMode(.number) },
            sp9,
            funcKey("中英") { [weak self] in
                guard let self = self else { return }
                self.switchMode(self.mode == .chinese9 ? .english : .chinese9)
            },
        ])
        let mainCol = UIStackView(arrangedSubviews: [g1, g2, g3, g4])
        mainCol.axis = .vertical; mainCol.spacing = 6

        // 右功能列：⌫ / 清空 / 符号 / 确认（蓝色，竞品同款）
        // ⌫ 与 清空 全套手势（用户点名）：
        //   点按=逐删缓冲→正文；长按=逐字连删带震动；
        //   左滑=光标跟随逐字滑删（滑回来还能逐字还原）；
        //   上滑=清空全部（缓冲+正文，可下滑恢复）；下滑=恢复刚清掉的内容。
        let bk = funcKey("⌫", triggerOnDown: false) { [weak self] in self?.backspace() }
        bk.titleLabel?.font = UIFont.systemFont(ofSize: 18)
        attachHold(bk) { [weak self] in self?.backspace() }
        attachClearGestures(bk)
        let clear = funcKey("清空", triggerOnDown: false) { [weak self] in self?.clearPreeditOrAll() }
        attachHold(clear) { [weak self] in self?.backspace() }
        attachClearGestures(clear)
        let sym = funcKey("符号") { [weak self] in self?.switchMode(.symbol) }
        let ok = funcKey("确认") { [weak self] in
            guard let self = self else { return }
            if self.isComposeMode, (!self.compose.isEmpty || !self.lockedSylls.isEmpty) {
                self.confirm()          // 打字中：首选上屏
            } else {
                self.textDocumentProxy.insertText("\n")   // 空闲时当换行/发送键
            }
        }
        ok.backgroundColor = .systemBlue
        ok.setTitleColor(.white, for: .normal)
        ok.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        let rightCol = UIStackView(arrangedSubviews: [bk, clear, sym, ok])
        rightCol.axis = .vertical; rightCol.spacing = 6; rightCol.distribution = .fillEqually
        rightCol.translatesAutoresizingMaskIntoConstraints = false
        rightCol.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let panel = UIStackView(arrangedSubviews: [leftCol, mainCol, rightCol])
        panel.axis = .horizontal; panel.spacing = 6; panel.alignment = .fill
        return [panel]
    }

    /// 左列刷新：打字时=4 个前缀音节候选（点选锁定第一个未定位置）；
    /// 空闲时=4 个常用中文标点（讯飞/豆包符号列、qingjian「不组句时放标点」）。
    /// 建槽时已挂唯一 action（按 accessibilityIdentifier 分派），这里只改外观与标签。
    private func updateSyllableColumn() {
        guard mode == .chinese9, sylButtons.count == 4 else { return }
        let opts = (engine.isLoaded && !compose.isEmpty)
            ? Array(engine.t9SyllableOptions(compose).prefix(4)) : []
        let puncts: [String] = opts.isEmpty ? ["，", "。", "？", "！"] : []
        for i in 0..<sylButtons.count {
            let b = sylButtons[i]
            if i < opts.count {
                let syl = opts[i].0
                b.isEnabled = true
                b.accessibilityIdentifier = "syl:" + syl
                b.setTitle(syl, for: .normal)
                b.setTitleColor(.label, for: .normal)
                b.backgroundColor = .tertiarySystemFill
                b.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            } else if i < puncts.count {
                let p = puncts[i]
                b.isEnabled = true
                b.accessibilityIdentifier = "p:" + p
                b.setTitle(p, for: .normal)
                b.setTitleColor(.label, for: .normal)
                b.backgroundColor = .secondarySystemGroupedBackground
                b.titleLabel?.font = UIFont.systemFont(ofSize: 18)
            } else {
                b.isEnabled = false
                b.accessibilityIdentifier = nil
                b.setTitle(" ", for: .normal)
                b.backgroundColor = .clear
            }
        }
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
                btns.append(backspaceKey())
            }
            rows.append(row(btns))
        }
        let r4: UIStackView
        if insertDirectly {
            let spEn = key("空格", triggerOnDown: false) { [weak self] in
                self?.textDocumentProxy.insertText(" ")
            }
            attachSpacePan(spEn)
            r4 = row([
                spEn,
                key("⏎") { [weak self] in self?.textDocumentProxy.insertText("\n") },
            ])
        } else {
            let sp26 = key("空格/确认", triggerOnDown: false) { [weak self] in self?.confirm() }
            attachSpacePan(sp26)
            r4 = row([
                key("，") { [weak self] in self?.punctuationCommit("，") },
                sp26,
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
            backspaceKey(),
            key("0") { [weak self] in self?.textDocumentProxy.insertText("0") },
            key(".") { [weak self] in self?.textDocumentProxy.insertText(".") },
            key("⏎") { [weak self] in self?.textDocumentProxy.insertText("\n") },
        ])
        return [r1, r2, r3, r4]
    }

    // MARK: - 符号
    private func symbolKeys() -> [UIStackView] {
        let sets = [
            // 中文标点常驻首行：9 键面板不再有标点列，聊天常用标点必须一键直达
            ["，", "。", "？", "！", "、", "：", "；", "…", "—"],
            ["@", "#", "&", "*", "(", ")", "_", "-", "+"],
            [",", ".", "?", "!", "\"", "'", ":", ";"],
            ["/", "\\", "|", "~", "`", "%", "^", "="],
        ]
        var rows: [UIStackView] = []
        for (i, set) in sets.enumerated() {
            rows.append(row(set.map { ch in
                let b = key(ch) { [weak self] in self?.textDocumentProxy.insertText(ch) }
                if i == 0 { b.titleLabel?.font = UIFont.systemFont(ofSize: 19) }
                return b
            }))
        }
        let spSym = key("空格", triggerOnDown: false) { [weak self] in self?.textDocumentProxy.insertText(" ") }
        attachSpacePan(spSym)
        rows.append(row([
            backspaceKey(),
            spSym,
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

    // MARK: - 清除/光标手势引擎（用户点名：搜狗同款）
    // ⌫ / 清空 键：
    //   上滑 = 清空全部（拼音缓冲 + 已上屏正文），下滑 = 恢复刚清掉的内容；
    //   左滑 = 光标跟随逐字滑删（每约16pt删一字，滑回来逐字还原，逐字震动）；
    //   长按 = 逐字连删带震动。
    // 空格键：左右滑行 = 移动光标（每约13pt一字，逐字震动）。

    private var clearSnapshot: (before: String, after: String)?  // 上滑清空前的正文快照（下滑恢复用）
    private var lastPreeditCleared: String = ""                  // 刚清掉的原始输入串（下滑恢复用）
    private var slideAnchorX: CGFloat = 0
    private var slideUndo: [(fromText: Bool, text: String)] = [] // 本次左滑删掉的字（右滑逐字还原）
    private var spaceAnchorX: CGFloat = 0
    private let slideStep: CGFloat = 16
    private let spaceStep: CGFloat = 13

    /// 通用退格键：点按逐删（缓冲→正文）/ 长按连删 / 左滑滑删 / 上滑清空 / 下滑恢复
    private func backspaceKey(title: String = "⌫", height: CGFloat = 48) -> UIButton {
        let b = key(title, height: height, triggerOnDown: false) { [weak self] in self?.backspace() }
        attachHold(b) { [weak self] in self?.backspace() }
        attachClearGestures(b)
        return b
    }

    /// 清空键点按：有拼音缓冲就只清缓冲；缓冲是空的就直接清空整个输入框正文（用户实测痛点：
    /// "清除键只能清候选栏，输入栏一个字都清不掉"）。两种情况都记快照，下滑可恢复。
    private func clearPreeditOrAll() {
        if !compose.isEmpty || !lockedSylls.isEmpty {
            lastPreeditCleared = rawInputString()
            compose = ""; lockedSylls = []; didBackspace = false
            refresh()
        } else {
            clearAllText()
        }
    }

    /// 原始输入串（9键=数字，26键=字母），清掉缓冲后下滑恢复时原样放回 compose
    private func rawInputString() -> String {
        lockedSylls.map { mode == .chinese9 ? t9Digits($0) : $0 }.joined() + compose
    }

    /// 上滑清空：正文前后文各拍一份快照，再从光标处一路删到头；同时清掉拼音缓冲
    private func clearAllText() {
        // documentTextBefore/AfterInput 是 UIInputViewController 的属性（iOS 15+）
        let before = documentTextBeforeInput ?? ""
        let after = documentTextAfterInput ?? ""
        if !before.isEmpty || !after.isEmpty { clearSnapshot = (before, after) }
        if !compose.isEmpty || !lockedSylls.isEmpty {
            lastPreeditCleared = rawInputString()
            compose = ""; lockedSylls = []; didBackspace = false
        }
        // 连删正文。hasText 只会反映光标前文本，删空后个别 App 仍返回 true，
        // 所以再加"连续 4 轮没变化就停"的保险，外加 4000 字硬上限。
        var n = 0, prevLen = -1, stable = 0
        while textDocumentProxy.hasText, n < 4000 {
            textDocumentProxy.deleteBackward()
            let len = (documentTextBeforeInput ?? "").count
            if len == prevLen { stable += 1; if stable > 3 { break } } else { stable = 0 }
            prevLen = len
            n += 1
        }
        refresh()
        tick()
    }

    /// 下滑恢复：优先恢复正文快照（连带刚清掉的拼音缓冲），其次恢复拼音缓冲
    private func restoreCleared() {
        if let snap = clearSnapshot {
            textDocumentProxy.insertText(snap.before + snap.after)
            clearSnapshot = nil
            if !lastPreeditCleared.isEmpty { compose = lastPreeditCleared; lastPreeditCleared = "" }
            refresh()
            tick()
        } else if !lastPreeditCleared.isEmpty {
            compose = lastPreeditCleared
            lastPreeditCleared = ""
            refresh()
            tick()
        }
    }

    /// 挂清除键手势：上滑清空 / 下滑恢复 / 左滑滑删
    private func attachClearGestures(_ b: UIButton) {
        let up = UISwipeGestureRecognizer(target: self, action: #selector(clearAllGesture(_:)))
        up.direction = .up
        b.addGestureRecognizer(up)
        let down = UISwipeGestureRecognizer(target: self, action: #selector(restoreGesture(_:)))
        down.direction = .down
        b.addGestureRecognizer(down)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(deletePan(_:)))
        pan.delegate = self
        b.addGestureRecognizer(pan)
    }

    @objc private func clearAllGesture(_ g: UISwipeGestureRecognizer) { clearAllText() }
    @objc private func restoreGesture(_ g: UISwipeGestureRecognizer) { restoreCleared() }

    /// 左滑逐字滑删（每滑约一个键宽删一字，滑回来逐字还原），逐字轻震
    @objc private func deletePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            slideAnchorX = 0
            slideUndo = []
        case .changed:
            let x = g.translation(in: g.view).x
            var guardCount = 0
            while x - slideAnchorX <= -slideStep, guardCount < 20 {
                slideAnchorX -= slideStep
                slideUndo.append(deleteOneForSlide())
                tick()
                guardCount += 1
            }
            guardCount = 0
            while x - slideAnchorX >= slideStep, !slideUndo.isEmpty, guardCount < 20 {
                slideAnchorX += slideStep
                let d = slideUndo.removeLast()
                if d.fromText {
                    textDocumentProxy.insertText(d.text)
                } else {
                    compose += d.text
                    refresh()
                }
                tick()
                guardCount += 1
            }
        default:
            break
        }
    }

    /// 滑删一步：先删拼音缓冲（数字/字母），缓冲空了删正文（记下被删的字用于还原）
    private func deleteOneForSlide() -> (fromText: Bool, text: String) {
        if isComposeMode {
            if !compose.isEmpty {
                let c = String(compose.removeLast())
                refresh()
                return (false, c)
            }
            if let last = lockedSylls.popLast() {
                let raw = mode == .chinese9 ? t9Digits(last) : last
                refresh()
                return (false, raw)
            }
        }
        let before = documentTextBeforeInput ?? ""
        textDocumentProxy.deleteBackward()
        let ch = before.isEmpty ? "" : String(before.suffix(1))
        return (true, ch.isEmpty ? " " : ch)
    }

    /// 挂空格滑行：左右移动光标（逐字震动）
    private func attachSpacePan(_ b: UIButton) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(spacePan(_:)))
        pan.delegate = self
        b.addGestureRecognizer(pan)
    }

    @objc private func spacePan(_ g: UIPanGestureRecognizer) {
        // 正在组词时滑空格不做光标移动（点按仍是确认首选）
        guard compose.isEmpty, lockedSylls.isEmpty else { return }
        switch g.state {
        case .began:
            spaceAnchorX = 0
        case .changed:
            let x = g.translation(in: g.view).x
            var guardCount = 0
            while x - spaceAnchorX >= spaceStep, guardCount < 30 {
                spaceAnchorX += spaceStep
                moveCursor(1)
                guardCount += 1
            }
            guardCount = 0
            while x - spaceAnchorX <= -spaceStep, guardCount < 30 {
                spaceAnchorX -= spaceStep
                moveCursor(-1)
                guardCount += 1
            }
        default:
            break
        }
    }

    private func moveCursor(_ n: Int) {
        textDocumentProxy.adjustTextPosition(byCharacterOffset: n)
        tick()   // 每移一字轻震一下（用户点名："滑一个字节有震感"）
    }

    // MARK: - 反馈（震动 + 按键音）
    // 注：impact 生成器与 currentImpact() 在类顶部统一声明（此处曾重复导致编译错）
    private lazy var selectionGen = UISelectionFeedbackGenerator()

    private func feedback() {
        if hapticOn() {
            let g = currentImpact()
            g.impactOccurred()
            g.prepare()               // 为下一次按键预准备，连打零延迟
        }
        playClick()
    }

    /// 手势逐字反馈（滑删/滑移光标/长按连删）：轻震 + 键音
    private func tick() {
        if hapticOn() {
            selectionGen.selectionChanged()
            selectionGen.prepare()
        }
        playClick()
    }

    // ---- 键音引擎 ----
    // 实测教训：playInputClick() 在第三方键盘扩展里多数时候不响（用户反馈"没有声音"）；
    // 自写 WAV + AudioServicesCreateSystemSoundID 也不响。
    // 这里走第三条路：合成一段"嗒"声 WAV 缓存到沙盒，AVAudioPlayer + .playback 会话播放
    // （.playback + mixWithOthers：静音拨片打开也照响，音量跟随 App 设置的滑杆）。
    // 首次按键后异步懒加载，不在键盘弹出帧做重活（watchdog 教训）。
    private var clickPlayer: AVAudioPlayer?
    private var clickSetupTried = false

    private func playClick() {
        guard soundOn() else { return }
        if let p = clickPlayer {
            p.volume = max(0.1, min(1, soundVol()))
            p.currentTime = 0
            p.play()
        } else {
            UIDevice.current.playInputClick()   // 兜底（部分机型/系统有效）
            setupClickSoundAsync()
        }
    }

    private func setupClickSoundAsync() {
        guard !clickSetupTried else { return }
        clickSetupTried = true
        DispatchQueue.main.async { [weak self] in self?.setupClickSound() }
        // 只尝试一次；若激活会话失败（极少数），维持 playInputClick 兜底
    }

    private func setupClickSound() {
        guard clickPlayer == nil else { return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, options: [.mixWithOthers])
            try s.setActive(true)
            let p = try AVAudioPlayer(contentsOf: cachedClickWav())
            p.prepareToPlay()
            clickPlayer = p
        } catch {
            clickPlayer = nil
        }
    }

    /// 合成键音缓存文件（第一次用写入，之后直接复用）
    private func cachedClickWav() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kb_click.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? makeClickWav().write(to: url)
        }
        return url
    }

    /// 短促"嗒"声：1750→1200Hz 下扫正弦 + 快速指数衰减 + 4ms 起振噪声，50ms
    private func makeClickWav() -> Data {
        let sr = 22050.0
        let dur = 0.05
        let n = Int(sr * dur)
        var samples = [Int16](repeating: 0, count: n)
        let phase = Double.random(in: 0..<(2 * .pi))
        for i in 0..<n {
            let t = Double(i) / sr
            let env = exp(-t * 110) * min(1, t * 2000)
            let f = 1750.0 - 550.0 * (t / dur)
            var v = sin(2 * Double.pi * f * t + phase) * 0.55 * env
            if t < 0.004 {
                v += (Double((i & 1023)) / 1024.0 - 0.5) * 0.5 * (1 - t / 0.004)
            }
            samples[i] = Int16(max(-1, min(1, v)) * 32000)
        }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
        var d = Data()
        d.append(contentsOf: Data("RIFF".utf8))
        d.append(contentsOf: le32(UInt32(36 + n * 2)))
        d.append(contentsOf: Data("WAVE".utf8))
        d.append(contentsOf: Data("fmt ".utf8))
        d.append(contentsOf: le32(16))
        d.append(contentsOf: le16(1))                     // PCM
        d.append(contentsOf: le16(1))                     // 单声道
        d.append(contentsOf: le32(UInt32(sr)))
        d.append(contentsOf: le32(UInt32(Int(sr) * 2)))   // byte rate
        d.append(contentsOf: le16(2))                     // block align
        d.append(contentsOf: le16(16))                    // 位深
        d.append(contentsOf: Data("data".utf8))
        d.append(contentsOf: le32(UInt32(n * 2)))
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

// MARK: - 手势代理
extension KeyboardViewController: UIGestureRecognizerDelegate {
    /// 滑行/滑删的 pan 只吃横向手势，纵向留给 上滑/下滑 swipe（清空/恢复），
    /// 否则手指稍带一点上下抖动就会把两个手势都触发。
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if let p = g as? UIPanGestureRecognizer {
            let v = p.velocity(in: p.view)
            return abs(v.x) > abs(v.y)
        }
        return true
    }
}
