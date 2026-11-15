import SwiftUI
import UIKit

// MARK: - 首次启动引导：一次性把两个必要权限讲清楚并落地
//
// 背景：之前装完第一次进 App 没有任何引导，于是「允许粘贴」的系统询问不会弹出来、
// 「是否自动跟踪（后台连续复制）」也没地方开。这里在首次启动时弹一个引导页，
// 把这两件事一次性办妥，之后不再出现。
//
//   · 权限 1「允许粘贴」：iOS 16+ 只要 App 读一次剪贴板就会弹系统询问框，
//     所以在引导页出现时主动读一次 UIPasteboard，把系统框唤出来，用户点「允许」即可。
//   · 权限 2「自动跟踪」：把 ns.autoPiP 置真，之后每次进 App 自动拉起画中画后台监听；
//     并立即 start() 一次，让用户当场看到小窗在跑。

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ns.autoPiP") private var autoTrack = false
    @State private var pastePrompted = false
    @State private var pastedNote = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("欢迎使用 粘鼠")
                            .font(.largeTitle.weight(.bold))
                        Text("连续复制：在任意 App 复制，内容自动收进列表，随时回看、批量复制、导出。不需要键盘扩展，靠系统画中画在后台常驻监听剪贴板。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // ── 权限 1：允许粘贴 ──
                    VStack(alignment: .leading, spacing: 10) {
                        Label("① 允许粘贴权限", systemImage: "doc.on.clipboard")
                            .font(.headline)
                        Text("粘鼠 要跨 App 读取你复制的内容，需要你在系统弹窗里点「允许」。下面按钮只是去触发一次系统询问；在跳出的系统框里选「允许」即可（之后也能在 设置 → 粘鼠 → 从其他 App 粘贴 里改）。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Button {
                            // 读一次剪贴板，触发系统「粘贴」授权框
                            _ = UIPasteboard.general.string
                            pastePrompted = true
                            pastedNote = "已触发系统询问，请在点出的系统弹窗里选择「允许」。"
                        } label: {
                            Label("触发粘贴授权询问", systemImage: "hand.tap.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        if pastePrompted {
                            Text(pastedNote)
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    .padding(14)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(14)

                    // ── 权限 2：自动跟踪 ──
                    VStack(alignment: .leading, spacing: 10) {
                        Label("② 自动跟踪（后台连续复制）", systemImage: "dot.radiowaves.left.and.right")
                            .font(.headline)
                        Toggle("进入 App 自动在后台连续复制", isOn: $autoTrack)
                            .font(.body)
                        Text("打开后：每次打开粘鼠会自动拉起画中画小窗，在后台持续监听剪贴板。关闭则只在你手动点「开启连续复制」时才工作。注意：后台监听还需要系统开启「通用 → 画中画 → 自动开启画中画」。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Button {
                            Self.openPiPSettings()
                        } label: {
                            Label("去系统设置开启画中画", systemImage: "gearshape")
                                .font(.footnote)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(14)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(14)

                    Spacer(minLength: 8)
                }
                .padding(20)
            }
            .navigationTitle("首次设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { finish() }
                }
            }
            // 引导页出现时主动读一次剪贴板，确保「允许粘贴」系统框一定弹出
            .onAppear {
                _ = UIPasteboard.general.string
                pastePrompted = true
            }
        }
    }

    private func finish() {
        if autoTrack {
            // ns.autoPiP 已由 @AppStorage 写入；这里立刻拉起一次，让用户看到在跑
            PiPManager.shared.start()
        }
        UserDefaults.standard.set(true, forKey: "ns.onboarded")
        dismiss()
    }

    private static func openPiPSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
