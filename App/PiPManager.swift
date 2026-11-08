import Foundation
import UIKit
import AVFoundation
import AVKit
import SwiftUI
import Combine

// MARK: - PiP 小窗里画什么（自定义界面，没有任何播放控件）

/// 用户参考图里那个「连续复制中… / Continuous copying…」深色小窗，
/// 用的是 iOS 的【视频通话画中画】：窗口内容由我们的 UIViewController 提供，
/// 系统只负责把窗口浮起来、给 ✕ 和返回按钮、支持拖到屏幕边缘缩成小图标。
///
/// 之前用 AVPlayerLayer 播一段静音视频，系统会把它当「视频播放器」，
/// 于是小窗上出现播放/暂停/快进 15 秒那一套控件（用户截图里的问题）。
final class QPPiPViewController: AVPictureInPictureVideoCallViewController {

    private let stack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subLabel = UILabel()
    private let countLabel = UILabel()

    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?
    private var scaledSize: CGFloat = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        iconView.image = UIImage(systemName: "doc.on.doc.fill")
        iconView.tintColor = UIColor(red: 0.36, green: 0.59, blue: 1.0, alpha: 1)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "连续复制中…"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.5

        subLabel.text = "Continuous copying…"
        subLabel.textColor = UIColor(white: 1, alpha: 0.55)
        subLabel.font = .systemFont(ofSize: 16, weight: .regular)
        subLabel.textAlignment = .center
        subLabel.numberOfLines = 1
        subLabel.adjustsFontSizeToFitWidth = true
        subLabel.minimumScaleFactor = 0.5

        countLabel.text = "已收录 0 条"
        countLabel.textColor = UIColor(white: 1, alpha: 0.42)
        countLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countLabel.textAlignment = .center

        let gap = UIView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.heightAnchor.constraint(equalToConstant: 2).isActive = true

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subLabel)
        stack.addArrangedSubview(gap)
        stack.addArrangedSubview(countLabel)

        let w = iconView.widthAnchor.constraint(equalToConstant: 52)
        let h = iconView.heightAnchor.constraint(equalToConstant: 52)
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
        // 小窗被拖到屏幕边缘会缩得很小，字号跟着窗口宽度等比缩
        let w = view.bounds.width
        guard w > 1 else { return }
        let s = max(0.26, min(1.0, w / 620))
        guard abs(s - scaledSize) > 0.04 else { return }
        scaledSize = s
        titleLabel.font = .systemFont(ofSize: 30 * s, weight: .bold)
        subLabel.font = .systemFont(ofSize: 16 * s, weight: .regular)
        countLabel.font = .systemFont(ofSize: 13 * s, weight: .medium)
        iconWidth?.constant = 52 * s
        iconHeight?.constant = 52 * s
        stack.spacing = max(1, 4 * s)
    }

    func update(count: Int) {
        countLabel.text = "已收录 \(count) 条"
    }
}

// MARK: - 连续复制管理器

/// 「连续复制」= 在任意 App 里复制，内容自动进剪贴板列表（不需要切回键盘）。
///
/// iOS 的现实约束：
///   · 键盘扩展只在被呼出时运行，收起就被挂起 —— 所以键盘自己做不到跨 App 常驻；
///   · 主 App 想留在后台，必须有合法的后台模式。这里用 系统画中画 + 静音音频
///     让 App 保持存活（这也是各类剪贴板/计时器 App 的做法）。
///
/// 于是分工：
///   PiP 在 → 主 App 活着 → 轮询系统剪贴板 → 写进 QPSharedHistory
///   键盘弹起 → 读 QPSharedHistory + 自己读剪贴板 → 合并显示
final class PiPManager: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {

    static let shared = PiPManager()

    @Published private(set) var running = false
    @Published private(set) var capturedCount = 0
    @Published private(set) var message = ""
    @Published private(set) var supported = AVPictureInPictureController.isPictureInPictureSupported()

    private var pipController: AVPictureInPictureController?
    private var contentVC: QPPiPViewController?
    private var sourceView: UIView?
    private var silence: AVAudioPlayer?
    private var monitor: Timer?
    private var lastChange = -1
    private var starting = false

    private override init() { super.init() }

    // MARK: - 开启

    func start() {
        guard supported else {
            message = "这台设备或系统版本不支持画中画，无法跨 App 连续复制"
            return
        }
        guard !running, !starting else { return }
        guard let window = Self.keyWindow() else {
            message = "找不到 App 窗口，请重进本页再点一次"
            return
        }

        starting = true
        message = "正在开启画中画…"

        // 承载视图必须真实挂在窗口上（不能 hidden、不能不加入层级、不能是零尺寸），
        // 否则 startPictureInPicture() 会静默失败 —— 这就是上一版「点了没反应」的原因。
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        host.backgroundColor = .clear
        host.alpha = 0.02
        host.isUserInteractionEnabled = false
        window.addSubview(host)
        sourceView = host

        let vc = QPPiPViewController()
        // iOS 16 起必须给出首选尺寸，否则 PiP 窗口算不出宽高比
        vc.preferredContentSize = CGSize(width: 640, height: 360)
        vc.update(count: QPSharedHistory.read().items.count)
        contentVC = vc

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: host,
            contentViewController: vc)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller

        startSilentAudio()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, let c = self.pipController else { return }
            c.startPictureInPicture()
            // 3 秒还没起来就判失败，别让界面一直卡在「正在开启」
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.starting, !self.running else { return }
                self.starting = false
                self.cleanup()
                self.message = "画中画没启动：请确认系统「设置 → 通用 → 画中画 → 自动开启画中画」已打开"
            }
        }
    }

    func stop() {
        if let c = pipController, c.isPictureInPictureActive {
            c.stopPictureInPicture()
        } else {
            finish()
        }
    }

    /// 页面定时调用，把 PiP 后台新收录的条数刷到界面上
    func refreshCount() {
        capturedCount = QPSharedHistory.read().items.count
        contentVC?.update(count: capturedCount)
    }

    // MARK: - 后台保活（静音音频 + audio 后台模式）

    private func startSilentAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            message = "音频会话启动失败：\(error.localizedDescription)"
        }
        if silence == nil, let url = Self.silenceFileURL() {
            silence = try? AVAudioPlayer(contentsOf: url)
            silence?.numberOfLoops = -1
            // 数据本身就是全零，音量给一点点只是为了不让系统判成「静音播放」而回收
            silence?.volume = 0.02
        }
        silence?.play()
    }

    private func stopSilentAudio() {
        silence?.stop()
        silence = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: [.notifyOthersOnDeactivation])
    }

    /// 现生成 1 秒单声道 16bit 全零 WAV，免得多带一个资源文件
    private static func silenceFileURL() -> URL? {
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
        d.append(Data(repeating: 0, count: dataSize))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qp-silence.wav")
        do {
            try d.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - PiP 期间监听系统剪贴板

    private func startMonitor() {
        monitor?.invalidate()
        lastChange = UIPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        monitor = t
    }

    private func tick() {
        // changeCount 读取不会弹授权框；只有内容真的变了才去读正文
        let change = UIPasteboard.general.changeCount
        guard change != lastChange else { return }
        lastChange = change

        guard let s = UIPasteboard.general.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, s.count < 20000 else { return }
        // 纯电脑服务地址是配置项，不占剪贴板历史
        guard !(s.count <= 64 && s.hasPrefix("http") && s.contains(":8787")) else { return }

        if QPSharedHistory.append(s) {
            let n = QPSharedHistory.read().items.count
            DispatchQueue.main.async {
                self.capturedCount = n
                self.contentVC?.update(count: n)
            }
        }
    }

    // MARK: - 收尾

    private func cleanup() {
        monitor?.invalidate()
        monitor = nil
        stopSilentAudio()
        pipController?.delegate = nil
        pipController = nil
        contentVC = nil
        sourceView?.removeFromSuperview()
        sourceView = nil
    }

    private func finish() {
        running = false
        starting = false
        QPSharedHistory.setPip(false)
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
            self.capturedCount = QPSharedHistory.read().items.count
            self.contentVC?.update(count: self.capturedCount)
            self.startMonitor()
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
        // 点小窗上的「返回 App」时把主界面唤回前台
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
                    HStack(spacing: 10) {
                        Circle()
                            .fill(pip.running
                                  ? Color(red: 0.20, green: 0.78, blue: 0.35)
                                  : Color(red: 0.76, green: 0.76, blue: 0.78))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pip.running ? "连续复制中…" : "未开启连续复制")
                                .font(.headline)
                            Text(pip.running
                                 ? "小窗已在屏幕上，切到微信、Safari 等任意 App 复制即可自动收录"
                                 : "开启后屏幕角落出现「连续复制中…」小窗，代表正在监听")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
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
                                .font(.headline)
                            Spacer()
                        }
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

                Section("已收录 \(pip.capturedCount) 条") {
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

                Section("收不到内容时检查") {
                    checkRow("1", "系统设置 → 通用 → 画中画 → 打开「自动开启画中画」")
                    checkRow("2", "设置 → QuickPaste → 从其他 App 粘贴 → 允许（否则后台每次读取都会问一次）")
                    checkRow("3", "小窗必须在屏幕上；App 被划掉、小窗被点掉就停止监听了")
                }
            }
            .navigationTitle("连续复制")
            .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                items = QPSharedHistory.read().items
                pip.refreshCount()
            }
        }
    }

    private func checkRow(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text).font(.footnote).foregroundColor(.secondary)
        }
        .padding(.vertical, 1)
    }
}
