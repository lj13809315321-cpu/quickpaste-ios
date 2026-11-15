import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 主 App「连续复制」页

struct PiPControlView: View {
    @ObservedObject private var pip = PiPManager.shared
    /// 合并视图（去重、墓碑过滤、按时间倒序）——见 LocalStore.allItems()
    @State private var entries: [NSItem] = PiPManager.mergedItems()
    /// 筛选：0 全部 / 1 文本 / 2 链接 / 3 图片
    @State private var filterKind = 0
    /// 批量编辑：选择模式 + 已选集合（以原文为 id）
    @State private var editMode = false
    @State private var selection = Set<String>()
    /// 导出分享面板
    @State private var sharePayload: [Any]?
    @State private var notice = ""
    /// 用户设定的默认返回 App（iOS 无键盘后拿不到宿主时的确定性兜底）
    @State private var defaultReturn: String = LocalStore.defaultReturn() ?? "auto"
    /// 删除所选前必须二次确认，杜绝「一键清空全部」的误操作
    @State private var confirmDelete = false
    /// v1.8.38：「开启连续复制前清空之前的连续复制」开关
    @AppStorage("ns.pipClearOnStart") private var clearBeforeStart = false
    /// v1.8.43：快捷指令「切换」关掉连续复制后，要不要自动跳回来源 App。
    /// 默认【关】= 停在粘鼠主 App；打开 = 关完立刻回抖音等来源 App。
    @AppStorage("ns.pipToggleReturnOnClose") private var toggleReturnOnClose = false
    /// 收录过滤：0 全部 / 1 仅文字 / 2 仅图片
    @AppStorage("ns.captureFilter") private var captureFilter = 0

    /// 链接条目判断
    private static func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.")
    }

    private var filtered: [NSItem] {
        switch filterKind {
        case 1: return entries.filter { $0.kind == .text && !$0.isLink }
        case 2: return entries.filter { $0.isLink }
        case 3: return entries.filter { $0.kind == .image }
        default: return entries
        }
    }

    private var filterName: String {
        ["全部", "文本", "链接", "图片"][filterKind]
    }

    // MARK: v1.8.43「一轮连续复制算一次」——按开启轮次统一标，不再逐条编号
    /// session：0=本次开启这一轮、1=上一轮、2=上上轮、3=更早（不标）。
    private func session(of item: NSItem) -> Int { Self.sessionRank(item.ts) }

    /// 靠「收录时刻落在哪一轮的区间里」判轮次，不用给每条历史加字段。
    private static func sessionRank(_ ts: Double) -> Int {
        let s = PiPManager.pipSessionStarts()
        guard !s.isEmpty, ts > 0 else { return 3 }
        if ts >= s[0] { return 0 }
        if s.count > 1, ts >= s[1] { return 1 }
        if s.count > 2, ts >= s[2] { return 2 }
        return 3
    }

    private func sessionLabel(_ r: Int) -> String? {
        switch r {
        case 0: return "本次"
        case 1: return "上次"
        case 2: return "上上次"
        default: return nil
        }
    }

    private func timeLabel(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let d = Date().timeIntervalSince1970 - ts
        if d < 60 { return "刚刚" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(pip.running
                                  ? Color(red: 0.20, green: 0.78, blue: 0.35)
                                  : Color(red: 0.76, green: 0.76, blue: 0.78))
                            .frame(width: 12, height: 12)
                        Text(pip.running ? (pip.paused ? "已暂停收录" : "连续复制中") : "未开启连续复制")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text("本次已收录 \(pip.capturedCount) 条")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                    }
                    Text(pip.running
                         ? (pip.paused
                            ? "小窗仍在、后台保活没断，只是暂时不收新复制的内容。点下面「继续收录」恢复。"
                            : "小窗在屏幕上就一直在抓：切到微信、Safari 复制，回来这里能看到每一条。")
                         : "开启后屏幕角落出现小窗，就代表正在后台监听剪贴板。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("这个列表只放【文字】和【图片】；PDF、视频等文件类内容在底部「文件」页，不会混进这里。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    // ★ 用户点名要的「小开关」：一个按钮，开/关连续复制，颜色跟随真实状态。
                    SmallSwitchButton()
                        .padding(.top, 2)
                    // ★ 暂停 / 继续：不关小窗，只停/开「读剪贴板」。
                    if pip.running {
                        Button {
                            pip.togglePause()
                        } label: {
                            Label(pip.paused ? "继续收录" : "暂停收录（小窗保持）",
                                  systemImage: pip.paused ? "play.circle.fill" : "pause.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(pip.paused ? .green : .orange)
                    }
                }

                // 无键盘后：用户设一个默认返回 App + 一个随时可按的「立即返回」按钮。
                Section("返回来源 App") {
                    Picker("默认返回 App", selection: $defaultReturn) {
                        ForEach(LocalStore.returnChoices, id: \.id) { c in
                            Text(c.name).tag(c.scheme)
                        }
                    }
                    .onChange(of: defaultReturn) { v in
                        LocalStore.setDefaultReturn(v)
                    }
                    Button {
                        let target = LocalStore.defaultReturnBundleId() ?? ""
                        if target.isEmpty {
                            PiPManager.shared.note("还没选择默认返回 App；请先在上面选一个")
                        } else {
                            AppRootView.openHostApp(target)
                        }
                    } label: {
                        Label("立即返回来源 App", systemImage: "arrow.uturn.backward")
                    }
                    Text("粘鼠 是独立 App，没有键盘扩展，拿不到「刚才在哪个 App」。设一个默认返回 App 就一定能跳回去；也可以点屏幕左上角系统状态栏的「返回 微信」等按钮。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
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

                // ── v1.8.38：开启连续复制前是否清空之前的连续复制 ──
                Section {
                    Toggle("开启前清空之前的连续复制", isOn: $clearBeforeStart)
                        .font(.body)
                    Text("打开后，每次点「开启连续复制」会先把之前攒下的连续复制内容清空，再从头开始收集；关闭则接着之前的继续叠加（默认关闭，沿用现在的行为）。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // ── 更多玩法：收录控制 ──
                Section("更多玩法 · 收录控制") {
                    Picker("只收什么", selection: $captureFilter) {
                        Text("文字 + 图片 + 文件（全部）").tag(0)
                        Text("仅文字").tag(1)
                        Text("仅图片").tag(2)
                    }
                    Text("选「仅文字」时图片和剪贴板文件都不收；选「仅图片」时文字不收。改完立刻生效，不用重启画中画。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("快捷指令里现在有三个独立动作：「暂停收录」（单独暂停）、「启动收录」（单独启动/继续）、「切换暂停启动」（一键在两者之间翻转）。三个都不用切回本 App，可放进自动化或用 Siri 唤起；暂停状态会一直保留到下次「启动」。注意：这三个只控制「收不收」，如果画中画小窗已经彻底关掉了，请改用「开启连续复制」。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // ── v1.8.43：快捷指令「切换」关闭后，是否自动跳回来源 App ──
                Section {
                    Toggle("切换关闭后自动跳回来源 App", isOn: $toggleReturnOnClose)
                        .font(.body)
                    Text("只管快捷指令里的「切换」动作。默认关闭：用「切换」关掉连续复制后会停在粘鼠主 App（能顺眼看一眼状态），单独「关闭」本来就不跳，不受影响。打开后：关完立刻自动跳回你刚才所在的 App（抖音等）。注意：画中画必须由前台窗口承载，触发「切换」时系统一定会短暂拉起粘鼠，这个开关控制的是关完要不要再跳回去，不能阻止那一次拉起。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // ── v1.8.14 收录列表：筛选 / 批量选择 / 删除 / 复制 / 导出 ──
                Section {
                    HStack(spacing: 16) {
                        Menu {
                            Picker("筛选", selection: $filterKind) {
                                Text("全部").tag(0)
                                Text("文本").tag(1)
                                Text("链接").tag(2)
                                Text("图片").tag(3)
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
                            Button("全选") { selection = Set(filtered.map(\.id)) }
                                .buttonStyle(.borderless)
                            Button("复制所选") { copySelected() }
                                .buttonStyle(.borderless)
                            Button("删除所选", role: .destructive) { confirmDelete = true }
                                .buttonStyle(.borderless)
                                .disabled(selection.isEmpty)
                            Spacer()
                            Text("已选 \(selection.count) 条")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .font(.subheadline)
                    }
                    if !notice.isEmpty {
                        Text(notice).font(.footnote).foregroundColor(.blue)
                    }
                } footer: {
                    Text("「选择」后点条目勾选，可批量删除；导出范围 = 有选择时导出所选，否则导出当前筛选下的全部。导出文件走系统分享面板（可转发微信、保存到「文件」等）。")
                }

                Section("已收录 \(filtered.count) 条 · 本次 \(filtered.filter { session(of: $0) == 0 }.count) 条") {
                    if filtered.isEmpty {
                        Text("还没有收录。开启连续复制后，在别的 App 里复制的文字或图片会出现在这里。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filtered) { e in
                            Button {
                                if editMode {
                                    if selection.contains(e.id) {
                                        selection.remove(e.id)
                                    } else {
                                        selection.insert(e.id)
                                    }
                                } else {
                                    if e.kind == .image, let name = e.imgName,
                                       let img = LocalStore.loadImage(named: name) {
                                        UIPasteboard.general.image = img
                                        NianshuFeedback.copied()
                                        flash("已复制图片到剪贴板，去能接图的 App 粘贴即可")
                                    } else {
                                        UIPasteboard.general.string = e.text
                                        NianshuFeedback.copied()
                                        if LocalStore.moveUsedToTopOn() {
                                            PiPManager.appendLocal(e.text)
                                            entries = PiPManager.mergedItems()
                                            flash("已复制，并移到最前")
                                        } else {
                                            flash("已复制该条内容，去任何输入框粘贴即可")
                                        }
                                    }
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    if editMode {
                                        Image(systemName: selection.contains(e.id)
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(.accentColor)
                                    }
                                    if let label = sessionLabel(session(of: e)) {
                                        Text(label)
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(session(of: e) == 0 ? .white : (session(of: e) == 1 ? .blue : .secondary))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(
                                                session(of: e) == 0 ? Color.blue
                                                    : (session(of: e) == 1 ? Color.blue.opacity(0.15)
                                                       : Color(UIColor.systemGray5))
                                            ))
                                    }
                                    if e.kind == .image {
                                        let thumb = (e.imgName).flatMap { LocalStore.loadImage(named: $0) }
                                        if let img = thumb {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 46, height: 46)
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        } else {
                                            Image(systemName: "photo")
                                                .frame(width: 46, height: 46)
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("图片")
                                                .font(.subheadline)
                                                .foregroundColor(.primary)
                                            if !timeLabel(e.ts).isEmpty {
                                                Text(timeLabel(e.ts))
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer()
                                    } else {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(e.text)
                                                .lineLimit(2)
                                                .font(.subheadline)
                                                .foregroundColor(.primary)
                                            if !timeLabel(e.ts).isEmpty {
                                                Text(timeLabel(e.ts))
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text("\(e.text.count) 字")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("收不到内容时按顺序检查") {
                    checkRow("1", "设置 → 粘鼠 → 从其他 App 粘贴 → 允许")
                    checkRow("2", "设置 → 通用 → 画中画 → 打开「自动开启画中画」")
                    checkRow("3", "小窗要一直在屏幕上；App 被划掉、小窗被点 ✕ 就停止监听了")
                }
            }
            .navigationTitle("连续复制")
            .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                entries = PiPManager.mergedItems()
                pip.refreshCount()
            }
            .onAppear {
                pip.startIfWanted()
                PiPManager.ensureSessionBaseline()
            }
            .sheet(isPresented: Binding(
                get: { sharePayload != nil },
                set: { if !$0 { sharePayload = nil } })) {
                if let payload = sharePayload {
                    ActivityView(items: payload)
                }
            }
            .alert("确认删除所选？", isPresented: $confirmDelete) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) { deleteSelected() }
            } message: {
                Text("将永久删除选中的 \(selection.count) 条（仅本机列表；此操作不可撤销）。")
            }
        }
    }

    // MARK: 列表动作

    private func flash(_ msg: String) {
        notice = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { notice = "" }
    }

    private func exportTexts() -> [String] {
        let sel = selection.isEmpty
            ? filtered
            : filtered.filter { selection.contains($0.id) }
        let texts = sel.filter { $0.kind == .text }.map { $0.text }
        return texts.isEmpty ? [""] : texts
    }

    private func exportButton(_ title: String,
                             texts: @escaping ([String]) -> URL?) -> some View {
        Button(title) {
            let t = exportTexts()
            if t == [""] { flash("没有可导出的内容"); return }
            guard let url = texts(t) else { flash("导出失败：文件生成出错"); return }
            sharePayload = [url]
        }
    }

    private func copySelected() {
        let sel = selection.isEmpty ? filtered : filtered.filter { selection.contains($0.id) }
        guard !sel.isEmpty else { flash("没有可复制的内容"); return }
        let texts = sel.filter { $0.kind == .text }.map { $0.text }
        let images = sel.compactMap { e -> UIImage? in
            guard e.kind == .image, let n = e.imgName else { return nil }
            return LocalStore.loadImage(named: n)
        }
        guard !texts.isEmpty || !images.isEmpty else { flash("没有可复制的内容"); return }
        // 文本与图片一起写进剪贴板：文本放一条、每张图各放一条
        var items: [[String: Any]] = []
        if !texts.isEmpty {
            items.append([UTType.utf8PlainText.identifier: texts.joined(separator: "\n\n————\n\n")])
        }
        for img in images {
            if let d = img.pngData() { items.append([UTType.png.identifier: d]) }
        }
        guard !items.isEmpty else { flash("没有可复制的内容"); return }
        UIPasteboard.general.items = items
        NianshuFeedback.copied()
        flash("已复制 \(texts.count) 条文字、\(images.count) 张图片到剪贴板")
    }

    private func deleteSelected() {
        let ids = selection.isEmpty ? filtered.map { $0.id } : Array(selection)
        guard !ids.isEmpty else { return }
        let before = entries.count
        PiPManager.deleteItems(ids)
        let after = PiPManager.mergedItems()
        entries = after
        selection.removeAll()
        let removed = before - after.count
        if removed > ids.count {
            flash("⚠️ 删除异常：应删 \(ids.count) 条，实际移除 \(removed) 条，请检查")
        } else {
            flash("已删除 \(removed) 条")
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

// MARK: - ★「小开关」：用户点名要的就地连续复制开关（独立 App 版）

/// 一个按钮 + 判活 + 同步收尾 + 状态色。独立 App 没有键盘扩展、没有跨进程指令，
/// 逻辑大幅简化：
///   · `isActive` = `running || starting`（PiPManager 的 @Published，不要任何剪贴板心跳）。
///   · 关闭一定用 `forceStopFromShortcut()`，别用裸 `stop()`（didStop 回调进后台常不派发）。
///   · 开启用 `start()`（内置「等窗口就绪 + 3 次重试」），不用在外面 sleep。
struct SmallSwitchButton: View {
    @ObservedObject private var pip = PiPManager.shared

    var body: some View {
        Button {
            if pip.isActive {
                pip.forceStopFromShortcut()
            } else {
                pip.start()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.title2)
                    .foregroundColor(pip.running ? .blue : .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("小开关")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(pip.isActive ? "连续复制运行中 · 点按关闭" : "已关闭 · 点按开启")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 系统分享面板（导出文件用）

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let window = (UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first) {
            vc.popoverPresentationController?.sourceView = window
            vc.popoverPresentationController?.sourceRect =
                CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
        }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
