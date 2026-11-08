import Foundation
import UIKit
import AVFoundation
import AVKit
import SwiftUI
import Combine

/// 系统级画中画（PiP）连续复制。
///
/// 用户参考图里那个「连续复制中…」深色小窗，是 AVPictureInPictureController
/// 渲染的【系统】PiP 窗口：浮在 SpringBoard 层、自带 ✕ 关闭按钮、可以拖到
/// 屏幕边缘自动缩小贴边（用户给的第 4 张图）。这些交互全部由 iOS 提供，
/// 不需要、也不应该自己在键盘里画一个假浮层。
///
/// PiP 期间主 App 保持运行，于是可以持续监听系统剪贴板：切到微信、Safari
/// 等任意 App 复制的文字都会被收进 QPSharedHistory，回到键盘即可看到。
final class PiPManager: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {

    static let shared = PiPManager()

    @Published private(set) var running = false
    @Published private(set) var capturedCount = 0
    @Published private(set) var message = ""
    @Published private(set) var supported = AVPictureInPictureController.isPictureInPictureSupported()

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var monitor: Timer?
    private var lastChange: Int = -1

    private override init() { super.init() }

    // MARK: - 画面承载

    /// SwiftUI 预览框把自己的 UIView 交进来（进入「连续复制」页时调用）。
    func attach(host: UIView) {
        guard playerLayer == nil else { return }
        setupPlayer(in: host)
    }

    /// 从键盘 URL scheme 跳进来时，页面可能还没加载，直接在 keyWindow 上补一个承载层。
    private func ensureLayerInWindow() {
        guard playerLayer == nil else { return }
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow })
                ?? scene?.windows.first else { return }
        let host = UIView(frame: CGRect(x: 10, y: 10, width: 160, height: 90))
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        window.addSubview(host)
        setupPlayer(in: host)
    }

    private func setupPlayer(in host: UIView) {
        let layer = AVPlayerLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        layer.videoGravity = .resizeAspectFill
        layer.cornerRadius = 12
        layer.masksToBounds = true
        layer.backgroundColor = UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1).cgColor
        host.layer.addSublayer(layer)
        playerLayer = layer

        let url = Bundle.main.url(forResource: "pip", withExtension: "mp4")
            ?? Bundle.main.url(forResource: "pip", withExtension: "mp4",
                               subdirectory: "Resources")
        guard let videoURL = url else {
            message = "App 包里缺画中画画面 pip.mp4"
            return
        }
        let item = AVPlayerItem(url: videoURL)
        let queue = AVQueuePlayer(items: [item])
        queue.isMuted = true
        layer.player = queue
        player = queue
        // 循环播放静帧，PiP 小窗才能一直挂在那儿
        looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.play()
    }

    // MARK: - 启停

    func start() {
        guard supported else {
            message = "这台设备或系统版本不支持画中画"
            return
        }
        ensureLayerInWindow()
        guard playerLayer != nil else {
            message = "画中画画面还没准备好，请重进本页再点一次"
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            message = "音频会话启动失败：\(error.localizedDescription)"
        }
        if pipController == nil, let layer = playerLayer {
            pipController = AVPictureInPictureController(playerLayer: layer)
            pipController?.delegate = self
        }
        player?.play()
        capturedCount = QPSharedHistory.read().items.count
        message = "正在开启画中画…"
        // 等 playerItem 进入 readyToPlay，否则 startPictureInPicture 会直接失败
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, let c = self.pipController else { return }
            guard !c.isPictureInPictureActive else { return }
            c.startPictureInPicture()
        }
    }

    func stop() {
        pipController?.stopPictureInPicture()
        finish()
    }

    /// 页面定时调用，把 PiP 后台新收录的条数刷到界面上。
    func refreshCount() {
        capturedCount = QPSharedHistory.read().items.count
    }

    private func finish() {
        monitor?.invalidate()
        monitor = nil
        player?.pause()
        running = false
        QPSharedHistory.setPip(false)
        message = "已结束连续复制"
    }

    // MARK: - PiP 期间的系统剪贴板监听

    private func startMonitor() {
        monitor?.invalidate()
        lastChange = UIPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        monitor = t
    }

    private func tick() {
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
            DispatchQueue.main.async { self.capturedCount = n }
        }
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.running = true
            self.message = "监控中：切到任意 App 继续复制"
            QPSharedHistory.setPip(true)
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
            self.running = false
            QPSharedHistory.setPip(false)
            self.message = "画中画启动失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - SwiftUI 承载视图

struct PiPHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
        v.backgroundColor = UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
        v.layer.cornerRadius = 12
        v.clipsToBounds = true
        PiPManager.shared.attach(host: v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - 主 App「连续复制」页

struct PiPControlView: View {
    @ObservedObject private var pip = PiPManager.shared

    private var items: [String] { QPSharedHistory.read().items }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pip.running ? "● 监控中 · 连续复制中…" : "悬浮窗已关闭")
                            .font(.headline)
                            .foregroundColor(pip.running ? .green : .secondary)
                        Text("PiP 画中画小窗出现即表示正在后台监控，切回任意 App 继续复制。"
                           + "小窗可以拖到屏幕左边框自动缩小贴边；点小窗上的 ✕ 结束监控。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("画中画预览") {
                    HStack {
                        Spacer()
                        PiPHostView()
                            .frame(width: 160, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Button {
                        if pip.running { pip.stop() } else { pip.start() }
                    } label: {
                        Label(pip.running ? "结束连续复制" : "开启连续复制（画中画）",
                              systemImage: pip.running ? "stop.circle" : "play.rectangle")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    if !pip.message.isEmpty {
                        Text(pip.message).font(.footnote).foregroundColor(.secondary)
                    }
                    if !pip.supported {
                        Text("当前设备不支持系统画中画。键盘可见期间的连续复制仍然可用。")
                            .font(.footnote).foregroundColor(.orange)
                    }
                    Text("已收录 \(pip.capturedCount) 条")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section("最近捕获（\(items.count)）") {
                    if items.isEmpty {
                        Text("开启画中画后，在别的 App 里复制的文字会出现在这里，也会出现在键盘的剪贴板列表里。")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(items.prefix(20), id: \.self) { text in
                            Button {
                                UIPasteboard.general.string = text
                            } label: {
                                Text(text).lineLimit(2).font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("连续复制 · 画中画")
            .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
                // 刷新 PiP 在后台写入的内容（@Published 变化会带动列表重绘）
                pip.refreshCount()
            }
        }
    }
}
