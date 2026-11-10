import SwiftUI
import UIKit

/// 主 App：v1.6 同步输入法的启用引导 + 电脑地址设置。
///
/// 注意：这里不是网页、不是演示页。真正的界面是系统键盘扩展
/// MozhiKeyboard.appex（见 Keyboard/KeyboardViewController.swift）。
/// 本 App 只做：填电脑地址、把地址放进剪贴板供键盘读取、引导启用键盘与完全访问。
///
/// 为什么用剪贴板传地址：键盘扩展与主 App 默认不共享 UserDefaults，
/// 硬性要求 App Groups 会让手机端签名变复杂。键盘本来就需要「允许完全访问」
/// 才能联网，用它读一次剪贴板即可，零额外 entitlement。
struct ContentView: View {
    @AppStorage("qp_server_url") private var savedURL: String = ""
    @ObservedObject private var pip = PiPManager.shared
    @State private var draft = ""
    @State private var hint = ""
    @State private var testText = ""

    private static let defaultURL = "http://192.168.1.2:8787"

    var body: some View {
        NavigationStack {
            Form {
                // ★ 放在最上面：从键盘「连续复制」按钮叫过来的用户，
                //   一进来就能一键开，不用在几个页签里找。
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(pip.running
                                  ? Color(red: 0.20, green: 0.78, blue: 0.35)
                                  : Color(red: 0.78, green: 0.78, blue: 0.80))
                            .frame(width: 12, height: 12)
                        Text(pip.running ? "连续复制中" : "连续复制未开启")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text("\(pip.capturedCount) 条")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Button {
                        if pip.running { pip.stop() } else { pip.start() }
                    } label: {
                        Label(pip.running ? "结束连续复制" : "开启连续复制（后台自动收录复制内容）",
                              systemImage: pip.running ? "stop.circle.fill"
                                                       : "dot.radiowaves.left.and.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(pip.running ? .red : .blue)

                    if pip.blocked {
                        Label("系统不让后台读剪贴板，请把「从其他 App 粘贴」改成允许",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                    Button {
                        PiPControlView.openAppSettings()
                    } label: {
                        Label("打开本 App 的系统设置（允许粘贴 / 画中画）", systemImage: "gearshape")
                    }
                    .font(.subheadline)
                } header: {
                    Text("连续复制")
                } footer: {
                    Text("iOS 要求 App 在后台读剪贴板必须获得允许：设置 → 墨指 → "
                         + "从其他 App 粘贴 → 允许。不设成允许的话，后台只能读到空内容。")
                }

                Section("这是什么") {
                    Text("墨指 是一个真正的系统输入法，不是网页演示。\n"
                       + "在任何 App 的输入框切到「墨指」键盘，就能直接看到并粘贴电脑上复制的文字、截图，"
                       + "也能把手机上输入的内容发回电脑。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Section("1. 连接电脑") {
                    TextField("http://192.168.1.2:8787", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button {
                        let u = normalize(draft)
                        savedURL = u
                        draft = u
                        UIPasteboard.general.string = u
                        hint = "已保存并复制地址。切到 墨指 键盘时会自动读取；也可在键盘里长按 ⧉ →「用剪贴板里的电脑地址」。"
                    } label: {
                        Label("保存并复制地址到剪贴板", systemImage: "doc.on.clipboard")
                    }
                    if !savedURL.isEmpty {
                        Text("当前地址：\(savedURL)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if !hint.isEmpty {
                        Text(hint).font(.footnote).foregroundColor(.blue)
                    }
                    Text("电脑上要启动 墨指 同步服务，且 iPhone 与电脑连同一 WiFi。"
                       + "IP 由路由器分配，重连 WiFi 后可能变化；在电脑上打开 "
                       + "http://127.0.0.1:8787/api/status 可看 lanIPs。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("2. 启用键盘") {
                    Text("设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 墨指\n"
                       + "然后点开 墨指 → 打开「允许完全访问」")
                        .font(.subheadline)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("打开本 App 的系统设置", systemImage: "gear")
                    }
                    Text("「允许完全访问」是键盘联网访问局域网的前提；不开的话键盘会显示提示且无法同步。"
                       + "数据只在同一 WiFi 内传输，不经过公网。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("3. 立即测试") {
                    TextField("在这里输入，切到 墨指 键盘试功能", text: $testText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Text("键盘里：点卡片直接上屏；💻 = 电脑复制，📱 = 手机发的；图片显示缩略图，点开可复制；"
                       + "底行蓝色「发送」把输入框文字发回电脑；长按 ⧉ 打开菜单可发剪贴板文字/图片。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("连续复制与签名") {
                    Text("键盘工具条第三个按钮（⧉）点一下会叫起本 App 并自动开启系统画中画小窗："
                       + "小窗出现在屏幕上就代表正在后台监控，切到任意 App 复制都会收录，"
                       + "小窗可拖到屏幕边缘缩成图标，点 ✕ 结束。键盘可见期间本来就会实时抓取，"
                       + "不依赖画中画。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("小窗必须留着，App 被划掉就停止监听。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("本 IPA 是未签名包，用手机端签名工具导入，同时重签主 App 与键盘扩展即可安装。"
                       + "密码框等敏感输入系统会强制使用原生键盘，属系统限制。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("墨指 同步键盘")
        }
        .onAppear {
            draft = savedURL.isEmpty ? Self.defaultURL : savedURL
        }
    }

    private func normalize(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { u = Self.defaultURL }
        if !u.hasPrefix("http://") && !u.hasPrefix("https://") { u = "http://" + u }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }
}
