import SwiftUI
import UIKit

// 与键盘扩展约定同一个 key：主 App 把配置作为自定义 item 追加到系统剪贴板，
// 键盘（开启「完全访问」）读取后写进自己的 UserDefaults 并移除该 item。
// 这样不需要 App Group entitlement —— 手机端重签工具通常不会保留自定义 entitlement。
private let kSettingsPBKey = "app.mulberry6323.mozhi.kbcfg"

struct ContentView: View {
    @AppStorage("kb_sound_on") private var soundOn = true
    @AppStorage("kb_haptic_on") private var hapticOn = true
    @AppStorage("kb_sound_vol") private var volume = 0.6

    @State private var syncTip = ""
    @State private var dictCheck = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("按键音", isOn: $soundOn)
                        .onChange(of: soundOn) { _ in syncToKeyboard() }
                    Toggle("震动反馈", isOn: $hapticOn)
                        .onChange(of: hapticOn) { _ in syncToKeyboard() }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("按键音量  \(Int(volume * 100))%")
                        Slider(value: $volume, in: 0...1)
                            .onChange(of: volume) { _ in syncToKeyboard() }
                    }
                    if !syncTip.isEmpty {
                        Text(syncTip).font(.footnote).foregroundColor(.secondary)
                    }
                } header: {
                    Text("键盘设置")
                } footer: {
                    Text("改完直接切到任意输入框，键盘弹出时自动生效。设置通过剪贴板同步，不覆盖你复制的文字；需已开启「允许完全访问」。")
                }

                Section("状态") {
                    Text(dictCheck.isEmpty ? "检测中…" : dictCheck)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("如何启用") {
                    Text("1. 用手机端签名工具导入未签名 IPA 并重签安装。")
                    Text("2. 打开 iPhone「设置 › 通用 › 键盘 › 键盘 › 添加新键盘」，选择本键盘。")
                    Text("3. 在同一页点进本键盘，打开「允许完全访问」（剪贴板与设置同步需要）。")
                    Text("4. 在任意输入框长按 🌐 切换到本键盘。")
                }

                Section("功能") {
                    Text("· 中文 9 键（T9 拼音）/ 中文 26 键：点「中9 / 中26」互切")
                    Text("· 英文 26 键 / 数字 / 符号 / 剪贴板")
                    Text("· 长句拼音、超级简拼（nh→你好）、模糊音、中英混输")
                    Text("· 语境联想 + 个人词频学习 + 网络热词细胞词库")
                }

                Section {
                    Text("词库全部内置、本地运行，不联网。已去掉双拼功能，键盘面板不再放设置入口。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("九宫格拼音")
            .onAppear {
                dictCheck = dictSelfCheck()
                syncToKeyboard()
            }
        }
    }

    /// 把当前设置同步给键盘扩展
    private func syncToKeyboard() {
        let cfg: [String: Any] = [
            "sound": soundOn,
            "haptic": hapticOn,
            "vol": Double(volume),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: cfg) else { return }
        let pb = UIPasteboard.general
        // 去掉旧的配置 item，用户复制的内容原样保留在数组前面
        var items = pb.items.filter { $0[kSettingsPBKey] == nil }
        items.append([kSettingsPBKey: data])
        pb.items = items
        syncTip = "已同步，下次弹出键盘时生效。"
    }

    /// 自检：确认词库确实打进了键盘扩展包，方便排查「打不了字」
    private func dictSelfCheck() -> String {
        let names = ["pinyin_chars", "pinyin_phrases", "pinyin_assoc",
                     "pinyin_char_freq", "pinyin_bigram", "pinyin_hot_words", "cat_net"]
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let ext = Bundle(url: plugins.appendingPathComponent("PinyinKeyboardKeyboard.appex")) else {
            return "未找到键盘扩展包（请确认安装的是完整 IPA）"
        }
        let ok = names.filter { ext.url(forResource: $0, withExtension: "json") != nil }.count
        return ok == names.count
            ? "词库自检通过：\(ok)/\(names.count) 个字典都已打包"
            : "词库自检异常：仅 \(ok)/\(names.count) 个字典，请重装 IPA"
    }
}
