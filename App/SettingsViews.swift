import SwiftUI
import UIKit

/// 主 App 的 v1.6 设置与内容页（按 quickpaste-ios-prototype.html 的 PAGES 注册表）。
///
/// 与键盘扩展内的 KeyboardSettings.swift 是两套 UI：
///   · 键盘里那套是键盘扩展内部 UIView 面板（呼出键盘时直接能改设置）
///   · 这里是主 App 的 SwiftUI 页面，用 TabView 承载 历史 / 分类 / 设置
/// 两端共用 UserDefaults.standard 的键名前缀 qp.*，但 iOS 键盘扩展与主 App
/// 默认不共享容器（未用 App Groups），所以主 App 这里的「键盘设置」主要通过
/// 「复制配置到剪贴板 → 键盘读取」以及系统设置引导完成，不假装能直接改键盘状态。

// MARK: - 教程数据（主 App 版，与键盘内保持同样文案）

struct AppTutorial: Identifiable {
    let id: String
    let title: String
    let summary: String
    let sections: [(String, String)]
}

enum AppTutorials {
    static let all: [AppTutorial] = [
        AppTutorial(id: "keyboard", title: "启用键盘与发送",
                    summary: "系统设置 → 通用 → 键盘，添加 QuickPaste，并开启完全访问。",
                    sections: [
            ("首次启用", "1. 打开系统「设置」。\n2. 通用 → 键盘 → 键盘 → 添加新键盘。\n3. 选择 QuickPaste，开启「允许完全访问」。"),
            ("切换与插入", "在任意 App 点输入框，长按地球键选 QuickPaste。点记录或常用语即在光标处插入；顶部地球按钮可切下一个键盘。"),
            ("发送到电脑", "键盘底行蓝色「发送」= 发送消息（等同回车）。要发到电脑请长按「发送」，或从 ⋯ 菜单选「发送输入框文字 / 剪贴板文字 / 图片到电脑」。"),
            ("完全访问的用途", "键盘读取剪贴板、访问局域网同步服务与本机历史都需要它。密码框会强制使用系统键盘，属系统限制。")
        ]),
        AppTutorial(id: "history", title: "剪贴板历史",
                    summary: "复制文字后，打开 QuickPaste；点记录即可复用。",
                    sections: [
            ("保存文字", "在其他 App 复制文字后，切到 QuickPaste 键盘查看。开启「连续复制」后，每次呼出键盘会把系统剪贴板新文字收入历史。"),
            ("搜索与复制", "在键盘「剪贴板」页上下滚动查找。点记录直接插入输入框；长按可复制到剪贴板、发送到电脑、放大图片或删除。"),
            ("整理历史", "置顶内容优先显示且不受历史保留天数清理影响。删除的记录可在「最近删除」恢复。"),
            ("电脑同步记录", "电脑 Ctrl+C 的文字和截图约 1 秒后出现在键盘列表，💻 = 电脑复制，📱 = 手机发的，图片显示缩略图。")
        ]),
        AppTutorial(id: "category", title: "常用语与分类",
                    summary: "把常用回复放进分类，在键盘里点一下就输入。",
                    sections: [
            ("新建分类", "本版本用「置顶」代替分类分组，长按键盘里的条目可置顶。"),
            ("添加常用语", "在键盘「常用语」页长按菜单可编辑；也可在连续复制设置里把抓取内容存到常用语。"),
            ("在键盘中使用", "点顶部「常用语」Tab，点一条即可插入，连续点多条会依次插入。")
        ]),
        AppTutorial(id: "split", title: "拆分选词",
                    summary: "长按历史卡片拆分文字，按点击顺序拼成新句子。",
                    sections: [
            ("进入拆分", "在键盘剪贴板卡片上长按，选择拆分选词相关操作。"),
            ("依次点选", "按顺序点词块，选中的词依次拼进结果框；点错再点一次取消。"),
            ("插入结果", "点结果框右侧蓝色上箭头把句子插入输入框。")
        ]),
        AppTutorial(id: "continuous", title: "连续复制与悬浮窗",
                    summary: "点键盘工具条右二的方块按钮，变蓝即开启自动同步。",
                    sections: [
            ("先选保存位置", "键盘设置 → 连续复制，可选择「剪贴板历史」或「常用语」。"),
            ("开启连续复制", "1. 确认键盘已开启完全访问。\n2. 切到 QuickPaste 键盘。\n3. 点工具条 ⧉ 变蓝即开启。\n4. 切回其他 App 继续复制，回到键盘即可看到记录。"),
            ("iOS 限制", "iOS 不允许第三方键盘显示系统级悬浮窗或后台常驻服务，抓取发生在每次呼出键盘时，不是后台静默监控。")
        ]),
        AppTutorial(id: "calc", title: "键盘计算器",
                    summary: "点「计算」，算出结果后点「输入」。",
                    sections: [
            ("开始计算", "点键盘左下角「f(x) 计算」，用数字、括号和加减乘除输入算式，结果随输入更新。"),
            ("把结果用于消息", "有有效结果时点「输入」，仅把计算结果插入当前输入框，并清空算式。"),
            ("回到文字列表", "点「返回」退出计算器，适合快速计算金额、数量或比例。")
        ])
    ]
}

// MARK: - 主 App 根视图

struct AppRootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            // 连接 / 启用引导（原 ContentView，保留地址设置与完全访问引导）
            ContentView().tabItem { Label("连接", systemImage: "link") }.tag(0)
            HistoryView().tabItem { Label("历史", systemImage: "clock") }.tag(1)
            CategoryView().tabItem { Label("分类", systemImage: "folder") }.tag(2)
            PiPControlView().tabItem {
                Label("连续复制", systemImage: "rectangle.on.rectangle")
            }.tag(3)
            SettingsView().tabItem { Label("设置", systemImage: "gearshape") }.tag(4)
        }
        // 键盘里点「连续复制」按钮会打开 quickpaste://pip/start
        // 键盘扩展本身不能开画中画，所以键盘那边只负责「把 App 叫到前台」，
        // 真正的开启在这里做：进来就自动开，用户少点一次。
        .onOpenURL { url in
            guard url.host == "pip" || url.absoluteString.contains("pip") else { return }
            tab = 3
            QPSharedHistory.setWant(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                PiPManager.shared.start()
            }
        }
        .onAppear {
            // 键盘按过「连续复制」但没跳成功（系统禁止键盘开 App）时，
            // 用户手动点图标进来，一样自动把画中画开起来。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                PiPManager.shared.startIfWanted()
            }
        }
    }
}

// MARK: - 剪贴板历史（空态 / 有记录）

struct HistoryView: View {
    @AppStorage("qp.app.history") private var stored: String = ""
    @State private var draft = ""
    @State private var search = ""

    private var items: [String] {
        stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
    private var filtered: [String] {
        search.isEmpty ? items : items.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("记一条（仅主 App 预览用）", text: $draft)
                            .textInputAutocapitalization(.never)
                        Button("添加") {
                            guard !draft.isEmpty else { return }
                            var arr = items
                            arr.insert(draft, at: 0)
                            stored = arr.prefix(30).joined(separator: "\n")
                            draft = ""
                        }
                    }
                }
                if filtered.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.on.clipboard").font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("还没有记录")
                            Text("在别的 App 复制文字后，切到 QuickPaste 键盘即可看到同步内容与本机历史。")
                                .font(.footnote).foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                } else {
                    Section("历史记录（\(filtered.count)）") {
                        ForEach(filtered, id: \.self) { text in
                            Button {
                                UIPasteboard.general.string = text
                            } label: {
                                HStack {
                                    Image(systemName: "doc.on.clipboard").foregroundColor(.blue)
                                    Text(text).lineLimit(2).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "square.on.square").foregroundColor(.secondary)
                                }
                            }
                        }
                        .onDelete { idx in
                            var arr = items
                            let toRemove = Set(idx.map { filtered[$0] })
                            arr.removeAll { toRemove.contains($0) }
                            stored = arr.joined(separator: "\n")
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索历史")
            .navigationTitle("剪贴板历史")
        }
    }
}

// MARK: - 分类 / 常用语

struct CategoryView: View {
    @AppStorage("qp.app.phrases") private var stored: String = ""
    @State private var draft = ""

    private var defaultPhrases: [String] {
        ["好的，收到", "稍后回复你", "谢谢！", "地址：", "明天上午方便吗"]
    }
    private var items: [String] {
        let s = stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return s.isEmpty ? defaultPhrases : s
    }

    var body: some View {
        NavigationStack {
            List {
                Section("添加常用语") {
                    HStack {
                        TextField("输入一条常用回复", text: $draft)
                        Button("添加") {
                            guard !draft.isEmpty else { return }
                            var arr = items
                            arr.insert(draft, at: 0)
                            stored = arr.joined(separator: "\n")
                            draft = ""
                        }
                    }
                }
                Section("常用语（\(items.count)）") {
                    ForEach(items, id: \.self) { text in
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            HStack {
                                Text(text).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "square.on.square").foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in
                        var arr = items
                        let rm = Set(idx.map { items[$0] })
                        arr.removeAll { rm.contains($0) }
                        stored = arr.joined(separator: "\n")
                    }
                }
                Section {
                    Text("点一条即复制到系统剪贴板。在 QuickPaste 键盘的「常用语」Tab 里可直接点条目上屏。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("分类 · 常用语")
        }
    }
}

// MARK: - 设置首页

struct SettingsView: View {
    @AppStorage("qp_server_url") private var savedURL: String = ""
    @State private var draft = ""
    @State private var hint = ""
    @State private var testText = ""

    private static let defaultURL = "http://192.168.1.2:8787"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("QuickPaste v1.8.3 · 真·系统输入法", systemImage: "keyboard")
                            .font(.subheadline.weight(.semibold))
                        Text("按 HTML 最新版效果原生实现的系统键盘，不是网页、不是 WebView 壳、不是演示动画。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("使用") {
                    NavigationLink("局域网同步（CopyQ）") { SyncSettingsView() }
                    NavigationLink("键盘设置") { KbdSettingsView() }
                    NavigationLink("快捷符号") { SymSettingsView() }
                    NavigationLink("连续复制") { ContinuousView() }
                    NavigationLink("使用教程") { TutorialListView() }
                }

                Section("1. 连接电脑") {
                    TextField(Self.defaultURL, text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button {
                        let u = normalize(draft)
                        savedURL = u
                        draft = u
                        UIPasteboard.general.string = u
                        hint = "已保存并复制地址。切到 QuickPaste 键盘会自动采用；也可在键盘设置里点「用剪贴板里的电脑地址」。"
                    } label: {
                        Label("保存并复制地址到剪贴板", systemImage: "doc.on.clipboard")
                    }
                    if !savedURL.isEmpty {
                        Text("当前地址：\(savedURL)").font(.footnote).foregroundColor(.secondary)
                    }
                    if !hint.isEmpty { Text(hint).font(.footnote).foregroundColor(.blue) }
                    Text("电脑需启动 QuickPaste 同步服务，且手机与电脑连同一 WiFi。IP 变化后重新填一次即可。")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section("2. 启用键盘") {
                    Text("设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → QuickPaste\n然后点开 QuickPaste → 开启「允许完全访问」")
                        .font(.subheadline)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: { Label("打开本 App 的系统设置", systemImage: "gear") }
                }

                Section("3. 立即测试") {
                    TextField("在这里输入，切到 QuickPaste 键盘试功能", text: $testText)
                    Text("键盘里点卡片直接上屏；💻=电脑复制，📱=手机发的；图片显示缩略图；蓝色「发送」把输入框文字发回电脑。")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section("预览") {
                    NavigationLink("查看有记录的历史") { HistoryView() }
                    NavigationLink("重新播放引导页") { OnboardingView() }
                    NavigationLink("关于本版本") { AboutView() }
                }

                Section("关于签名") {
                    Text("本 IPA 内含键盘扩展（.appex），用爱思助手免费 Apple ID 7 天签名安装，到期需重签。密码框会强制使用系统键盘，属系统限制。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .onAppear { draft = savedURL.isEmpty ? Self.defaultURL : savedURL }
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

// MARK: - 设置详情：局域网同步

struct SyncSettingsView: View {
    @AppStorage("qp_server_url") private var savedURL: String = ""
    @AppStorage("qp.app.pair") private var pair: String = ""
    @State private var draft = ""
    @State private var status = "未检测"

    var body: some View {
        Form {
            Section("连接状态") {
                HStack { Text("状态"); Spacer(); Text(status).foregroundColor(.secondary) }
                Button("立即检测") { check() }
            }
            Section("电脑地址") {
                TextField("http://192.168.1.2:8787", text: $draft)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button("保存并复制到剪贴板") {
                    savedURL = draft
                    UIPasteboard.general.string = draft
                }
                Text("保存后切到 QuickPaste 键盘，在「设置 → 局域网同步」里点「用剪贴板里的电脑地址」即可采用。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("配对码（电脑端设了才填）") {
                TextField("可留空", text: $pair)
                Text("主 App 的配对码不会自动同步到键盘，请在键盘设置里也填一次。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("说明") {
                Text("数据只在你的局域网内传输，不经过公网。图片以 HTTP 二进制直传 /api/image，电脑端写入系统剪贴板真实图片，Ctrl+V 可直接粘贴。")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
        .navigationTitle("局域网同步（CopyQ）")
        .onAppear { draft = savedURL.isEmpty ? "http://192.168.1.2:8787" : savedURL }
    }

    private func check() {
        guard let url = URL(string: draft + "/api/status") else { status = "地址无效"; return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let d = data,
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    status = "已连接 · v" + String(describing: j["version"] ?? "?")
                } else { status = "连接失败：" + (error?.localizedDescription ?? "未知") }
            }
        }.resume()
    }
}

// MARK: - 设置详情：键盘设置

struct KbdSettingsView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink("使用教程") { TutorialListView() }
                NavigationLink("快捷符号") { SymSettingsView() }
                NavigationLink("连续复制") { ContinuousView() }
                NavigationLink("局域网同步（CopyQ）") { SyncSettingsView() }
            }
            Section("键盘开关位置") {
                Text("所有键盘开关都在【键盘内部】：切到 QuickPaste 键盘 → 点工具条「⋯」→ 设置 → 键盘设置。")
                    .font(.subheadline)
                Text("包含：悬浮窗关闭按钮、点击直接切换、显示新内容提示、显示清空按钮、空格滑动移光标、发送后自动收起、连续复制、键盘增高、列数、工具条对齐。")
                    .font(.footnote).foregroundColor(.secondary)
                Text("iOS 限制：主 App 与键盘扩展默认不共享设置容器，为避免 App Groups 让爱思免费签名变复杂，开关直接存在键盘里、在键盘里改，主 App 这页不重复造假开关。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("打开系统设置") {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: { Label("打开本 App 的系统设置", systemImage: "gear") }
                Text("进入 设置 → 通用 → 键盘 → QuickPaste → 允许完全访问；并把「从其他 App 粘贴」设为允许。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("如何启用键盘") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(["打开「设置」应用", "进入「通用」→「键盘」→「键盘」",
                                  "点击「添加新键盘…」", "选择「QuickPaste」",
                                  "点击「QuickPaste」并开启「允许完全访问」"].enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top) {
                            Text("\(i + 1).").fontWeight(.semibold)
                            Text(s)
                        }
                    }
                }
            }
            Section("使用说明") {
                Text("问：为什么每次复制都会出现「是否允许粘贴」？\n答：点「允许」即可，也可在系统设置里把「从其他 App 粘贴」设为允许。")
                Text("问：键盘里看不到同步记录？\n答：确认完全访问已开、电脑服务已启动、同一 WiFi、地址正确。")
            }
        }
        .navigationTitle("键盘设置")
    }
}

// MARK: - 设置详情：快捷符号

struct SymSettingsView: View {
    @AppStorage("qp.app.symbols") private var stored: String = ""
    @State private var draft = ""

    private var defaults: [String] { ["。", "，", "？", "！", "："] }
    private var symbols: [String] {
        let s = stored.split(separator: "\u{1F}").map(String.init).filter { !$0.isEmpty }
        return s.isEmpty ? defaults : s
    }

    var body: some View {
        Form {
            Section("当前符号（\(symbols.count)）") {
                ForEach(Array(symbols.enumerated()), id: \.offset) { i, s in
                    HStack {
                        Text("\(i + 1)").foregroundColor(.secondary).frame(width: 22)
                        Text(s).font(.title3)
                        Spacer()
                        Button { move(i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                        Button { move(i, 1) } label: { Image(systemName: "arrow.down") }.disabled(i == symbols.count - 1)
                        Button { remove(i) } label: { Image(systemName: "xmark").foregroundColor(.red) }
                            .disabled(symbols.count <= 1)
                    }.buttonStyle(.borderless)
                }
                HStack {
                    TextField("输入要添加的符号", text: $draft)
                    Button("添加") {
                        guard !draft.isEmpty else { return }
                        var a = symbols; a.append(String(draft.prefix(4)))
                        stored = a.joined(separator: "\u{1F}"); draft = ""
                    }
                }
            }
            Section("工具条显示数量") {
                Text("2 / 3 / 4 / 5 个，可在键盘「⋯ → 快捷符号」里设置。空间不足时自动收进「⋯」面板。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("工具条按钮对齐") {
                Text("键盘、地球、连续复制三个按钮可整体居左、居中或居右，在键盘「⋯ → 快捷符号」里切换。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section {
                Button("恢复默认符号") { stored = "" }
                Text("主 App 的符号列表仅作预览；真正生效的是键盘内的设置。可通过复制到剪贴板后在键盘里采用。")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
        .navigationTitle("快捷符号")
    }

    private func move(_ i: Int, _ d: Int) {
        var a = symbols
        guard i + d >= 0, i + d < a.count else { return }
        a.swapAt(i, i + d); stored = a.joined(separator: "\u{1F}")
    }
    private func remove(_ i: Int) {
        var a = symbols; a.remove(at: i); stored = a.joined(separator: "\u{1F}")
    }
}

// MARK: - 设置详情：连续复制

struct ContinuousView: View {
    var body: some View {
        Form {
            Section {
                Text("连续复制会在你复制新内容时自动保存。iOS 不允许第三方键盘后台常驻监控或显示系统级悬浮窗，QuickPaste 的实现是：每次呼出键盘时把系统剪贴板里的新文字收入历史。")
                    .font(.subheadline)
            }
            Section("如何开启") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 在任意 App 切换到 QuickPaste 键盘")
                    Text("2. 点工具条右二方块 ⧉，变蓝即开启自动同步")
                    Text("3. 切回其他 App 继续复制，回到键盘即可看到记录")
                }
                Text("也可在键盘「⋯ → 设置 → 连续复制」里打开「呼出时抓取剪贴板」开关。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("存储位置") {
                Text("键盘设置里可选「剪贴板历史」或「常用语」。相同文字会去重，置顶记录不受自动清理影响。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("补充说明") {
                Text("问：为什么有的内容没保存？\n答：iOS 只允许键盘在呼出期间读取剪贴板；系统粘贴授权、后台限制和复制速度都可能影响保存。")
                Text("问：能像悬浮窗那样一直监控吗？\n答：不能，这是 iOS 系统限制，不是本键盘没做。")
            }
        }
        .navigationTitle("连续复制")
    }
}

// MARK: - 教程列表 / 详情

struct TutorialListView: View {
    var body: some View {
        List(AppTutorials.all) { t in
            NavigationLink(t.title) { TutorialDetailView(tutorial: t) }
        }
        .navigationTitle("使用教程")
    }
}

struct TutorialDetailView: View {
    let tutorial: AppTutorial
    var body: some View {
        List {
            Section { Text(tutorial.summary).font(.subheadline) }
            ForEach(Array(tutorial.sections.enumerated()), id: \.offset) { i, s in
                Section("\(i + 1). \(s.0)") {
                    Text(s.1).font(.subheadline)
                }
            }
        }
        .navigationTitle(tutorial.title)
    }
}

// MARK: - 引导 / 关于

struct OnboardingView: View {
    var body: some View {
        List {
            Section("启用 QuickPaste") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(["安装后用爱思助手 / 手机端签名工具完成 7 天签名",
                                  "设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → QuickPaste",
                                  "点开 QuickPaste → 开启「允许完全访问」",
                                  "打开主 App，填电脑地址 http://192.168.1.2:8787 并保存",
                                  "在任意 App 输入框按地球仪切到 QuickPaste 即可使用"].enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top) { Text("\(i + 1).").fontWeight(.semibold); Text(s) }
                    }
                }
            }
            Section {
                Text("键盘里：点卡片直接上屏；💻 = 电脑复制，📱 = 手机发的；图片显示缩略图；蓝色「发送」把输入框文字发回电脑。")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
        .navigationTitle("启用引导")
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                Text("QuickPaste v1.8.3 · 真·系统输入法").font(.headline)
                Text("iOS：键盘扩展 .appex（com.apple.keyboard-service）")
                Text("安卓：系统输入法 InputMethodService")
            }
            Section("说明") {
                Text("界面按 quickpaste-ios-prototype.html v1.6 原型原生实现，无 WebView、无演示动画。")
                Text("数据只在你的局域网内传输，不经过公网。")
                Text("免费 Apple ID 签名 7 天到期后需重签，键盘内数据不会丢失。")
            }
        }
        .navigationTitle("关于")
    }
}
