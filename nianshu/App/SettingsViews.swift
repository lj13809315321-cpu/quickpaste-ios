import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 主 App 根视图（独立 App，无键盘扩展）

struct AppRootView: View {
    @State private var tab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            HistoryView().tabItem { Label("历史", systemImage: "clock") }.tag(0)
            PiPControlView().tabItem {
                Label("连续复制", systemImage: "rectangle.on.rectangle")
            }.tag(1)
            SettingsView().tabItem { Label("设置", systemImage: "gearshape") }.tag(2)
        }
        // 独立 App 没有键盘扩展来发指令，只需处理自己的 nianshu:// 深链
        // （快捷指令/页面跳转触发），以及进前台时按「下次自动开」拉起。
        .onOpenURL { url in
            let host = url.host ?? ""
            if host == "pip" {
                tab = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    PiPManager.shared.start()
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                PiPManager.shared.startIfWanted()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                PiPManager.shared.startIfWanted()
            }
        }
    }

    /// 等画中画真正起来（running 由启动回调置真）再跳回，最多等 3 秒；
    /// 没起来就留在本页看系统提示，不假装「已开好并跳回」。
    static func returnToSourceAfterPipStart() {
        let target = LocalStore.defaultReturnBundleId()
        guard let target = target, !target.isEmpty, target != "none" else { return }
        jumpBackAfterPiP(host: target)
    }

    private static func jumpBackAfterPiP(host: String, triesLeft: Int = 15) {
        if PiPManager.shared.running {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openHostApp(host) }
            return
        }
        guard triesLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            jumpBackAfterPiP(host: host, triesLeft: triesLeft - 1)
        }
    }

    /// 跳回来源 App：用公开 API `UIApplication.shared.open(协议)`，
    /// 这是 iOS 上最可靠的一条（需在 Info.plist 的 LSApplicationQueriesSchemes 声明白名单）。
    static func openHostApp(_ host: String) {
        guard !host.isEmpty, host != "none" else { return }
        // 传进来的已经是 "weixin://" 这类协议串（来自「默认返回 App」选择）。
        guard let url = URL(string: host), host.contains("://"),
              UIApplication.shared.canOpenURL(url) else {
            PiPManager.shared.note("没跳回来源 App（\(host)），可点本页「返回来源 App」按钮或状态栏系统返回；连续复制不受影响")
            return
        }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok {
                PiPManager.shared.note("没跳回来源 App（\(host)），可点本页「返回来源 App」按钮或状态栏系统返回；连续复制不受影响")
            }
        }
    }
}

// MARK: - 剪贴板历史

struct HistoryView: View {
    @State private var entries: [(text: String, ts: Double)] = PiPManager.mergedItems()
    @State private var draft = ""
    @State private var search = ""
    @State private var flashMsg = ""
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
                        TextField("添加一条到历史", text: $draft)
                            .textInputAutocapitalization(.never)
                        Button("添加") {
                            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            PiPManager.appendLocal(t)
                            draft = ""
                            reload()
                            notice("已添加，连续复制页同步可见")
                        }
                        .buttonStyle(.borderless)
                    }
                    if !flashMsg.isEmpty {
                        Text(flashMsg).font(.footnote).foregroundColor(.blue)
                    }
                } footer: {
                    Text("这一页显示的是与「连续复制」页完全同一份记录：App 后台收录的、你在别的 App 复制的，都在这里。")
                }

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
                    Text("「选择」后点条目勾选，可全选、复制所选、删除所选（有二次确认）；导出范围 = 有选择时导出所选，否则导出当前筛选下的全部。")
                }

                if filtered.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.on.clipboard").font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text(search.isEmpty ? "还没有记录" : "没有匹配的记录")
                            Text(search.isEmpty
                                 ? "在任意 App 复制文字后切到粘鼠，或开启「连续复制」让 App 在后台收录，记录就会出现在这里。"
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
                                    NianshuFeedback.copied()
                                    if LocalStore.moveUsedToTopOn() {
                                        PiPManager.appendLocal(item.text)
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
                Text("将永久删除选中的 \(selection.count) 条（仅本机列表；此操作不可撤销）。")
            }
        }
    }

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
            sharePayload = [url]
        }
    }

    private func copySelected() {
        let texts = selection.isEmpty
            ? filtered.map(\.text)
            : filtered.filter { selection.contains($0.text) }.map(\.text)
        guard !texts.isEmpty else { notice("没有可复制的内容"); return }
        UIPasteboard.general.string = texts.joined(separator: "\n\n————\n\n")
        NianshuFeedback.copied()
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
            notice("已删除 \(removed) 条")
        }
    }
}

// MARK: - 设置首页（独立 App 版）

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("粘鼠 v1.0.0 · 连续复制独立版", systemImage: "doc.on.doc.fill")
                            .font(.subheadline.weight(.semibold))
                        Text("把任意 App 里复制的文字自动收进列表，随时回看、导出、批量复制。不需要键盘扩展，靠系统画中画在后台常驻监听剪贴板。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("剪贴板行为") {
                    NavigationLink("复制后移到最前") { MoveUsedToTopView() }
                    NavigationLink("复制成功震动") { CopyHapticView() }
                    NavigationLink("返回来源 App") { ReturnAppView() }
                }

                Section("启用与排查") {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: { Label("打开本 App 的系统设置", systemImage: "gear") }
                    Text("要让后台连续复制生效，请在系统设置里把「从其他 App 粘贴」设为允许，并在「通用 → 画中画」打开「自动开启画中画」。")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section("预览") {
                    NavigationLink("剪贴板历史") { HistoryView() }
                    NavigationLink("连续复制") { PiPControlView() }
                }

                Section("关于签名") {
                    Text("本 App 用免费 Apple ID 在手机端签名安装，到期需重签。密码框会强制使用系统键盘，属系统限制。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}

// MARK: - 设置详情：复制到最前 / 震动 / 返回来源

struct MoveUsedToTopView: View {
    @State private var on = LocalStore.moveUsedToTopOn()
    var body: some View {
        Form {
            Toggle("复制后移到最前", isOn: $on)
                .onChange(of: on) { v in LocalStore.setMoveUsedToTop(v) }
            Text("开着时：在历史页或连续复制页点一条旧记录复制，这条会自动排到列表最前。系统里复制新内容一直都会排到最前，不受这个开关影响。")
                .font(.footnote).foregroundColor(.secondary)
        }
        .navigationTitle("复制后移到最前")
    }
}

struct CopyHapticView: View {
    @State private var on = LocalStore.copyHapticOn()
    var body: some View {
        Form {
            Toggle("复制成功震动", isOn: $on)
                .onChange(of: on) { v in LocalStore.setCopyHaptic(v) }
            Text("点条目复制成功后轻震一下，确认内容真的进了剪贴板。")
                .font(.footnote).foregroundColor(.secondary)
        }
        .navigationTitle("复制成功震动")
    }
}

struct ReturnAppView: View {
    @State private var choice: String = LocalStore.defaultReturn() ?? "auto"
    var body: some View {
        Form {
            Picker("默认返回 App", selection: $choice) {
                ForEach(LocalStore.returnChoices, id: \.id) { c in
                    Text(c.name).tag(c.scheme)
                }
            }
            .onChange(of: choice) { v in LocalStore.setDefaultReturn(v) }
            Text("粘鼠 是独立 App，没有键盘扩展，拿不到「刚才在哪个 App」。设一个默认返回 App 后，开启/关闭连续复制完就能一键跳回去。选「不自动返回」则只停在粘鼠内。")
                .font(.footnote).foregroundColor(.secondary)
        }
        .navigationTitle("返回来源 App")
    }
}
