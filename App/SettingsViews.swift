import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreFoundation

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
                    summary: "系统设置 → 通用 → 键盘，添加 墨指，并开启完全访问。",
                    sections: [
            ("首次启用", "1. 打开系统「设置」。\n2. 通用 → 键盘 → 键盘 → 添加新键盘。\n3. 选择 墨指，开启「允许完全访问」。"),
            ("切换与插入", "在任意 App 点输入框，长按地球键选 墨指。点记录或常用语即在光标处插入；顶部地球按钮可切下一个键盘。"),
            ("发送到电脑", "键盘底行蓝色「发送」= 发送消息（等同回车）。要发到电脑请长按「发送」键，在弹出的菜单里选「发送输入框文字 / 剪贴板文字 / 图片到电脑」。"),
            ("完全访问的用途", "键盘读取剪贴板、访问局域网同步服务与本机历史都需要它。密码框会强制使用系统键盘，属系统限制。")
        ]),
        AppTutorial(id: "history", title: "剪贴板历史",
                    summary: "复制文字后，打开 墨指；点记录即可复用。",
                    sections: [
            ("保存文字", "在其他 App 复制文字后，切到 墨指 键盘查看。开启「连续复制」后，每次呼出键盘会把系统剪贴板新文字收入历史。"),
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
                    summary: "打开主 App「连续复制」页点开启，或用键盘设置里的「键盘可见时自动抓取」开关。",
                    sections: [
            ("先选保存位置", "键盘设置 → 连续复制，可选择「剪贴板历史」或「常用语」。"),
            ("开启连续复制", "1. 确认键盘已开启完全访问。\n2. 轻点键盘工具条「连续复制」图标：跳到本页并自动开启，再轻点一次则关闭；也可在本页手动点「开启连续复制」/「结束连续复制」。\n3. 切回其他 App 继续复制，记录会持续增加。"),
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
    /// v1.8.29：图一那条跳转是「把已在后台的 App 激活」，
    /// 此时 onAppear 不触发，只有 scenePhase 会变 active —— 必须监听它。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            // v1.8.21：删掉整个「连接」页 —— 它的「1. 连接电脑 / 2. 启用键盘 /
            // 3. 立即测试」在下面的设置主表里各有一份，顶部那块「连续复制」
            // 又和独立的「连续复制」Tab 完全重复，整页属于重复版面。
            // 电脑地址、启用引导、系统设置入口全部统一收进「设置」。
            HistoryView().tabItem { Label("历史", systemImage: "clock") }.tag(0)
            CategoryView().tabItem { Label("分类", systemImage: "folder") }.tag(1)
            PiPControlView().tabItem {
                Label("连续复制", systemImage: "rectangle.on.rectangle")
            }.tag(2)
            SettingsView().tabItem { Label("设置", systemImage: "gearshape") }.tag(3)
        }
        // ★ v1.8.29：v1.8.27 的跳转链路（键盘四路径 + 工具条轻点 + 设置页
        //   SwiftUI Link）已由用户真机验证「能跳转」，**一行都不动**：
        //   键盘仍发 mozhi://tab/pip?from=keyboard-more，Link 仍发
        //   mozhi://tab/pip?from=keyboard-link。
        // ★ 图一真因：轻点能跳，但按 bundle id 拉起 App 时 URL 不投递，
        //   且 App 从后台被激活时根视图 onAppear 不会触发 —— v1.8.28 挂在
        //   onOpenURL / onAppear 的 start() 一次都没跑到，所以「没自动开」。
        //   图二 SwiftUI Link 由系统亲自投递 URL、App 完整前台，所以能开。
        //   本版改由共享通道带一次性「开/关指令」，主 App 在
        //   onOpenURL / onAppear / scenePhase active 三处任一处消费。
        //   旧 mozhi://pip/start 分支原样保留，仅作老链接兼容，不作为入口。
        // ★ v1.8.30：图一「按 bundle id 拉起」这条根本不投递 URL，
        //   上面 onOpenURL 的 tab=2 对它无效；切页与开关改由独立指令通道
        //   + UIKit 前台通知 + 前台轮询保证（见本结构末尾）。
        // ★ 不能用 absoluteString.contains("pip") 判定路径，按 host 分流。
        .onOpenURL { url in
            let host = url.host ?? ""
            if host == "pip" {
                tab = 2   // v1.8.22：删掉连接页后，连续复制从 tag 3 变 tag 2
                QPSharedHistory.setWant(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    PiPManager.shared.start()
                }
            } else if host == "tab", url.path.contains("pip") {
                tab = 2
                if !self.applyPendingPiPCommand(),
                   !url.absoluteString.contains("from=keyboard-more") {
                    // 设置页 SwiftUI Link：系统确实把 URL 送到了，
                    // 保持 v1.8.28 已验证成功的「进去就开」行为。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        PiPManager.shared.start()
                    }
                }
            }
        }
        .onAppear {
            let didToggle = self.applyPendingPiPCommand()
            // v1.8.26 兜底：跳被拦时手动点桌面图标也直达连续复制页。
            if QPSharedHistory.consumePendingTabPip() { tab = 2 }
            if !didToggle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    PiPManager.shared.startIfWanted()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { self.consumeKeyboardCommand() }
        }
        // ★ v1.8.30：图一按 bundle id 把 App 拉回前台时 URL 不投递、
        //   onOpenURL 不触发；若 App 只是被键盘盖住、没真正进过后台，
        //   onAppear 和 scenePhase 也都不会再触发 —— 三个回调可能全落空，
        //   这就是「一直停在历史页」的真因。再加 UIKit 前台通知 +
        //   前台 0.6 秒轮询两道保险；指令读到即清，重复调用天然幂等。
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            self.consumeKeyboardCommand()
        }
        .onReceive(Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()) { _ in
            guard scenePhase == .active else { return }
            self.consumeKeyboardCommand()
        }
    }

    /// v1.8.30：消费键盘写进「独立指令通道」的一次性命令。
    /// 不再读 Payload —— 主 App 的连续复制收录心跳会整份覆盖 Payload，
    /// 塞在里面的 pending 标记会被冲掉。切到连续复制页 + 按 running 开/关。
    /// 0.9s 等窗口就绪，1.8s 幂等补偿（冷启动首次可能拿不到 keyWindow）；
    /// 两次都按「期望状态」判断，不会把刚开的又关掉。
    private func applyPendingPiPCommand() -> Bool {
        guard let cmd = QPSharedHistory.consumePipCommand() else { return false }
        tab = 2
        let shouldRun = !PiPManager.shared.running
        for delay in [0.9, 1.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if shouldRun {
                    if !PiPManager.shared.running { PiPManager.shared.start() }
                } else {
                    if PiPManager.shared.running { PiPManager.shared.stop() }
                }
            }
        }
        // v1.8.31：在哪个 App 点开的，开/关完成后就自动跳回那个 App。
        // v1.8.32：iOS 26.4+ 系统不再给键盘宿主包名，识别不到时退到用户
        // 设定的「默认返回 App」；两者都没有才留在本页（页面上有按钮可手动回）。
        let host = (cmd.host?.isEmpty == false ? cmd.host : nil)
            ?? QPSharedHistory.defaultReturnBundleId()
        guard let target = host, !target.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                // 不管画中画有没有起来都给反馈，绝不出现「点了没反应」；
                // 开 / 关两条路径都会走到这里，所以文案只描述状态不受影响。
                PiPManager.shared.note("没识别出来源 App，可在本页「返回来源 App」选默认目标或点按钮返回；连续复制状态不受影响")
            }
            return true
        }
        if shouldRun {
            Self.jumpBackAfterPiP(host: target)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { Self.openHostApp(target) }
        }
        return true
    }

    /// 等画中画真正起来（running 由启动回调置真）再跳回，最多等 3 秒；
    /// 没起来就留在本页看系统提示，不假装「已开好并跳回」。
    private static func jumpBackAfterPiP(host: String, triesLeft: Int = 15) {
        if PiPManager.shared.running {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Self.openHostApp(host) }
            return
        }
        guard triesLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Self.jumpBackAfterPiP(host: host, triesLeft: triesLeft - 1)
        }
    }

    /// v1.8.32：跳回来源 App。
    /// ★ 顺序反过来：先用**公开 API** `UIApplication.shared.open(协议)`，
    ///   这是 iOS 上最可靠的一条（第三方输入法语音输入跳回宿主也走这条）；
    ///   1.0 秒后若还在前台，再用私有 `openApplicationWithBundleID:` 补一次。
    /// ★ v1.8.31 的两处错：把私有接口放在协议之前；而且只给键盘 plist
    ///   加了协议白名单，主 App 端 canOpenURL 一律 false —— 公开 API 被系统直接拒。
    static func openHostApp(_ host: String) {
        guard !host.isEmpty, host != "none" else { return }
        let scheme = MozhiHostResolver.scheme(for: host) ?? host
        if let url = URL(string: scheme), scheme.contains("://"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } else if !host.contains("://") {
            Self.openByBundleId(host)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard UIApplication.shared.applicationState == .active else { return }
            if !host.contains("://") {
                AppRootView.openByBundleId(host)
            } else if let url = URL(string: scheme) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard UIApplication.shared.applicationState == .active else { return }
                PiPManager.shared.note("没跳回来源 App（\(host)），可点本页「返回来源 App」按钮或状态栏系统返回；连续复制不受影响")
            }
        }
    }

    /// 私有接口按包名拉起（键盘侧同款，真机已验证能把主 App 拉起来）。
    /// 自用重签、不上架，无审核风险。
    static func openByBundleId(_ bundleId: String) {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let ws = cls.perform(NSSelectorFromString("defaultWorkspace"))?
                          .takeUnretainedValue() as? NSObject else { return }
        let sel = NSSelectorFromString("openApplicationWithBundleID:")
        if ws.responds(to: sel) { _ = ws.perform(sel, with: bundleId) }
    }

    /// 前台任一入口统一消费：独立开关指令 + 旧的「手动点桌面图标」切页兜底。
    private func consumeKeyboardCommand() {
        _ = applyPendingPiPCommand()
        if QPSharedHistory.consumePendingTabPip() { tab = 2 }
    }
}

// MARK: - 剪贴板历史（v1.8.21 接真实数据源 / v1.8.22 补齐选择·全选·导出）

struct HistoryView: View {
    /// v1.8.21 修复「历史页永远空白」：旧版读 `qp.app.history` 这个孤立本地键，
    /// 全工程只有「记一条（仅主 App 预览用）」会写，键盘和连续复制都不写它。
    /// 现在与「连续复制」Tab 一样读 PiPManager.mergedItems()：
    /// 主 App 本地收录 ∪ 跨进程共享通道，按时间倒序、去重、过滤删除墓碑。
    @State private var entries: [(text: String, ts: Double)] = PiPManager.mergedItems()
    @State private var draft = ""
    @State private var search = ""
    @State private var flashMsg = ""
    /// v1.8.22：把「连续复制」页的筛选 / 选择 / 全选 / 导出整套搬过来（同一份功能）
    @State private var filterKind = 0
    @State private var editMode = false
    @State private var selection = Set<String>()
    @State private var sharePayload: [Any]?
    @State private var confirmDelete = false
    @Environment(\.scenePhase) private var scenePhase

    private static func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.")
    }

    private var searched: [(text: String, ts: Double)] {
        search.isEmpty ? entries
                       : entries.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }
    private var filtered: [(text: String, ts: Double)] {
        switch filterKind {
        case 1: return searched.filter { !Self.isLink($0.text) }
        case 2: return searched.filter { Self.isLink($0.text) }
        default: return searched
        }
    }
    private var filterName: String { ["全部", "文本", "链接"][filterKind] }

    private func reload() { entries = PiPManager.mergedItems() }
    private func notice(_ s: String) {
        flashMsg = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { flashMsg = "" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("添加一条到历史（键盘里也能看到）", text: $draft)
                            .textInputAutocapitalization(.never)
                        Button("添加") {
                            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            PiPManager.appendLocal(t)
                            _ = QPSharedHistory.append(t)
                            draft = ""
                            reload()
                            notice("已添加，键盘与连续复制页同步可见")
                        }
                        .buttonStyle(.borderless)
                    }
                    if !flashMsg.isEmpty {
                        Text(flashMsg).font(.footnote).foregroundColor(.blue)
                    }
                } footer: {
                    Text("这一页显示的是与「连续复制」页完全同一份记录：主 App 后台收录的、键盘里复制的、画中画抓到的，都在这里。")
                }

                // ── v1.8.22 与「连续复制」页同款：筛选 / 导出 / 选择 ──
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
                            // v1.8.19 教训：List 同一行多个 Button 必须 borderless，
                            // 否则点「全选」会把复制/删除一起触发，变成「全选=全删」。
                            Button("全选") { selection = Set(filtered.map(\.text)) }
                                .buttonStyle(.borderless)
                            Button("复制所选") { copySelected() }
                                .buttonStyle(.borderless)
                            Button("删除所选", role: .destructive) { confirmDelete = true }
                                .buttonStyle(.borderless)
                                .disabled(selection.isEmpty)
                            Spacer()
                            Text("已选 \(selection.count) 条")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                        .font(.subheadline)
                    }
                } footer: {
                    Text("「选择」后点条目勾选，可全选、复制所选、删除所选（有二次确认）；导出范围 = 有选择时导出所选，否则导出当前筛选下的全部。「设置 → 局域网同步 → 导出到电脑」开着时文件直发电脑（下载\\墨指导出），关着时走系统分享。")
                }

                if filtered.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.on.clipboard").font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text(search.isEmpty ? "还没有记录" : "没有匹配的记录")
                            Text(search.isEmpty
                                 ? "在任意 App 复制文字后切到 墨指 键盘，或开启「连续复制」让 App 在后台收录，记录就会出现在这里。"
                                 : "换个关键词再试试。")
                                .font(.footnote).foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                } else {
                    Section("历史记录（\(filtered.count)）") {
                        ForEach(filtered, id: \.text) { item in
                            Button {
                                if editMode {
                                    if selection.contains(item.text) { selection.remove(item.text) }
                                    else { selection.insert(item.text) }
                                } else {
                                    UIPasteboard.general.string = item.text
                                    MozhiFeedback.copied()   // v1.8.23：复制成功轻震一下，别让人以为没复制上
                                    // v1.8.22「复制后移到最前」：两端共用开关，
                                    // 用了旧条目也把它排到列表最前，键盘里同样跟随。
                                    if QPSharedHistory.moveUsedToTopOn() {
                                        PiPManager.appendLocal(item.text)
                                        _ = QPSharedHistory.append(item.text)
                                        reload()
                                        notice("已复制到剪贴板，并移到最前")
                                    } else {
                                        notice("已复制到剪贴板")
                                    }
                                }
                            } label: {
                                HStack {
                                    if editMode {
                                        Image(systemName: selection.contains(item.text)
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(.accentColor)
                                    }
                                    Image(systemName: "doc.on.clipboard").foregroundColor(.blue)
                                    Text(item.text).lineLimit(2).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "square.on.square").foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .onDelete { idx in
                            let texts = idx.map { filtered[$0].text }
                            PiPManager.deleteTexts(texts)
                            reload()
                            notice("已删除 \(texts.count) 条")
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索历史")
            .navigationTitle("剪贴板历史")
            .onAppear { reload() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { reload() }
            }
            .sheet(isPresented: Binding(
                get: { sharePayload != nil },
                set: { if !$0 { sharePayload = nil } })) {
                if let payload = sharePayload { ActivityView(items: payload) }
            }
            .alert("确认删除所选？", isPresented: $confirmDelete) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) { deleteSelected() }
            } message: {
                Text("将永久删除选中的 \(selection.count) 条（仅本机主 App 列表；键盘端需单独清除）。此操作不可撤销。")
            }
        }
    }

    // MARK: 列表动作（与 PiPControlView 同一套实现）

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
            if t == [""] { notice("没有可导出的内容"); return }
            guard let url = texts(t) else { notice("导出失败：文件生成出错"); return }
            if QPSharedHistory.exportToPcOn() { sendToPc(url) }
            else { sharePayload = [url] }
        }
    }

    private func sendToPc(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { notice("读取导出文件失败"); return }
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
        notice("正在发送到电脑…")
        SyncClient(url: addr, pair: pair).sendFile(
            data, name: url.lastPathComponent, mime: mime) { err in
                DispatchQueue.main.async {
                    if let err = err { self.notice("发送失败：\(err)") }
                    else { self.notice("已发到电脑：\(url.lastPathComponent)（下载\\墨指导出）") }
                }
        }
    }

    private func copySelected() {
        let texts = selection.isEmpty
            ? filtered.map(\.text)
            : filtered.filter { selection.contains($0.text) }.map(\.text)
        guard !texts.isEmpty else { notice("没有可复制的内容"); return }
        UIPasteboard.general.string = texts.joined(separator: "\n\n————\n\n")
        MozhiFeedback.copied()
        notice("已复制 \(texts.count) 条到剪贴板")
    }

    private func deleteSelected() {
        let texts = Array(selection)
        guard !texts.isEmpty else { return }
        let before = entries.count
        PiPManager.deleteTexts(texts)
        reload()
        selection.removeAll()
        let removed = before - entries.count
        if removed > texts.count {
            notice("⚠️ 删除异常：应删 \(texts.count) 条，实际移除 \(removed) 条，请检查")
        } else {
            notice("已删除 \(removed) 条（主 App 列表；键盘列表需在键盘里单独清）")
        }
    }
}

// MARK: - 分类 / 常用语（v1.8.22：导入本地文件 + 与键盘工具栏共用同一份数据）

struct CategoryView: View {
    /// 用 JSON 数组字符串存，而不是换行拼接：单条常用语可以长达 20000 字节、
    /// 里面完全可能带换行，用 \n 分隔会把一条拆成好几条。
    @AppStorage("qp.app.phrases") private var stored: String = ""
    @State private var draft = ""
    @State private var search = ""
    @State private var notice = ""
    @State private var showImporter = false
    /// body 每次重算都会读 items，绝不能在里面去读 4MB 的共享通道 —— 会卡。
    /// 只在 onAppear / 改动后读一次，平时用内存数组。
    @State private var entries: [String] = []

    private var defaultPhrases: [String] {
        ["好的，收到", "稍后回复你", "谢谢！", "地址：", "明天上午方便吗"]
    }
    private var filtered: [String] {
        search.isEmpty ? entries : entries.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private static func decode(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        if let d = s.data(using: .utf8),
           let a = try? JSONDecoder().decode([String].self, from: d) { return a }
        // 兼容 v1.8.21 及更早的「换行拼接」老数据
        return s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
    private static func encode(_ a: [String]) -> String {
        guard let d = try? JSONEncoder().encode(a),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }

    private func reload() {
        let local = Self.decode(stored)
        if !local.isEmpty { entries = QPPhraseStore.sanitize(local); return }
        let shared = QPPhraseStore.read()
        entries = shared.isEmpty ? defaultPhrases : shared
    }

    /// 所有改动的唯一出口：本地存一份 + 写键盘独立通道，键盘工具条点开就是同一份。
    private func commit(_ arr: [String]) {
        let cleaned = QPPhraseStore.sanitize(arr)
        stored = Self.encode(cleaned)
        entries = cleaned
        _ = QPPhraseStore.write(cleaned)
    }

    private func flash(_ s: String) { notice = s }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 68)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25)))
                    Button("添加（可直接粘贴长文本）") {
                        guard !draft.isEmpty else { return }
                        var a = entries
                        a.insert(draft, at: 0)
                        commit(a)
                        draft = ""
                        flash("已添加并同步到键盘工具条的「常用语」")
                    }
                    .buttonStyle(.borderless)
                    if !notice.isEmpty {
                        Text(notice).font(.footnote).foregroundColor(.blue)
                    }
                } header: {
                    Text("添加常用语")
                } footer: {
                    Text("一条最长 20000 字节（约六千多个汉字），最多 200 条；超长会按字边界安全截断，不会切出半个汉字。列表用固定行高，长文本不会让键盘变卡。")
                }

                Section("导入 / 同步") {
                    Button {
                        showImporter = true
                    } label: {
                        Label("从手机本地文件导入（txt / csv）", systemImage: "doc.badge.plus")
                    }
                    Button {
                        _ = QPPhraseStore.write(entries)
                        flash("已同步：键盘工具条点「常用语」就能看到这 \(entries.count) 条")
                    } label: {
                        Label("立即同步到键盘", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Text("导入规则：每行一条（支持 UTF-8 / GBK 的 txt、csv），自动去空行、去重、截断到 200 条。导入后与主 App 这一页、键盘工具条的「常用语」浮层是同一份数据。")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section("容量") {
                    HStack {
                        Text("条数"); Spacer()
                        Text("\(entries.count) / \(QPPhraseStore.maxCount)").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("已用字节"); Spacer()
                        Text("\(QPPhraseStore.usedBytes(entries)) / 单条 \(QPPhraseStore.maxItemBytes)")
                            .foregroundColor(.secondary)
                    }
                    Text("200 条 × 单条 20000 字节约 4MB，保存时一次性写入，之后键盘只在点开浮层时读一次，不参与 0.5 秒剪贴板轮询。")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section {
                    ForEach(filtered, id: \.self) { text in
                        Button {
                            UIPasteboard.general.string = text
                            MozhiFeedback.copied()
                            flash("已复制这一条（\(text.utf8.count) 字节）")
                        } label: {
                            HStack {
                                // 只显示摘要：2 万字节的整段文本绝不参与列表布局计算
                                Text(String(text.prefix(80)))
                                    .lineLimit(2).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "square.on.square").foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .onDelete { idx in
                        let rm = Set(idx.map { filtered[$0] })
                        commit(entries.filter { !rm.contains($0) })
                        flash("已删除并同步到键盘")
                    }
                } header: {
                    Text("常用语（\(filtered.count)）")
                } footer: {
                    Text("点一条即复制到系统剪贴板；在 墨指 键盘工具条点「常用语」图标，可直接点条目上屏。")
                }
            }
            .searchable(text: $search, prompt: "搜索常用语")
            .navigationTitle("分类 · 常用语")
            .onAppear { reload() }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .commaSeparatedText, .data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else {
                        flash("导入失败：读不到文件内容"); return
                    }
                    let text = Self.decodeFile(data)
                    guard !text.isEmpty else { flash("导入失败：文件是空的或编码不支持"); return }
                    let lines = text
                        .replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    var merged = lines
                    merged.append(contentsOf: entries)
                    let before = entries.count
                    commit(merged)
                    let added = entries.count - before
                    flash("导入完成：新增 \(added) 条，当前共 \(entries.count) 条（上限 200 条 / 单条 20000 字节），已同步到键盘")
                case .failure(let e):
                    flash("导入失败：\(e.localizedDescription)")
                }
            }
        }
    }

    /// UTF-8 优先；Windows 记事本存出来的 GBK/GB18030 中文也能读。
    private static func decodeFile(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        // GB18030 的 NSStringEncoding 固定值（0x80000632），比依赖 CoreFoundation
        // 常量导入更稳；Windows 记事本另存的中文 txt 大多是这个编码。
        let gbk = String.Encoding(rawValue: 0x80000632)
        return String(data: data, encoding: gbk) ?? ""
    }
}

// MARK: - 设置首页

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("墨指 v1.8.35 · 真·系统输入法", systemImage: "keyboard")
                            .font(.subheadline.weight(.semibold))
                        Text("按 HTML 最新版效果原生实现的系统键盘，不是网页、不是 WebView 壳、不是演示动画。")
                            .font(.footnote).foregroundColor(.secondary)
                        // v1.8.21：原「连接」页独有的「这是什么」说明压成这一行
                        Text("墨指 是真正的系统输入法：在任何 App 的输入框切到「墨指」键盘，就能直接粘贴电脑上复制的文字与截图，也能把手机上输入的内容发回电脑。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("使用") {
                    NavigationLink("局域网同步（CopyQ）") { SyncSettingsView() }
                    NavigationLink("键盘设置") { KbdSettingsView() }
                    NavigationLink("快捷符号") { SymSettingsView() }
                    NavigationLink("定制工具栏") { BarCustomizeView(isToolbar: true) }
                    NavigationLink("定制菜单栏") { BarCustomizeView(isToolbar: false) }
                    NavigationLink("使用教程") { TutorialListView() }
                }

                Section("启用键盘 / 连接电脑") {
                    Text("设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 墨指 → 开启「允许完全访问」。打开系统设置的按钮在「键盘设置」页顶部（全工程只留这一个）。")
                        .font(.subheadline)
                    // v1.8.22：这页原来的「1. 连接电脑」地址输入框、「3. 立即测试」
                    // 与「局域网同步」详情页 / 底部 Tab 完全重复，已删掉。
                    // 电脑地址、配对码、连接开关、立即检测统一在「局域网同步」页设置。
                    Text("电脑地址、配对码、连接开关、状态检测，全部在「局域网同步（CopyQ）」这一页；本页不再重复放一套。")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section("预览") {
                    NavigationLink("剪贴板历史") { HistoryView() }
                    NavigationLink("重新播放引导页") { OnboardingView() }
                    NavigationLink("关于本版本") { AboutView() }
                }

                Section("关于签名") {
                    Text("本 IPA 内含键盘扩展（.appex），用爱思助手免费 Apple ID 7 天签名安装，到期需重签。密码框会强制使用系统键盘，属系统限制。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}

// MARK: - 设置详情：局域网同步

struct SyncSettingsView: View {
    @AppStorage("qp_server_url") private var savedURL: String = ""
    @AppStorage("qp.app.pair") private var pair: String = ""
    /// v1.8.14「连接电脑」总开关：两端共用共享通道字段（QPSharedHistory.syncOff），
    /// 键盘下次弹出时跟随这里的改动；键盘里改了，这里进页面时也会刷新。
    @State private var syncOn = !QPSharedHistory.syncOff()
    /// v1.8.18「断网自动暂停」开关：断开 Wi-Fi（或只剩流量）时停止同步轮询/推送，
    /// 回 Wi-Fi 自动恢复。两端共用（QPSharedHistory.netGuard）。
    @State private var netGuard = QPSharedHistory.netGuardOn()
    /// v1.8.20「导出到电脑」开关：开 = 主 App / 键盘的导出文件直接发送到电脑
    /// 「下载\墨指导出」文件夹；关 = 主 App 导出走系统分享（可转发微信等），
    /// 键盘文本导出复制到剪贴板。两端共用（QPSharedHistory.exportToPc）。
    @State private var exportToPc = QPSharedHistory.exportToPcOn()
    /// v1.8.22「复制后移到最前」：点一条旧记录使用后自动排到列表最前。
    @State private var moveUsedToTop = QPSharedHistory.moveUsedToTopOn()
    /// v1.8.23「复制成功震动」：两端共用开关，默认开。
    @State private var copyHaptic = QPSharedHistory.copyHapticOn()
    @State private var draft = ""
    @State private var status = "未检测"

    var body: some View {
        Form {
            Section("连接开关") {
                Toggle("连接电脑（两端共用）", isOn: $syncOn)
                    .onChange(of: syncOn) { on in
                        QPSharedHistory.setSyncOff(!on)
                    }
                Text("一个开关管两端：关掉后主 App 不再自动推送（含画中画后台收录），键盘也不再轮询拉取、不再自动推送——键盘下次弹出即生效；键盘里改了，回到这页也会刷新。\n断开后手机照常使用键盘，手动「立即检测 / 立即同步」仍可临时连一次。")
                    .font(.footnote).foregroundColor(.secondary)
                Toggle("断开 Wi-Fi 自动暂停同步（两端共用）", isOn: $netGuard)
                    .onChange(of: netGuard) { on in
                        QPSharedHistory.setNetGuard(on)
                    }
                Text("开着时：手机断开 Wi-Fi（断网或只剩流量）就自动停止同步轮询与推送，不再反复「连接中/失败」闪来闪去，也不浪费流量和电量；回到 Wi-Fi 自动恢复。关掉则断网也照常尝试连接。键盘设置里是同一个开关。")
                    .font(.footnote).foregroundColor(.secondary)
                Toggle("导出到电脑（两端共用）", isOn: $exportToPc)
                    .onChange(of: exportToPc) { on in
                        QPSharedHistory.setExportToPc(on)
                    }
                Text("开：导出文件直接发送到电脑的「下载\\墨指导出」文件夹（电脑端浏览器打开 http://127.0.0.1:8787/setup 可改接收位置）。关：主 App 导出走系统分享（可转发微信、保存到文件等），键盘的文本导出直接复制到剪贴板。键盘设置里是同一个开关。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("剪贴板行为（两端共用）") {
                Toggle("复制后移到最前", isOn: $moveUsedToTop)
                    .onChange(of: moveUsedToTop) { on in
                        QPSharedHistory.setMoveUsedToTop(on)
                    }
                Text("开着时：在历史页或连续复制页点一条旧记录复制，这条会自动排到列表最前，键盘里的剪贴板列表也跟着排到最前；关掉则列表顺序不变。系统里复制新内容一直都会排到最前，不受这个开关影响。键盘设置里是同一个开关。")
                    .font(.footnote).foregroundColor(.secondary)
                Toggle("复制成功震动", isOn: $copyHaptic)
                    .onChange(of: copyHaptic) { on in
                        QPSharedHistory.setCopyHaptic(on)
                    }
                Text("点条目后面的复制小图标、连续复制页点条目、复制所选、键盘长按菜单里的「复制」，成功后轻震一下，确认内容真的进了剪贴板。它和「按键震动」是两回事：那个管按下按键的手感，这个管复制结果。键盘设置里是同一个开关，默认开。")
                    .font(.footnote).foregroundColor(.secondary)
            }
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
                    MozhiFeedback.copied()
                }
                Text("保存后切到 墨指 键盘，在「设置 → 局域网同步」里点「用剪贴板里的电脑地址」即可采用。")
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
        .onAppear {
            draft = savedURL.isEmpty ? "http://192.168.1.2:8787" : savedURL
            syncOn = !QPSharedHistory.syncOff()   // 键盘端改过开关 → 进页面刷新
            netGuard = QPSharedHistory.netGuardOn() // v1.8.18：同上
            exportToPc = QPSharedHistory.exportToPcOn() // v1.8.20：同上
            moveUsedToTop = QPSharedHistory.moveUsedToTopOn() // v1.8.22：同上
            copyHaptic = QPSharedHistory.copyHapticOn()       // v1.8.23：同上
        }
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
    @State private var keySound = true
    var body: some View {
        Form {
            Section("声音与反馈") {
                Toggle("按键声音", isOn: $keySound)
                    .onChange(of: keySound) { v in _ = QPSharedHistory.setKeySound(v) }
                Text("按下任意按键播放系统键盘点击音，跟随系统「键盘反馈 → 声音」与静音键；关掉后只保留震动。键盘内「设置 → 键盘设置」里是同一个开关。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            // v1.8.21：全工程唯一的系统设置入口，放在「设置 → 键盘设置」页顶部。
            // 原「连接」页两处 + 设置主表一处已全部删掉，不再四处重复。
            Section("打开系统设置") {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: { Label("打开本 App 的系统设置", systemImage: "gear") }
                Text("进入 设置 → 通用 → 键盘 → 墨指 → 允许完全访问；并把「从其他 App 粘贴」设为允许（后台连续复制需要）。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            // v1.8.22：删掉这里重复的第二套「使用教程 / 快捷符号 / 连续复制 /
            // 局域网同步」入口 —— 设置主表里已经各有一份，点开「键盘设置」又看到
            // 一模一样的四个入口就是用户说的「版面重复」。
            Section("键盘开关位置") {
                Text("所有键盘本地开关都在【键盘内部】：切到 墨指 键盘 → 长按工具条「连续复制」图标 → 设置 → 键盘设置。")
                    .font(.subheadline)
                Text("包含：悬浮窗关闭按钮、点击直接切换、显示新内容提示、显示清空按钮、空格滑动移光标、发送后自动收起、连续复制、复制后移到最前、键盘增高、列数、工具条对齐。")
                    .font(.footnote).foregroundColor(.secondary)
                Text("「连接电脑 / 断网自动暂停 / 导出到电脑 / 复制后移到最前」和「快捷符号」是两端共用一份：在设置 → 局域网同步 / 快捷符号里改，键盘下次弹出即跟随；在键盘里改，回到 App 也会刷新。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("如何启用键盘") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(["打开「设置」应用", "进入「通用」→「键盘」→「键盘」",
                                  "点击「添加新键盘…」", "选择「墨指」",
                                  "点击「墨指」并开启「允许完全访问」"].enumerated()), id: \.offset) { i, s in
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
        .onAppear { keySound = QPSharedHistory.keySoundOn() }
    }
}

// MARK: - 设置详情：快捷符号（v1.8.22：App 里改的真的会同步到键盘）

struct SymSettingsView: View {
    @AppStorage("qp.app.symbols") private var stored: String = ""
    @AppStorage("qp.app.symbolsAt") private var localAt: Double = 0
    @State private var draft = ""
    @State private var showCount = 4
    @State private var align = "left"

    /// v1.8.22：默认符号表补全（以前只有 5 个标点，用户说「没弄全」）
    private var defaults: [String] {
        ["。", "，", "？", "！", "：", "；", "、", "…", "～", "「", "」", "（", "）", "·", "—"]
    }
    private var symbols: [String] {
        let s = stored.split(separator: "\u{1F}").map(String.init).filter { !$0.isEmpty }
        return s.isEmpty ? defaults : s
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(symbols.enumerated()), id: \.offset) { i, s in
                    HStack {
                        Text("\(i + 1)").foregroundColor(.secondary).frame(width: 22)
                        Text(s).font(.title3)
                        Spacer()
                        if i < showCount {
                            Text("工具条").font(.caption2).foregroundColor(.blue)
                        }
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
                        commit(a); draft = ""
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("当前符号（\(symbols.count)）")
            } footer: {
                Text("排在前面的优先显示在工具条；点符号可直接在光标处插入。")
            }
            Section("工具条显示数量") {
                Picker("显示几个", selection: $showCount) {
                    Text("2 个").tag(2); Text("3 个").tag(3)
                    Text("4 个").tag(4); Text("5 个").tag(5)
                }
                .pickerStyle(.segmented)
                .onChange(of: showCount) { _ in syncToKeyboard() }
                Text("最少 2 个、最多 5 个；空间不足时后面的可在符号区左右滑动查看。这一项以前只是文字说明，现在能真正设置了。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section("工具条按钮对齐") {
                Picker("对齐方式", selection: $align) {
                    Text("居左").tag("left"); Text("居中").tag("center"); Text("居右").tag("right")
                }
                .pickerStyle(.segmented)
                .onChange(of: align) { _ in syncToKeyboard() }
            }
            Section {
                Button("恢复默认符号") {
                    commit(defaults); showCount = 4; align = "left"
                    syncToKeyboard()
                }
                Button("立即同步到键盘") {
                    syncToKeyboard()
                }
                Text("这里和键盘「长按连续复制图标 → 快捷符号」是同一份设置：任一端改了，另一端下次出现时跟随。改完键盘下次弹出即生效；如果键盘正开着，点一下上面的「立即同步到键盘」。")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
        .navigationTitle("快捷符号")
        .onAppear {
            let s = QPSharedHistory.sharedSymbolSettings()
            // 键盘里改过（时间戳更新）→ 采用键盘那一份，别拿 App 的旧值盖回去
            if s.at > localAt, !s.symbols.isEmpty {
                stored = s.symbols.joined(separator: "\u{1F}")
                localAt = s.at
            }
            showCount = min(max(s.count, 2), 5)
            align = ["left", "center", "right"].contains(s.align) ? s.align : "left"
        }
    }

    private func commit(_ a: [String]) {
        stored = a.joined(separator: "\u{1F}")
        syncToKeyboard()
    }

    /// 写共享通道：键盘 refreshSymbols 会读到（时间戳比本地新就采用）。
    private func syncToKeyboard() {
        localAt = QPSharedHistory.setSharedSymbols(symbols, count: showCount, align: align)
    }

    private func move(_ i: Int, _ d: Int) {
        var a = symbols
        guard i + d >= 0, i + d < a.count else { return }
        a.swapAt(i, i + d); commit(a)
    }
    private func remove(_ i: Int) {
        var a = symbols; a.remove(at: i); commit(a)
    }
}

// MARK: - 设置详情：定制工具栏 / 定制菜单栏（v1.8.35）

/// 两栏共用同一个功能池：可增删、拖动排序、把一项从工具栏挪到菜单栏（或反过来）。
/// 写入 QPSharedHistory 共享通道，键盘下次弹出即生效 —— 与「快捷符号」同一套机制。
struct BarCustomizeView: View {
    let isToolbar: Bool

    @AppStorage("qp.app.barToolbar") private var tbStored: String = ""
    @AppStorage("qp.app.barMenu") private var mnStored: String = ""
    @State private var toolbar: [String] = QPBarCatalog.defaultToolbar
    @State private var menu: [String] = QPBarCatalog.defaultMenu
    @State private var editMode: EditMode = .inactive

    private var mine: [String] { isToolbar ? toolbar : menu }
    private var otherIDs: [String] { isToolbar ? menu : toolbar }

    /// 两栏都没用的功能
    private var unused: [QPBarCatalog.Item] {
        QPBarCatalog.all.filter { !mine.contains($0.id) && !otherIDs.contains($0.id) }
    }
    /// 在另一栏里的功能（点 + 就是挪过来）
    private var inOther: [QPBarCatalog.Item] {
        QPBarCatalog.all.filter { otherIDs.contains($0.id) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(mine, id: \.self) { id in
                    HStack(spacing: 12) {
                        Image(systemName: QPBarCatalog.symbol(id))
                            .frame(width: 22)
                            .foregroundColor(.blue)
                        Text(QPBarCatalog.name(id))
                        Spacer(minLength: 4)
                        Button { moveToOther(id) } label: {
                            Image(systemName: isToolbar ? "arrow.down.to.line" : "arrow.up.to.line")
                                .foregroundColor(.blue)
                        }
                        Button { remove(id) } label: {
                            Image(systemName: "minus.circle.fill").foregroundColor(.red)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .onMove { src, dst in moveWithin(src, dst) }
            } header: {
                Text("\(isToolbar ? "工具栏显示" : "菜单栏显示")（\(mine.count) 项）")
            } footer: {
                Text("点右上角「编辑」可拖动排序；蓝色箭头把这一项挪到另一栏；红色减号移除。改完即时生效，切回键盘即可看到。")
            }

            if !inOther.isEmpty {
                Section("从\(isToolbar ? "菜单栏" : "工具栏")移过来") {
                    ForEach(inOther, id: \.id) { it in
                        addRow(it, hint: "点 + 挪过来")
                    }
                }
            }

            if !unused.isEmpty {
                Section("可用功能（\(unused.count)）") {
                    ForEach(unused, id: \.id) { it in
                        addRow(it, hint: QPBarCatalog.needsFullAccess(it.id)
                               ? "需完全访问" : "")
                    }
                }
            }

            Section {
                Button("恢复默认版面") {
                    toolbar = QPBarCatalog.defaultToolbar
                    menu = QPBarCatalog.defaultMenu
                    commit()
                }
            }
        }
        .navigationTitle(isToolbar ? "定制工具栏" : "定制菜单栏")
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
        }
        .onAppear {
            load()
            // 通道可能被一次普通复制冲掉，进页面顺手重新发布，保证切回键盘时新鲜。
            QPSharedHistory.republishBarSettings()
        }
    }

    @ViewBuilder
    private func addRow(_ it: QPBarCatalog.Item, hint: String) -> some View {
        Button { add(it.id) } label: {
            HStack {
                Image(systemName: it.symbol).frame(width: 22)
                Text(it.name)
                Spacer()
                if !hint.isEmpty {
                    Text(hint).font(.caption2).foregroundColor(.secondary)
                }
                Image(systemName: "plus.circle.fill").foregroundColor(.green)
            }
        }
        .buttonStyle(.borderless)
    }

    private func load() {
        let s = QPSharedHistory.sharedBarLayout()
        toolbar = s.toolbar
        menu = s.menu
        // 本地留一份，共享通道被系统临时清空时页面不会显示回弹
        tbStored = encode(s.toolbar)
        mnStored = encode(s.menu)
    }

    private func commit() {
        let t = QPBarCatalog.sanitize(toolbar)
        let m = QPBarCatalog.sanitize(menu)
        toolbar = t
        menu = m
        tbStored = encode(t)
        mnStored = encode(m)
        _ = QPSharedHistory.setSharedBarLayout(toolbar: t, menu: m)
    }

    private func encode(_ a: [String]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: a, options: []) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    private func setMine(_ a: [String]) {
        if isToolbar { toolbar = a } else { menu = a }
    }

    private func setOther(_ a: [String]) {
        if isToolbar { menu = a } else { toolbar = a }
    }

    private func moveWithin(_ src: IndexSet, _ dst: Int) {
        var a = mine
        a.move(fromOffsets: src, toOffset: dst)
        setMine(a)
        commit()
    }

    private func remove(_ id: String) {
        var a = mine
        a.removeAll { $0 == id }
        setMine(a)
        commit()
    }

    private func add(_ id: String) {
        var a = mine
        guard !a.contains(id) else { return }
        a.append(id)
        setMine(a)
        // 从另一栏挪过来 = 另一栏里删掉，保证一个功能只在一栏出现
        var other = otherIDs
        other.removeAll { $0 == id }
        setOther(other)
        commit()
    }

    private func moveToOther(_ id: String) {
        var a = mine
        a.removeAll { $0 == id }
        setMine(a)
        var other = otherIDs
        if !other.contains(id) { other.append(id) }
        setOther(other)
        commit()
    }
}

// MARK: - 设置详情：连续复制

struct ContinuousView: View {
    var body: some View {
        Form {
            Section {
                Text("连续复制会在你复制新内容时自动保存。iOS 不允许第三方键盘后台常驻监控或显示系统级悬浮窗，墨指 的实现是：每次呼出键盘时把系统剪贴板里的新文字收入历史。")
                    .font(.subheadline)
            }
            Section("如何开启") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 打开主 App「连续复制」页，点「开启连续复制」（后台小窗自动出现）")
                    Text("2. 切到任意 App 继续复制，记录持续增加，键盘里也能看到")
                }
                Text("键盘侧开关在「长按连续复制图标 → 设置 → 连续复制」的「键盘可见时自动抓取」。")
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
            Section("启用 墨指") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(["安装后用爱思助手 / 手机端签名工具完成 7 天签名",
                                  "设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 墨指",
                                  "点开 墨指 → 开启「允许完全访问」",
                                  "打开主 App，填电脑地址 http://192.168.1.2:8787 并保存",
                                  "在任意 App 输入框按地球仪切到 墨指 即可使用"].enumerated()), id: \.offset) { i, s in
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
                Text("墨指 v1.8.35 · 真·系统输入法").font(.headline)
                Text("iOS：键盘扩展 .appex（com.apple.keyboard-service）")
                Text("安卓：系统输入法 InputMethodService")
            }
            Section("说明") {
                Text("界面按 最新版原型原生实现，无 WebView、无演示动画。")
                Text("数据只在你的局域网内传输，不经过公网。")
                Text("免费 Apple ID 签名 7 天到期后需重签，键盘内数据不会丢失。")
            }
        }
        .navigationTitle("关于")
    }
}
