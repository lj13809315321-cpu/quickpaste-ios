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
            ? "系统设置 → QuickPaste → 从其他 App 粘贴 → 允许"
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
///     「设置 → QuickPaste → 从其他 App 粘贴」设成【允许】。否则后台每次读
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

    private override init() {
        super.init()
        // App 是共享通道的唯一写入方，读不到时用内存里的记录继续累积
        QPSharedHistory.memoryFallback = true
    }

    // MARK: - 开启

    func start() {
        guard supported else {
            message = "这台设备或系统版本不支持画中画，无法跨 App 连续复制"
            return
        }
        guard !running, !starting else { return }
        guard let window = Self.keyWindow() else {
            message = "找不到 App 窗口，请退回首页再点一次"
            return
        }

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
        capturedCount = QPSharedHistory.read().items.count
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, let c = self.pipController else { return }
            c.startPictureInPicture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.starting, !self.running else { return }
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

    /// 页面定时调用，把后台新收录的条数刷到界面上
    func refreshCount() {
        let p = QPSharedHistory.read()
        capturedCount = p.items.count
        blocked = p.isBlocked
        contentVC?.update(blocked: blocked, count: capturedCount)
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

    private func readNow(pb: UIPasteboard) {
        guard pb.hasStrings else { return }
        guard let raw = pb.string else {
            // ★ 有关键字却读不到正文 = 被系统拦了。
            // 后台/前台都可能发生，只有「设置 → QuickPaste → 从其他 App 粘贴 → 允许」能解。
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
            pushToPc(s)
            let n = QPSharedHistory.read().items.count
            DispatchQueue.main.async {
                self.capturedCount = n
                self.contentVC?.update(blocked: false, count: n)
                self.message = "已收录 \(n) 条"
            }
        } else {
            // 同一条重复复制：正文一致，也算读到了，说明没被拦
            let n = QPSharedHistory.read().items.count
            DispatchQueue.main.async {
                self.capturedCount = n
                self.contentVC?.update(blocked: false, count: n)
            }
        }
    }

    /// 主 App 在后台（画中画）抓到的新内容，同样直接推给电脑。
    /// 键盘没弹出来的时候复制，电脑那边照样立刻能看到 —— 这才是「连续复制」的意义。
    private func pushToPc(_ text: String) {
        // v1.8.13「断开连接」（主 App 侧总开关）：关掉后画中画后台收录的
        // 内容也不再自动推给电脑；键盘侧开关独立存放在键盘进程里。
        let d0 = UserDefaults.standard
        guard (d0.object(forKey: "qp.app.syncEnabled") as? Bool) ?? true else { return }
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
            self.contentVC?.update(blocked: true, count: QPSharedHistory.read().items.count)
            self.message = "系统不让后台读剪贴板：设置 → QuickPaste → 从其他 App 粘贴 → 允许"
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
            self.capturedCount = QPSharedHistory.read().items.count
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
    @State private var items: [String] = QPSharedHistory.read().items

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
                            Text("已收录 \(pip.capturedCount) 条")
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

                Section("已收录 \(items.count) 条") {
                    if items.isEmpty {
                        Text("开启后，在别的 App 里复制的文字会出现在这里，"
                             + "也会出现在键盘的剪贴板列表里。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(items.prefix(20).enumerated()), id: \.offset) { pair in
                            Text(pair.element).lineLimit(2).font(.subheadline)
                        }
                    }
                }

                Section("收不到内容时按顺序检查") {
                    checkRow("1", "设置 → QuickPaste → 从其他 App 粘贴 → 允许")
                    checkRow("2", "设置 → 通用 → 画中画 → 打开「自动开启画中画」")
                    checkRow("3", "小窗要一直在屏幕上；App 被划掉、小窗被点 ✕ 就停止监听了")
                }
            }
            .navigationTitle("连续复制")
            .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                items = QPSharedHistory.read().items
                pip.refreshCount()
            }
            .onAppear { pip.startIfWanted() }
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
