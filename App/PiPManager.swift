import Foundation
import UIKit
import AVFoundation
import AVKit
import SwiftUI
import Combine
import Network

// MARK: - PiP 小窗里画什么（自定义界面，没有任何播放控件）

/// 用户参考图里那个「连续复制中…」深色小窗，用的是 iOS 的【视频通话画中画】：
/// 窗口内容由我们的 UIViewController 提供，系统只负责把窗口浮起来、给 ✕ 按钮、
/// 支持拖到屏幕边缘缩成小图标。
///
/// 之前用 AVPlayerLayer 播静音视频，系统会把它当「视频播放器」，
/// 于是小窗上出现播放/暂停/快进 15 秒那一套控件。
/// 字号也按用户要求放大了：主标题 34pt、「已收录 N 条」26pt 加粗白字，
/// 小窗缩到边缘时再按窗口宽度等比缩。
final class QPPiPViewController: AVPictureInPictureVideoCallViewController {

    private let stack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subLabel = UILabel()
    private let countLabel = UILabel()

    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?
    private var scaledSize: CGFloat = 0
    private var count: Int = 0
    private var blocked = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        iconView.image = UIImage(systemName: "doc.on.doc.fill")
        iconView.tintColor = UIColor(red: 0.36, green: 0.59, blue: 1.0, alpha: 1)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "连续复制中…"
        titleLabel.textColor = UIColor(white: 1, alpha: 0.78)
        // 用户要求：「连续复制中…」只是说明，字号变小；真正要看清的是下面的「已收录 N 条」
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.4

        subLabel.text = "Continuous copying…"
        subLabel.textColor = UIColor(white: 1, alpha: 0.55)
        subLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subLabel.textAlignment = .center
        subLabel.numberOfLines = 2
        subLabel.adjustsFontSizeToFitWidth = true
        subLabel.minimumScaleFactor = 0.4

        countLabel.text = "已收录 0 条"
        countLabel.textColor = .white
        // 用户要求：条数放大，一眼看清收录了几条
        countLabel.font = .systemFont(ofSize: 44, weight: .bold)
        countLabel.textAlignment = .center
        countLabel.numberOfLines = 1
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.4

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subLabel)
        stack.addArrangedSubview(countLabel)

        let w = iconView.widthAnchor.constraint(equalToConstant: 34)
        let h = iconView.heightAnchor.constraint(equalToConstant: 34)
        iconWidth = w
        iconHeight = h
        NSLayoutConstraint.activate([
            w, h,
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -10)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        guard w > 1 else { return }
        let s = max(0.26, min(1.0, w / 620))
        guard abs(s - scaledSize) > 0.04 else { return }
        scaledSize = s
        applyFonts(s)
    }

    private func applyFonts(_ s: CGFloat) {
        titleLabel.font = .systemFont(ofSize: 20 * s, weight: .semibold)
        subLabel.font = .systemFont(ofSize: 13 * s, weight: .regular)
        countLabel.font = .systemFont(ofSize: 44 * s, weight: .bold)
        iconWidth?.constant = 34 * s
        iconHeight?.constant = 34 * s
        stack.spacing = max(1, 5 * s)
    }

    /// 正常状态：大字「已收录 N 条」
    func update(count: Int) {
        self.count = count
        guard !blocked else { return }
        countLabel.textColor = .white
        countLabel.text = "已收录 \(count) 条"
        subLabel.text = "Continuous copying…"
    }

    /// 系统拦住了后台读剪贴板：小窗直接把解决办法喊出来，别让小字糊弄人
    func update(blocked: Bool, count: Int) {
        self.blocked = blocked
        self.count = count
        countLabel.textColor = blocked
            ? UIColor(red: 1.0, green: 0.72, blue: 0.25, alpha: 1)
            : .white
        countLabel.text = blocked ? "需要允许粘贴" : "已收录 \(count) 条"
        subLabel.text = blocked
            ? "系统设置 → 墨指 → 从其他 App 粘贴 → 允许"
            : "Continuous copying…"
        if scaledSize > 0 { applyFonts(scaledSize) }
    }
}

// MARK: - 连续复制管理器

/// 「连续复制」= 在任意 App 里复制，内容自动进剪贴板列表（不需要切回键盘）。
///
/// iOS 的现实约束（这是「只收录一条」的真正原因）：
///   · 键盘扩展只在被呼出时运行，收起就被挂起 —— 键盘自己做不到跨 App 常驻；
///   · 主 App 想留在后台，必须有合法的后台模式。这里用系统画中画 + 音频
///     让 App 保持存活；
///   · ★ 即使 App 活着，iOS 16 起也不许它随便读剪贴板：必须由用户把
///     「设置 → 墨指 → 从其他 App 粘贴」设成【允许】。否则后台每次读
///     都拿到 nil（前台会弹一次授权框，后台连框都不弹，直接给 nil）。
///     上一版就是只抓到第 1 条（那时 App 还在前台），之后永远是 nil，
///     于是小窗永远显示「已收录 1 条」。
///
/// 现在：
///   · changeCount 变了但读不到正文 → 判定 blocked，小窗 + App 首页直接喊「需要允许粘贴」；
///   · 抓到就写进 QPSharedHistory（App Group 文件优先，剪贴板自定义类型兜底）；
///   · 键盘弹起后把共享里的每一条都并进本机历史。
final class PiPManager: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {

    static let shared = PiPManager()

    /// v1.8.31：message 是 private(set)，跨文件不可直接赋值；
    /// 主 App 根视图用这个方法写一行状态提示。
    func note(_ text: String) { message = text }

    @Published private(set) var running = false
    @Published private(set) var capturedCount = 0
    @Published private(set) var message = ""
    @Published private(set) var blocked = false
    @Published private(set) var supported = AVPictureInPictureController.isPictureInPictureSupported()

    private var pipController: AVPictureInPictureController?
    private var contentVC: QPPiPViewController?
    private var sourceView: UIView?
    private var silence: AVAudioPlayer?
    private var monitor: Timer?
    private var lastChange = -1
    private var lastBeat = Date.distantPast
    private var starting = false
    private var watchOnly = false
    /// 最近已经推到电脑的文本，避免同一条反复 POST
    private var pushedRecent: [String] = []
    // v1.8.18 断网守卫：主 App 侧同样监听 Wi-Fi（推电脑前先看网络，没有 Wi-Fi 就不空跑请求）
    private let netMonitor = NWPathMonitor()
    private var netWiFiOK = true

    private override init() {
        super.init()
        // App 是共享通道的唯一写入方，读不到时用内存里的记录继续累积
        QPSharedHistory.memoryFallback = true
        netMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied &&
                (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            DispatchQueue.main.async { self?.netWiFiOK = ok }
        }
        netMonitor.start(queue: DispatchQueue(label: "mozhi.app.netmonitor"))
    }

    // MARK: - 开启

    func start() { start(retry: 8) }

    /// v1.8.39：App/快捷指令刚拉起时窗口可能还没挂上，导致画中画直接 -1001 失败。
    /// 这里窗口未就绪就稍等重试，就绪后再真正拉起；三种开启入口（App 按钮 /
    /// 键盘跳 / 快捷指令）都走这套，无需各自 sleep。
    private func start(retry: Int) {
        guard supported else {
            message = "这台设备或系统版本不支持画中画，无法跨 App 连续复制"
            return
        }
        guard !running, !starting else { return }
        guard let window = Self.keyWindow() else {
            if retry > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.start(retry: retry - 1)
                }
            } else {
                message = "找不到 App 窗口，请退回首页再点一次"
            }
            return
        }
        setupAndStart(window: window)
    }

    private func setupAndStart(window: UIWindow) {
        guard !running, !starting else { return }

        // v1.8.38/1.8.39：「开启前清空」开关（清空 App 端）；「清空输入法前端」
        // 开关（额外让键盘清空自己的前端栏）。两者任一打开都先把 App 端清掉，
        // 因为键盘前端和 App 共用共享通道，不清 App 端键盘也会从通道把旧条目搬回。
        let clearApp = UserDefaults.standard.bool(forKey: "qp.pipClearOnStart")
        let clearKb = UserDefaults.standard.bool(forKey: "qp.pipClearKbOnStart")
        if clearApp || clearKb { Self.clearContinuousHistory() }
        if clearKb { QPSharedHistory.markKbClear() }

        starting = true
        message = "正在开启画中画…"

        // 先把监听跑起来：App 在前台时读取剪贴板是**不需要**额外授权的，
        // 所以用户此刻复制的东西能立刻进列表，也能顺便把「是否被系统拦」测出来。
        startMonitor()
        // 小窗起来后再试读一次：前台这次通常会弹「允许粘贴」，用户点允许就说明通了；
        // 点不允许就立刻把 blocked 亮出来，别让用户以为在抓。
        // （延后是为了别让系统授权框挡在画中画启动前面）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.running else { return }
            self.readNow(pb: UIPasteboard.general)
        }

        // 从系统设置改完「从其他 App 粘贴 → 允许」回来，马上重测，不用等下一次复制
        NotificationCenter.default.removeObserver(self,
                                                 name: UIApplication.didBecomeActiveNotification,
                                                 object: nil)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.running || self.starting else { return }
            self.readNow(pb: UIPasteboard.general)
        }

        // 承载视图必须真实挂在窗口上（不能 hidden、不能不加入层级、不能是零尺寸），
        // 否则 startPictureInPicture() 会静默失败。
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        host.backgroundColor = .clear
        host.alpha = 0.02
        host.isUserInteractionEnabled = false
        window.addSubview(host)
        sourceView = host

        let vc = QPPiPViewController()
        vc.preferredContentSize = CGSize(width: 640, height: 360)
        // v1.8.15：画中画计数按「本次会话」归零，从 0 重新累加，
        // 不再显示历史总条数（用户：启动一次应归零、重新计算）。
        capturedCount = 0
        vc.update(count: capturedCount)
        contentVC = vc

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: host,
            contentViewController: vc)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller

        startAudioKeepAlive()

        // v1.8.39：画中画起不来（AVKitErrorDomain -1001）多为系统路由/窗口还没就绪，
        // 这里失败就重试几次（0.25s / 0.75s / 1.25s），把瞬时失败吃掉。
        attemptStartPiP(attempt: 3)
    }

    private func attemptStartPiP(attempt: Int) {
        guard let c = pipController else { starting = false; return }
        guard !c.isPictureInPictureActive else { starting = false; return }
        c.startPictureInPicture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.pipController?.isPictureInPictureActive == true {
                self.starting = false
            } else if attempt > 1 {
                self.attemptStartPiP(attempt: attempt - 1)
            } else {
                self.starting = false
                self.message = "画中画没启动：请确认 设置 → 通用 → 画中画 → 自动开启画中画 已打开"
            }
        }
    }

    func startIfWanted() {
        guard !running, !starting else { return }
        guard QPSharedHistory.read().isWanted || UserDefaults.standard.bool(forKey: "qp.autoPiP") else { return }
        start()
    }

    func stop() {
        if let c = pipController, c.isPictureInPictureActive {
            c.stopPictureInPicture()
        } else {
            finish()
        }
    }

    /// v1.8.42：给快捷指令判活用的只读状态（running/starting 都是 private(set)/private，
    /// 不能直接从 MozhiIntents.swift 跨文件摸 starting，统一走这里）。
    var isActive: Bool { running || starting }

    /// v1.8.42：快捷指令「切换」的关闭分支专用，同步把状态彻底收干净。
    /// ★ 不能用 stop()：stopPictureInPicture() 只是【异步请求】，真正把 running /
    ///   pip / want / qp.autoPiP 全清掉靠 didStop 回调里的 finish()。而快捷指令
    ///   关闭后会立刻 openHostApp 跳回来源 App，App 一进后台 didStop 常常不派发
    ///   → finish() 不执行 → 状态仍是「在跑」，下次进 App 又被 startIfWanted
    ///   拉起来，表现在外面就是「切换的关闭没生效」（单独关闭走静默指令带
    ///   0.6s 强制补刀，所以一直是好使的）。
    ///   这里直接同步 finish()，并清掉前台可能排队的两条旧指令，避免刚关又被打开。
    func forceStopFromShortcut() {
        if let c = pipController, c.isPictureInPictureActive {
            c.stopPictureInPicture()
        }
        QPSharedHistory.clearPipStopCommand()
        _ = QPSharedHistory.consumePipCommand()   // 清掉旧的键盘切换指令，别把刚关的又打开
        finish()
    }

    /// 页面定时调用，把后台新收录的条数刷到界面上。
    /// v1.8.15：只刷新「被系统拦」状态与小窗显示，不再用历史总条数覆盖
    /// capturedCount（否则会话计数会被冲回历史数）。capturedCount 只在
    /// 本次会话内从 0 累加。
    func refreshCount() {
        blocked = QPSharedHistory.read().isBlocked
        contentVC?.update(blocked: blocked, count: capturedCount)
    }

    // MARK: - App 本地收录历史（v1.8.14）

    /// ★「永远 8 条」的根因与修复：手机端签名没有签 App Group entitlement，
    ///   共享通道退化为「剪贴板自定义类型兜底」——主 App 在后台读不到剪贴板时
    ///   既读不出也写不进，列表就永远停在最后一次前台写入时的条数
    ///   （用户实测：开启连续复制后列表一直 8 条、计数归零重算）。
    ///   修复 = 收录同时写主 App 自己的 UserDefaults（qp.app.pipHistory），
    ///   列表显示「本地 ∪ 共享」合并去重；删除用墓碑（qp.app.deletedMarks）
    ///   过滤，本地与共享两侧都立即隐藏。
    private struct LocalEntry: Codable {
        var t: String
        var ts: Double
    }

    private static func localHistory() -> [LocalEntry] {
        guard let data = UserDefaults.standard.data(forKey: "qp.app.pipHistory"),
              let arr = try? JSONDecoder().decode([LocalEntry].self, from: data) else { return [] }
        return arr
    }

    private static func saveLocal(_ arr: [LocalEntry]) {        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: "qp.app.pipHistory")
        }
    }

    /// 开启连续复制前清空之前的连续复制内容（受「开启前清空」开关控制）。
    /// 同时清主 App 本地历史（qp.app.pipHistory）与共享通道（QPSharedHistory），
    /// 共享通道在 Ad Hoc 下走剪贴板兜底但会保留真实剪贴板正文。
    static func clearContinuousHistory() {
        saveLocal([])
        QPSharedHistory.clearItemsKeepingClipboard()
    }

    /// 指纹：**用完整内容**。墓碑按指纹过滤，之前只取前 140 字，
    /// 两条长文本前 140 字相同会被误判成同一条 —— 删除一条把别的也删掉。
    /// 用完整内容后，删除精确命中选中的那一条，绝不会误删别的。
    static func fingerprint(_ text: String) -> String {
        text
    }

    static func deletedMarks() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "qp.app.deletedMarks") ?? [])
    }

    private static func saveDeletedMarks(_ s: Set<String>) {
        let capped = Array(s.prefix(500))
        UserDefaults.standard.set(capped, forKey: "qp.app.deletedMarks")
    }

    /// 收录一条进本地历史（PiP 抓到新文本时调用）。
    @discardableResult
    static func appendLocal(_ text: String) -> Bool {
        var arr = localHistory()
        if arr.first?.t == text { return false }
        arr.removeAll { $0.t == text }
        arr.insert(LocalEntry(t: text, ts: Date().timeIntervalSince1970), at: 0)
        if arr.count > 200 { arr = Array(arr.prefix(200)) }
        saveLocal(arr)
        return true
    }

    /// 合并视图：本地 ∪ 共享，去重（指纹，取时间较新者）、过滤墓碑、按时间倒序。
    /// 共享通道没有逐条时间戳：给递减伪时间保持「共享里靠前的条目靠上」。
    static func mergedItems() -> [(text: String, ts: Double)] {
        let marks = deletedMarks()
        var seen = Set<String>()
        var arr = localHistory().map { ($0.t, $0.ts) }
        var pseudo = Date().timeIntervalSince1970 - 1
        for t in QPSharedHistory.read().items {
            arr.append((t, pseudo))
            pseudo -= 1
        }
        var out: [(String, Double)] = []
        for (t, ts) in arr.sorted(by: { $0.1 > $1.1 }) {
            let fp = fingerprint(t)
            guard !marks.contains(fp), !seen.contains(fp) else { continue }
            seen.insert(fp)
            out.append((t, ts))
        }
        return out
    }

    /// 批量删除：写墓碑 + 从本地历史移除（共享通道无逐条删除 API，靠墓碑过滤）。
    static func deleteTexts(_ texts: [String]) {
        var marks = deletedMarks()
        for t in texts { marks.insert(fingerprint(t)) }
        saveDeletedMarks(marks)
        let fps = Set(texts.map { fingerprint($0) })
        saveLocal(localHistory().filter { !fps.contains(fingerprint($0.t)) })
    }

    // MARK: - 后台保活（音频 + audio 后台模式）

    /// ⚠️ 这里必须是**真的在出声**（哪怕人耳几乎听不见），不能是全零静音：
    /// 全零波形会被系统判成「静音播放」，App 照样在后台被挂起，
    /// 表现在外面就是小窗一直停在「已收录 N 条」不再变化。
    /// 但之前用 1kHz 正弦（人耳最敏感的频段）用户是能听见「滋——」的，
    /// 所以改成 20Hz 次低频：音频管线仍在输出、系统仍认「正在播放」，
    /// 而手机扬声器放不出 20Hz，人耳也基本听不到。首尾各 20ms 淡入淡出，循环点不咔哒。
    private func startAudioKeepAlive() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            message = "音频会话启动失败：\(error.localizedDescription)"
        }
        if silence == nil, let url = Self.toneFileURL() {
            silence = try? AVAudioPlayer(contentsOf: url)
            silence?.numberOfLoops = -1
            silence?.volume = 1.0
            silence?.prepareToPlay()
        }
        silence?.play()

        NotificationCenter.default.removeObserver(self,
                                                 name: AVAudioSession.interruptionNotification,
                                                 object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc private func audioInterrupted(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            silence?.play()
        }
    }

    private func stopAudioKeepAlive() {
        silence?.stop()
        silence = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: [.notifyOthersOnDeactivation])
    }

    private static func toneFileURL() -> URL? {
        let sampleRate = 44100
        let frames = sampleRate
        let dataSize = frames * 2
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        le32(16)
        le16(1)                              // PCM
        le16(1)                              // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * 2))         // byte rate
        le16(2)                              // block align
        le16(16)                             // bits
        d.append(contentsOf: Array("data".utf8))
        le32(UInt32(dataSize))

        var samples = Data(capacity: dataSize)
        // 20Hz、幅度 0.02：手机扬声器对 20Hz 基本没有有效输出，人耳也听不到，
        // 但波形非全零，系统仍判定「有音频在播放」，后台保活照样生效。
        let amp = 0.02
        let freq = 20.0
        let fade = Int(Double(sampleRate) * 0.02)          // 20ms 淡入淡出
        for i in 0..<frames {
            var gain = 1.0
            if i < fade { gain = Double(i) / Double(fade) }
            else if i >= frames - fade { gain = Double(frames - i) / Double(fade) }
            let v = Int16((sin(2.0 * Double.pi * freq * Double(i) / Double(sampleRate)) * amp * gain
                           * Double(Int16.max)).rounded())
            withUnsafeBytes(of: v.littleEndian) { samples.append(contentsOf: $0) }
        }
        d.append(samples)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qp-keepalive.wav")
        do {
            try d.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - 剪贴板监听（这才是「连续复制」的本体）

    /// 前台也开、后台也开：不依赖画中画是否已经起来。
    private func startMonitor() {
        monitor?.invalidate()
        lastChange = UIPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        monitor = t
        watchOnly = true
    }

    private func tick() {
        // ★ v1.8.33：键盘里点一下「就地关闭」写下的独立停止指令。
        //   tick() 只在连续复制跑着时才转，读到即清，天然一次性、天然幂等；
        //   不新增定时器、不新增轮询。★ 不看 applicationState：画中画运行时
        //   主 App 的前后台状态在系统版本间不确定，挡住会白白降级成跳转。
        //   与前台 toggle 指令的隔离由「独立文件 + 降级前 clear」保证。
        if QPSharedHistory.consumePipStopCommand() != nil {
            stopInPlaceFromKeyboard()
            return
        }
        // changeCount 读取不会弹授权框；只有内容真的变了才去读正文
        let pb = UIPasteboard.general
        let change = pb.changeCount
        if change != lastChange {
            lastChange = change
            readNow(pb: pb)
        }
        // 心跳：让键盘能判断「小窗还在、App 其实已经被挂起」
        if Date().timeIntervalSince(lastBeat) > 5 {
            lastBeat = Date()
            QPSharedHistory.beat()
        }
    }

    /// v1.8.33：后台真执行 stop()，不是只把共享标记写成 false 的「假关闭」。
    /// 正常路径：stopPictureInPicture() → didStop 回调 → finish() 写回
    /// setPip(false) / 清「下次自动开」/ 停定时器与音频保活 / 移除承载视图。
    /// ★ 后台是否派发 didStop 回调没有文档保证，所以 0.6 秒后若还 running
    ///   就再补一次 stop 并强制 finish()，保证键盘判活一定变假、图标一定恢复本色。
    private func stopInPlaceFromKeyboard() {
        if running || starting { stop() } else { finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            if self.running || self.starting {
                if let c = self.pipController, c.isPictureInPictureActive {
                    c.stopPictureInPicture()
                }
                self.finish()
            }
        }
    }

    private func readNow(pb: UIPasteboard) {
        guard pb.hasStrings else { return }
        guard let raw = pb.string else {
            // ★ 有关键字却读不到正文 = 被系统拦了。
            // 后台/前台都可能发生，只有「设置 → 墨指 → 从其他 App 粘贴 → 允许」能解。
            markBlocked()
            return
        }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 20000 else { return }
        // 纯电脑服务地址是配置项，不占剪贴板历史
        guard !(s.count <= 64 && s.hasPrefix("http") && s.contains(":8787")) else { return }
        // 读到正文 = 没被拦，立刻把红字撤掉
        if blocked || QPSharedHistory.read().isBlocked {
            blocked = false
            QPSharedHistory.setBlocked(false)
        }
        if QPSharedHistory.append(s) {
            Self.appendLocal(s)
            pushToPc(s)
            DispatchQueue.main.async {
                // 本次会话新收录一条 → 计数 +1（从 0 开始重新累加）
                self.capturedCount += 1
                self.contentVC?.update(blocked: false, count: self.capturedCount)
                self.message = "本次已收录 \(self.capturedCount) 条"
            }
        } else {
            // 同一条重复复制：正文一致，也算读到了，说明没被拦（计数不变）
            DispatchQueue.main.async {
                self.contentVC?.update(blocked: false, count: self.capturedCount)
            }
        }
    }

    /// 主 App 在后台（画中画）抓到的新内容，同样直接推给电脑。
    /// 键盘没弹出来的时候复制，电脑那边照样立刻能看到 —— 这才是「连续复制」的意义。
    private func pushToPc(_ text: String) {
        // v1.8.14「连接电脑」总开关（两端共用，权威状态在共享通道 syncOff）：
        // 主 App 设置页或键盘快捷菜单任一处断开，这里都不再自动推。
        guard !QPSharedHistory.syncOff() else { return }
        // v1.8.18 断网守卫：开关开着且手机没有 Wi-Fi（断网 / 只剩蜂窝）时不推，
        // 推了也连不上电脑，白白空跑请求。回 Wi-Fi 后新复制的内容自然恢复推送。
        if QPSharedHistory.netGuardOn() && !netWiFiOK { return }
        guard !pushedRecent.contains(text) else { return }
        pushedRecent.append(text)
        if pushedRecent.count > 30 { pushedRecent.removeFirst(pushedRecent.count - 30) }

        let d = UserDefaults.standard
        let url = d.string(forKey: "qp.syncURL")
            ?? d.string(forKey: "qp_server_url")
            ?? "http://192.168.1.2:8787"
        let pair = d.string(forKey: "qp.syncPair") ?? ""
        SyncClient(url: url, pair: pair).pushText(text) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                // 推失败（电脑没连上）：撤标记，下一条或下次启动再试
                self?.pushedRecent.removeAll { $0 == text }
            }
        }
    }

    private func markBlocked() {
        QPSharedHistory.setBlocked(true)
        DispatchQueue.main.async {
            self.blocked = true
            self.contentVC?.update(blocked: true, count: Self.mergedItems().count)
            self.message = "系统不让后台读剪贴板：设置 → 墨指 → 从其他 App 粘贴 → 允许"
        }
    }

    // MARK: - 收尾

    private func cleanup() {
        monitor?.invalidate()
        monitor = nil
        stopAudioKeepAlive()
        pipController?.delegate = nil
        pipController = nil
        contentVC = nil
        sourceView?.removeFromSuperview()
        sourceView = nil
        watchOnly = false
    }

    private func finish() {
        running = false
        starting = false
        QPSharedHistory.setPip(false)
        // 用户主动结束（点小窗 ✕ 或页面上点结束）→ 下次进 App 别自己又开起来
        QPSharedHistory.setWant(false)
        UserDefaults.standard.set(false, forKey: "qp.autoPiP")
        cleanup()
        message = "已结束连续复制"
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let w = scene?.windows.first(where: { $0.isKeyWindow }) { return w }
        return scene?.windows.first ?? UIApplication.shared.windows.first
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.starting = false
            self.running = true
            self.message = "监控中：切到任意 App 继续复制"
            QPSharedHistory.setPip(true)
            QPSharedHistory.setWant(true)
            UserDefaults.standard.set(true, forKey: "qp.autoPiP")
            // v1.8.15：画中画真正启动 = 本次会话开始，计数归零重新累加
            self.capturedCount = 0
            self.contentVC?.update(blocked: self.blocked, count: self.capturedCount)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { self.finish() }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.starting = false
            self.running = false
            QPSharedHistory.setPip(false)
            self.cleanup()
            let e = error as NSError
            self.message = "画中画启动失败（\(e.domain) \(e.code)）：\(e.localizedDescription)"
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

// MARK: - 主 App「连续复制」页

struct PiPControlView: View {
    @ObservedObject private var pip = PiPManager.shared
    /// 合并视图（本地 ∪ 共享、去重、墓碑过滤）——见 PiPManager.mergedItems()
    @State private var entries: [(text: String, ts: Double)] = PiPManager.mergedItems()
    /// 筛选：0 全部 / 1 文本 / 2 链接
    @State private var filterKind = 0
    /// 批量编辑：选择模式 + 已选集合（以原文为 id）
    @State private var editMode = false
    @State private var selection = Set<String>()
    /// 导出分享面板
    @State private var sharePayload: [Any]?
    @State private var notice = ""
    /// v1.8.32：用户设定的默认返回 App（iOS 26.4+ 拿不到宿主时的确定性兜底）
    @State private var defaultReturn: String = QPSharedHistory.defaultReturn() ?? "auto"
    /// v1.8.16：删除所选前必须二次确认，杜绝「一键清空全部」的误操作
    @State private var confirmDelete = false
    /// v1.8.38：「开启连续复制前清空之前的连续复制」开关（持久化到 UserDefaults）
    @AppStorage("qp.pipClearOnStart") private var clearBeforeStart = false
    /// v1.8.39：「开启连续复制前清空输入法前端剪贴板」开关（持久化到 UserDefaults）
    @AppStorage("qp.pipClearKbOnStart") private var clearKbOnStart = false

    /// 链接条目判断（与键盘侧 isLinkItem 同口径）
    private static func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.")
    }

    private var filtered: [(text: String, ts: Double)] {
        switch filterKind {
        case 1: return entries.filter { !Self.isLink($0.text) }
        case 2: return entries.filter { Self.isLink($0.text) }
        default: return entries
        }
    }

    private var filterName: String {
        ["全部", "文本", "链接"][filterKind]
    }

    // MARK: v1.8.42「哪条是刚复制的」——文字徽标 + 颜色 + 相对时间，三样一起给
    /// 包一层 Identifiable，避免 SwiftUI 里对元组用 keypath（Swift 不支持）。
    private struct RankedItem: Identifiable {
        let id: String
        let text: String
        let ts: Double
        let rank: Int
    }

    /// 列表本来就是「新 → 旧」，rank 0 就是本次（最近一次）复制。
    private var ranked: [RankedItem] {
        filtered.enumerated().map {
            RankedItem(id: $0.element.text, text: $0.element.text,
                       ts: $0.element.ts, rank: $0.offset)
        }
    }

    private func rankLabel(_ i: Int) -> String {
        switch i {
        case 0: return "本次"
        case 1: return "上次"
        case 2: return "上上次"
        default: return "第\(i + 1)条"
        }
    }

    private func timeLabel(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let d = Date().timeIntervalSince1970 - ts
        if d < 60 { return "刚刚" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(pip.running
                                      ? Color(red: 0.20, green: 0.78, blue: 0.35)
                                      : Color(red: 0.76, green: 0.76, blue: 0.78))
                                .frame(width: 12, height: 12)
                            Text(pip.running ? "连续复制中" : "未开启连续复制")
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Text("本次已收录 \(pip.capturedCount) 条")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                        }
                        Text(pip.running
                             ? "小窗在屏幕上就一直在抓：切到微信、Safari 复制，回来这里能看到每一条。"
                             : "开启后屏幕角落出现小窗，就代表正在后台监听剪贴板。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // v1.8.32：iOS 26.4 起 Apple 移除了键盘扩展识别宿主 App 的
                // 私有接口，自动返回不一定成功。给用户一个确定性兜底：
                // 设一个默认返回 App + 一个随时可按的「立即返回」按钮。
                Section("返回来源 App") {
                    Picker("默认返回 App", selection: $defaultReturn) {
                        ForEach(QPSharedHistory.returnChoices, id: \.id) { c in
                            Text(c.name).tag(c.scheme)
                        }
                    }
                    .onChange(of: defaultReturn) { v in
                        QPSharedHistory.setDefaultReturn(v)
                    }
                    Button {
                        let target = QPSharedHistory.cachedHostBundleId()
                            ?? QPSharedHistory.defaultReturnBundleId()
                            ?? ""
                        if target.isEmpty {
                            PiPManager.shared.note("还没识别出来源 App，也没设默认返回 App；请先在上面选一个")
                        } else {
                            AppRootView.openHostApp(target)
                        }
                    } label: {
                        Label("立即返回来源 App", systemImage: "arrow.uturn.backward")
                    }
                    Text("iOS 26.4 起系统不再告诉键盘「当前在哪个 App」，自动返回可能失败。设一个默认返回 App 就一定能跳回去；也可以点屏幕左上角系统状态栏的「返回 微信」等按钮。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if pip.blocked {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("系统拦住了后台读剪贴板", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundColor(.orange)
                            Text("必须在系统设置里把「从其他 App 粘贴」改成【允许】，"
                                 + "否则 App 在后台只能读到空内容 —— 这就是之前只收录一条的原因。")
                                .font(.subheadline)
                            Button {
                                Self.openAppSettings()
                            } label: {
                                Label("去系统设置允许粘贴", systemImage: "gearshape.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Button {
                        if pip.running { pip.stop() } else { pip.start() }
                    } label: {
                        HStack {
                            Spacer()
                            Label(pip.running ? "结束连续复制" : "开启连续复制",
                                  systemImage: pip.running ? "stop.circle.fill"
                                                           : "dot.radiowaves.left.and.right")
                                .font(.title3.weight(.semibold))
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(pip.running ? .red : .blue)

                    if !pip.message.isEmpty {
                        Text(pip.message)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("小窗就是系统画中画：可以拖到屏幕边框缩成小图标，点小窗上的 ✕ 结束。"
                         + "小窗消失 = 停止监听。")
                }

                // ── v1.8.38：开启连续复制前是否清空之前的连续复制 ──
                Section {
                    Toggle("开启前清空之前的连续复制", isOn: $clearBeforeStart)
                        .font(.body)
                    Text("打开后，每次点「开启连续复制」会先把之前攒下的连续复制内容清空，再从头开始收集；关闭则接着之前的继续叠加（默认关闭，沿用现在的行为）。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // ── v1.8.39：开启连续复制前是否清空输入法前端剪贴板 ──
                Section {
                    Toggle("开启前清空输入法前端剪贴板", isOn: $clearKbOnStart)
                        .font(.body)
                    Text("打开后，每次开启连续复制会一并把输入法（键盘）前端栏里之前攒的条目也清空——因为键盘前端和 App 共用同一条共享通道，不清这一份，键盘栏还会把旧条目搬回来。关掉则只清 App 端（默认关闭）。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // ── v1.8.14 收录列表：筛选 / 批量选择 / 删除 / 复制 / 导出 ──
                Section {
                    HStack(spacing: 16) {
                        Menu {
                            Picker("筛选", selection: $filterKind) {
                                Text("全部").tag(0)
                                Text("文本").tag(1)
                                Text("链接").tag(2)
                            }
                        } label: {
                            Label(filterName, systemImage: "line.3.horizontal.decrease.circle")
                        }
                        Menu {
                            exportButton("导出为 TXT", texts: { QPExport.txtFile($0) })
                            exportButton("导出为 CSV", texts: { QPExport.csvFile($0) })
                            exportButton("导出为 Excel(.xlsx)", texts: { QPExport.xlsxFile($0) })
                            exportButton("导出为 Word(.doc)", texts: { QPExport.wordFile($0) })
                            exportButton("导出为 PDF", texts: { QPExport.pdfFile($0) })
                            exportButton("导出为 HTML", texts: { QPExport.htmlFile($0) })
                            exportButton("导出为图片", texts: { QPExport.imageFile($0) })
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                        Button(editMode ? "完成" : "选择") {
                            editMode.toggle()
                            if !editMode { selection.removeAll() }
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.subheadline)

                    if editMode {
                        HStack(spacing: 16) {
                            // v1.8.19 修复：List 同一行里多个 Button 默认会整行共享点击，
                            // 点「全选」把三个动作全触发（全选→删除确认），表现成「全选=删除」。
                            // 必须显式 borderless，让点击只命中按到的那个按钮。
                            Button("全选") { selection = Set(filtered.map(\.text)) }
                                .buttonStyle(.borderless)
                            Button("复制所选") { copySelected() }
                                .buttonStyle(.borderless)
                            Button("删除所选", role: .destructive) { confirmDelete = true }
                                .buttonStyle(.borderless)
                                .disabled(selection.isEmpty)
                            Spacer()
                            Text("已选 \(selection.count) 条")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .font(.subheadline)
                    }
                    if !notice.isEmpty {
                        Text(notice).font(.footnote).foregroundColor(.blue)
                    }
                } footer: {
                    Text("「选择」后点条目勾选，可批量删除；导出范围 = 有选择时导出所选，否则导出当前筛选下的全部。「设置 → 局域网同步 → 导出到电脑」开着时导出文件直接发电脑（下载\\墨指导出），关着时走系统分享。主 App 历史只收文字，图片只在键盘端。")
                }

                Section("已收录 \(filtered.count) 条") {
                    if filtered.isEmpty {
                        Text("还没有收录。开启连续复制后，在别的 App 里复制的文字会出现在这里，也会出现在键盘的剪贴板列表里。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(ranked) { e in
                            Button {
                                if editMode {
                                    if selection.contains(e.text) {
                                        selection.remove(e.text)
                                    } else {
                                        selection.insert(e.text)
                                    }
                                } else {
                                    UIPasteboard.general.string = e.text
                                    MozhiFeedback.copied()   // v1.8.23：点一下就复制，给个触感确认
                                    // v1.8.22「复制后移到最前」（两端共用）：
                                    // 用了旧条目也排到最前，键盘里同步跟随。
                                    if QPSharedHistory.moveUsedToTopOn() {
                                        PiPManager.appendLocal(e.text)
                                        _ = QPSharedHistory.append(e.text)
                                        entries = PiPManager.mergedItems()
                                        flash("已复制，并移到最前（键盘同步）")
                                    } else {
                                        flash("已复制该条内容，去任何输入框粘贴即可")
                                    }
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    if editMode {
                                        Image(systemName: selection.contains(e.text)
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(.accentColor)
                                    }
                                    // v1.8.42：文字徽标 + 颜色一起标先后 ——
                                    // 本次=蓝底白字、上次=浅蓝、上上次及更早=灰。
                                    Text(rankLabel(e.rank))
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundColor(e.rank == 0 ? .white : (e.rank == 1 ? .blue : .secondary))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(
                                            e.rank == 0 ? Color.blue
                                                : (e.rank == 1 ? Color.blue.opacity(0.15)
                                                   : Color(UIColor.systemGray5))
                                        ))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(e.text)
                                            .lineLimit(2)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        if !timeLabel(e.ts).isEmpty {
                                            Text(timeLabel(e.ts))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text("\(e.text.count) 字")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                e.rank == 0 ? Color.blue.opacity(0.08)
                                            : Color(UIColor.secondarySystemGroupedBackground)
                            )
                        }
                    }
                }

                Section("收不到内容时按顺序检查") {
                    checkRow("1", "设置 → 墨指 → 从其他 App 粘贴 → 允许")
                    checkRow("2", "设置 → 通用 → 画中画 → 打开「自动开启画中画」")
                    checkRow("3", "小窗要一直在屏幕上；App 被划掉、小窗被点 ✕ 就停止监听了")
                }
            }
            .navigationTitle("连续复制")
            .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                entries = PiPManager.mergedItems()
                pip.refreshCount()
            }
            .onAppear { pip.startIfWanted() }
            .sheet(isPresented: Binding(
                get: { sharePayload != nil },
                set: { if !$0 { sharePayload = nil } })) {
                if let payload = sharePayload {
                    ActivityView(items: payload)
                }
            }
            .alert("确认删除所选？", isPresented: $confirmDelete) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) { deleteSelected() }
            } message: {
                Text("将永久删除选中的 \(selection.count) 条（仅本机主 App 列表；键盘端需单独清除）。此操作不可撤销。")
            }
        }
    }

    // MARK: 列表动作

    private func flash(_ msg: String) {
        notice = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { notice = "" }
    }

    /// 导出范围：有选择时导出所选，否则导出当前筛选下的全部
    private func exportTexts() -> [String] {
        let texts = selection.isEmpty
            ? filtered.map(\.text)
            : filtered.filter { selection.contains($0.text) }.map(\.text)
        return texts.isEmpty ? [""] : texts
    }

    private func exportButton(_ title: String,
                              texts: @escaping ([String]) -> URL?) -> some View {
        Button(title) {
            let t = exportTexts()
            if t == [""] { flash("没有可导出的内容"); return }
            guard let url = texts(t) else { flash("导出失败：文件生成出错"); return }
            // v1.8.20「导出到电脑」开关（两端共用）：开 → 文件直发电脑接收文件夹；
            // 关 → 系统分享面板（可转发微信、保存到「文件」等）。
            if QPSharedHistory.exportToPcOn() {
                sendToPc(url)
            } else {
                sharePayload = [url]
            }
        }
    }

    /// v1.8.20：把导出文件发到电脑（LocalSend 风格两步上传），落「下载\墨指导出」。
    private func sendToPc(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            flash("读取导出文件失败")
            return
        }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "txt": mime = "text/plain"
        case "csv": mime = "text/csv"
        case "html": mime = "text/html"
        case "pdf": mime = "application/pdf"
        case "doc": mime = "application/msword"
        case "xlsx": mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "png": mime = "image/png"
        default: mime = "application/octet-stream"
        }
        let d = UserDefaults.standard
        let addr = d.string(forKey: "qp.syncURL")
            ?? d.string(forKey: "qp_server_url")
            ?? "http://192.168.1.2:8787"
        let pair = d.string(forKey: "qp.syncPair") ?? ""
        flash("正在发送到电脑…")
        SyncClient(url: addr, pair: pair).sendFile(
            data, name: url.lastPathComponent, mime: mime) { err in
                DispatchQueue.main.async {
                    if let err = err {
                        self.flash("发送失败：\(err)")
                    } else {
                        self.flash("已发到电脑：\(url.lastPathComponent)（在电脑的 下载\\墨指导出 文件夹）")
                    }
                }
        }
    }

    private func copySelected() {
        let texts = selection.isEmpty ? filtered.map(\.text) : filtered.filter { selection.contains($0.text) }.map(\.text)
        guard !texts.isEmpty else { flash("没有可复制的内容"); return }
        UIPasteboard.general.string = texts.joined(separator: "\n\n————\n\n")
        MozhiFeedback.copied()
        flash("已复制 \(texts.count) 条到剪贴板，去任何输入框粘贴即可")
    }

    private func deleteSelected() {
        let texts = Array(selection)
        guard !texts.isEmpty else { return }
        let before = entries.count
        PiPManager.deleteTexts(texts)
        let after = PiPManager.mergedItems()
        entries = after
        selection.removeAll()
        let removed = before - after.count
        // v1.8.16 安全护栏：指纹已是完整文本，删除精确命中选中的条数；
        // 若实际移除数超过所选条数（异常），明确提示而非静默吞掉。
        if removed > texts.count {
            flash("⚠️ 删除异常：应删 \(texts.count) 条，实际移除 \(removed) 条，请检查")
        } else {
            flash("已删除 \(removed) 条（主 App 列表；键盘列表需在键盘里单独清）")
        }
    }

    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func checkRow(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text).font(.footnote).foregroundColor(.secondary)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - 系统分享面板（导出文件用）
//
// iPad（TARGETED_DEVICE_FAMILY 含 2）上 UIActivityViewController 必须
// 有 popover 锚点，否则 present 即崩：这里取 keyWindow 根视图中心兜底。

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let window = (UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first) {
            vc.popoverPresentationController?.sourceView = window
            vc.popoverPresentationController?.sourceRect =
                CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
        }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
