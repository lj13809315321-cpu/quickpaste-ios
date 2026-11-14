import SwiftUI
import UIKit

// 与键盘扩展约定同一个 key：主 App 把配置作为自定义 item 追加到系统剪贴板，
// 键盘（开启「完全访问」）读取后写进自己的 UserDefaults 并移除该 item。
// 这样不需要 App Group entitlement —— 手机端重签工具通常不会保留自定义 entitlement。
private let kSettingsPBKey = "app.mulberry6323.mozhi.kbcfg"
private let kDiagPBKey = "app.mulberry6323.mozhi.kbdiag"
private let kPhrasesKey = "kb_custom_phrases"

struct ContentView: View {
    @AppStorage("kb_sound_on") private var soundOn = true
    @AppStorage("kb_haptic_on") private var hapticOn = true
    @AppStorage("kb_sound_vol") private var volume = 0.6

    @State private var syncTip = ""
    @State private var dictCheck = ""
    @State private var diagText = ""
    @State private var phrases: [String: String] = [:]
    @State private var newKey = ""
    @State private var newValue = ""

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

                Section {
                    ForEach(phrases.keys.sorted(), id: \.self) { k in
                        HStack {
                            Text(k)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.blue)
                            Text(phrases[k] ?? "")
                                .lineLimit(1)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                phrases.removeValue(forKey: k)
                                savePhrases()
                            } label: {
                                Image(systemName: "trash").foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("缩写 addr", text: $newKey)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .frame(maxWidth: 110)
                        TextField("完整内容 / 地址 / 话术", text: $newValue)
                        Button("添加") { addPhrase() }
                            .disabled(newKey.isEmpty || newValue.isEmpty)
                            .buttonStyle(.borderless)
                    }
                } header: {
                    Text("自定义短语")
                } footer: {
                    Text("在中文键盘里敲缩写即可一键上屏，也支持只打缩写前半段提示。适合地址、手机号、客服话术、邮箱签名。")
                }

                Section("状态") {
                    Text(dictCheck.isEmpty ? "检测中…" : dictCheck)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text(diagText.isEmpty ? "键盘启动状态：暂无记录" : "键盘启动状态：\(diagText)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("若键盘闪退，这里显示它最后走到的阶段（1:init → 2:ui-ready → 3:core → 4:extras），据此可快速定位。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("如何启用") {
                    Text("1. 用手机端签名工具导入未签名 IPA 并重签安装。")
                    Text("2. 打开 iPhone「设置 › 通用 › 键盘 › 键盘 › 添加新键盘」，选择本键盘。")
                    Text("3. 在同一页点进本键盘，打开「允许完全访问」（剪贴板与设置同步需要）。")
                    Text("4. 在任意输入框长按 🌐 切换到本键盘。")
                }

                Section("打字能力") {
                    Text("· 整句拼音智能切分，首位直接给长句；候选顺序随上文自动调整")
                    Text("· 词库自学习：选过的词自动靠前，退格改选后学得更快")
                    Text("· 容错纠错：邻键按错、漏键、多键、字母对调、平翘舌/前后鼻音")
                    Text("· 中文 9 键 / 中文 26 键 / 英文 / 数字 / 符号 / 剪贴板")
                    Text("· U 模式拆字（umumu→林）、V 模式（v123、vrq、v1+2*3）")
                    Text("· 按下即响应 + 按键音/震动，长按不丢键、连打不卡顿")
                }

                Section {
                    Text("词库全部内置、本地运行，不联网。键盘面板不放设置入口。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("九宫格拼音")
            .onAppear {
                loadPhrases()
                dictCheck = dictSelfCheck()
                diagText = readDiag()
                syncToKeyboard()
            }
        }
    }

    private func loadPhrases() {
        phrases = UserDefaults.standard.dictionary(forKey: kPhrasesKey) as? [String: String] ?? [:]
    }

    private func addPhrase() {
        let k = newKey.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !v.isEmpty else { return }
        phrases[k] = v
        newKey = ""; newValue = ""
        savePhrases()
    }

    private func savePhrases() {
        UserDefaults.standard.set(phrases, forKey: kPhrasesKey)
        syncToKeyboard()
    }

    /// 把当前设置同步给键盘扩展
    private func syncToKeyboard() {
        let cfg: [String: Any] = [
            "sound": soundOn,
            "haptic": hapticOn,
            "vol": Double(volume),
            "phrases": phrases,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: cfg) else { return }
        let pb = UIPasteboard.general
        // 去掉旧配置 item 和已读过的诊断 item，用户复制的内容原样保留在数组前面
        var items = pb.items.filter { $0[kSettingsPBKey] == nil && $0[kDiagPBKey] == nil }
        items.append([kSettingsPBKey: data])
        pb.items = items
        syncTip = "已同步，下次弹出键盘时生效。"
    }

    /// 读键盘扩展写回的启动里程碑（扩展与主 App 不共享 UserDefaults，走剪贴板独立 item）
    private func readDiag() -> String {
        var last = ""
        for item in UIPasteboard.general.items {
            if let s = item[kDiagPBKey] as? String { last = s }
            else if let d = item[kDiagPBKey] as? Data,
                    let s = String(data: d, encoding: .utf8) { last = s }
        }
        return last
    }

    /// 自检：确认词库确实打进了键盘扩展包，方便排查「打不了字」
    private func dictSelfCheck() -> String {
        let names = ["pinyin_chars", "pinyin_phrases", "pinyin_assoc",
                     "pinyin_char_freq", "pinyin_bigram", "pinyin_hot_words",
                     "pinyin_t9", "pinyin_english", "pinyin_abbr", "pinyin_flat", "cat_net"]
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
