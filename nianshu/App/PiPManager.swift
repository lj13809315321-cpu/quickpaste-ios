import Foundation
import UIKit
import AVFoundation
import AVKit
import SwiftUI
import Combine

// MARK: - PiP 小窗里画什么（自定义界面，没有任何播放控件）

/// 用户参考图里那个「连续复制中…」深色小窗，用的是 iOS 的【视频通话画中画】：
/// 窗口内容由我们的 UIViewController 提供，系统只负责把窗口浮起来、给 ✕ 按钮、
/// 支持拖到屏幕边缘缩成小图标。
///
/// 之前用 AVPlayerLayer 播静音视频，系统会把它当「视频播放器」，
/// 于是小窗上出现播放/暂停/快进 15 秒那一套控件。字号已按用户要求放大。
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

    /// 系统拦住了后台读剪贴板：小窗直接把解决办法喊出来。
    func update(blocked: Bool, count: Int) {
        self.blocked = blocked
        self.count = count
        countLabel.textColor = blocked
            ? UIColor(red: 1.0, green: 0.72, blue: 0.25, alpha: 1)
            : .white
        countLabel.text = blocked ? "需要允许粘贴" : "已收录 \(count) 条"
        subLabel.text = blocked
            ? "系统设置 → 粘鼠 → 从其他 App 粘贴 → 允许"
            : "Continuous copying…"
        if scaledSize > 0 { applyFonts(scaledSize) }
    }
}

// MARK: - 连续复制管理器

/// 「连续复制」= 在任意 App 里复制，内容自动进剪贴板列表（不需要切回键盘）。
///
/// iOS 的现实约束（这是「只收录一条」的真正原因）：
///   · 主 App 想留在后台，必须有合法的后台模式。这里用系统画中画 + 音频
///     让 App 保持存活；
///   · ★ 即使 App 活着，iOS 16 起也不许它随便读剪贴板：必须由用户把
///     「设置 → 粘鼠 → 从其他 App 粘贴」设成【允许】。否则后台每次读
///     都拿到 nil（前台会弹一次授权框，后台连框都不弹，直接给 nil）。
///     上一版就是只抓到第 1 条（那时 App 还在前台），之后永远是 nil，
///     于是小窗永远显示「已收录 1 条」。
///
/// 粘鼠是**单进程独立 App**（无键盘扩展），状态只有一个来源 PiPManager，
/// UI 用 @Published 直接绑，快捷意图也直接调 PiPManager.shared，
/// 不再有「写指令 → 后台 tick 消费」这一层。逻辑更少、更稳，也不污染用户剪贴板。
final class PiPManager: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {

    static let shared = PiPManager()

    /// message 是 private(set)，主 App 根视图用这个方法写一行状态提示。
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
    private var starting = false
    private var watchOnly = false

    private override init() {
        super.init()
    }

    // MARK: - 开启

    func start() { start(retry: 8) }

    /// App/快捷指令刚拉起时窗口可能还没挂上，导致画中画直接 -1001 失败。
    /// 这里窗口未就绪就稍等重试，就绪后再真正拉起；三种开启入口都走这套。
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

        let clearApp = UserDefaults.standard.bool(forKey: "ns.pipClearOnStart")
        if clearApp { Self.clearContinuousHistory() }

        starting = true
        message = "正在开启画中画…"

        // 先把监听跑起来：App 在前台时读取剪贴板是**不需要**额外授权的，
        // 所以用户此刻复制的东西能立刻进列表，也能顺便把「是否被系统拦」测出来。
        startMonitor()
        // 小窗起来后再试读一次：前台这次通常会弹「允许粘贴」，用户点允许就说明通了；
        // 点不允许就立刻把 blocked 亮出来，别让用户以为在抓。
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
        guard LocalStore.isWanted || UserDefaults.standard.bool(forKey: "ns.autoPiP") else { return }
        start()
    }

    func stop() {
        if let c = pipController, c.isPictureInPictureActive {
            c.stopPictureInPicture()
        } else {
            finish()
        }
    }

    /// 给快捷指令判活用的只读状态（running/starting 都是 private(set)，
    /// 不能直接从 NianshuIntents.swift 跨文件摸 starting，统一走这里）。
    var isActive: Bool { running || starting }

    /// 快捷指令「切换」的关闭分支专用，同步把状态彻底收干净。
    /// ★ 不能用 stop()：stopPictureInPicture() 只是【异步请求】，真正把 running /
    ///   want / ns.autoPiP 全清掉靠 didStop 回调里的 finish()。而快捷指令
    ///   关闭后会立刻 openHostApp 跳回来源 App，App 一进后台 didStop 常常不派发
    ///   → finish() 不执行 → 状态仍是「在跑」，下次进 App 又被 startIfWanted
    ///   拉起来，表现在外面就是「切换的关闭没生效」。
    ///   这里直接同步 finish()，避免刚关又被打开。
    func forceStopFromShortcut() {
        if let c = pipController, c.isPictureInPictureActive {
            c.stopPictureInPicture()
        }
        finish()
    }

    func refreshCount() {
        blocked = LocalStore.isBlocked
        contentVC?.update(blocked: blocked, count: capturedCount)
    }

    // MARK: - 本地收录历史（单进程，直接走 LocalStore）

    /// 开启连续复制前清空之前的连续复制内容（受「开启前清空」开关控制）。
    /// 同时清本地历史与轮次起点，新收的条目才是「本次」。
    static func clearContinuousHistory() {
        LocalStore.clearHistory()
        resetPipSessionStarts()
    }

    /// 合并视图（去重、墓碑过滤、按时间倒序）。
    static func mergedItems() -> [NSItem] {
        LocalStore.allItems()
    }

    /// v1.8.43「一轮连续复制算一次」——按开启轮次给条目标记
    /// 一次连续复制 = 画中画从起到停的这一轮。只记最近 3 轮的开启时刻，
    /// 靠每条的收录时间落在哪个区间来判轮次，不用给每条历史记录加字段。
    static func pipSessionStarts() -> [Double] { LocalStore.pipSessionStarts() }

    static func markPipSessionStart() { LocalStore.markPipSessionStart() }

    static func resetPipSessionStarts() { LocalStore.resetPipSessionStarts() }

    static func ensureSessionBaseline() { LocalStore.ensureSessionBaseline() }

    static func fingerprint(_ text: String) -> String { LocalStore.fingerprint(text) }

    static func deletedMarks() -> Set<String> { LocalStore.deletedMarks() }

    /// 收录一条进本地历史（PiP 抓到新文本时调用）。
    @discardableResult
    static func appendLocal(_ text: String) -> Bool { LocalStore.append(text) }

    /// 批量删除：写墓碑 + 从本地历史移除（id = 文本原文 或 「nsimg:哈希」）。
    static func deleteItems(_ ids: [String]) { LocalStore.delete(ids) }

    // MARK: - 后台保活（音频 + audio 后台模式）

    /// ⚠️ 这里必须是**真的在出声**（哪怕人耳几乎听不见），不能是全零静音：
    /// 全零波形会被系统判成「静音播放」，App 照样在后台被挂起。
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
            .appendingPathComponent("ns-keepalive.wav")
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
        // 单进程 App：没有键盘来发起指令，不需要消费任何停止/切换指令。
        let pb = UIPasteboard.general
        let change = pb.changeCount
        if change != lastChange {
            lastChange = change
            readNow(pb: pb)
        }
    }

    private func readNow(pb: UIPasteboard) {
        let hasText = pb.hasStrings
        let hasImage = pb.hasImages
        var newItems = 0
        // —— 文字：和原来一样收录（内容没变就跳过，防止轮询回环）——
        if hasText, let raw = pb.string {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, s.count < 20000 {
                if LocalStore.append(s) { newItems += 1 }
            }
        }
        // —— 图片：剪贴板里是图也一并收录（缩放/压缩/哈希去重都在 LocalStore 里做）——
        if hasImage, let img = pb.image {
            if LocalStore.appendImage(img) { newItems += 1 }
        }
        // —— 文件：源 App 把 PDF / HTML / RTF / 音视频 / 办公文档字节放进剪贴板时自动收
        //    （只认白名单 UTI、≤20MB、按内容哈希去重；只给 file-url 的格式抓不到，
        //     用户可在「文件」页用系统文件导入器导入）。
        newItems += FileStore.capture(from: pb)

        if newItems > 0 {
            // 读到内容 = 没被拦，立刻把红字撤掉
            if blocked || LocalStore.isBlocked {
                blocked = false
                LocalStore.isBlocked = false
            }
            DispatchQueue.main.async {
                self.capturedCount += newItems
                self.contentVC?.update(blocked: false, count: self.capturedCount)
                self.message = "本次已收录 \(self.capturedCount) 条"
            }
        } else {
            // 有内容却读不到正文/图 = 被系统拦了（常见于未授权「允许粘贴」）
            if (hasText && pb.string == nil) || (hasImage && pb.image == nil) {
                markBlocked()
            }
        }
    }

    private func markBlocked() {
        LocalStore.isBlocked = true
        DispatchQueue.main.async {
            self.blocked = true
            self.contentVC?.update(blocked: true, count: Self.mergedItems().count)
            self.message = "系统不让后台读剪贴板：设置 → 粘鼠 → 从其他 App 粘贴 → 允许"
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
        // 用户主动结束（点小窗 ✕ 或页面上点结束）→ 下次进 App 别自己又开起来
        LocalStore.isWanted = false
        UserDefaults.standard.set(false, forKey: "ns.autoPiP")
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
            LocalStore.isWanted = true
            UserDefaults.standard.set(true, forKey: "ns.autoPiP")
            self.capturedCount = 0
            self.contentVC?.update(blocked: self.blocked, count: self.capturedCount)
            Self.markPipSessionStart()
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
            LocalStore.isWanted = false
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
