import SwiftUI
import UIKit

// MARK: - 主 App「连续复制」页

struct PiPControlView: View {
    @ObservedObject private var pip = PiPManager.shared
    /// 合并视图（去重、墓碑过滤、按时间倒序）——见 LocalStore.allItems()
    @State private var entries: [(text: String, ts: Double)] = PiPManager.mergedItems()
    /// 筛选：0 全部 / 1 文本 / 2 链接
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

    /// 链接条目判断
    private static func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.")
    }

    private var filtered: [(text: String, ts: Double)] {
        switch filterKind {
        case 1: return entries.filter { !Self.isLink($0.text) }
        case 2: return entries.filter { Self.isLink($0.text) }
        default: return entries
        }
    }

    private var filterName: String {
        ["全部", "文本", "链接"][filterKind]
    }

    // MARK: v1.8.43「一轮连续复制算一次」——按开启轮次统一标，不再逐条编号
    private struct RankedItem: Identifiable {
        let id: String
        let text: String
        let ts: Double
        let session: Int
    }

    /// session：0=本次开启这一轮、1=上一轮、2=上上轮、3=更早（不标）。
    private var ranked: [RankedItem] {
        filtered.map {
            RankedItem(id: $0.text, text: $0.text, ts: $0.ts,
                       session: Self.sessionRank($0.ts))
        }
    }

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
                        Text(pip.running ? "连续复制中" : "未开启连续复制")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text("本次已收录 \(pip.capturedCount) 条")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                    }
                    Text(pip.running
                         ? "小窗在屏幕上就一直在抓：切到微信、Safari 复制，回来这里能看到每一条。"
                         : "开启后屏幕角落出现小窗，就代表正在后台监听剪贴板。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    // ★ 用户点名要的「小开关」：一个按钮，开/关连续复制，颜色跟随真实状态。
                    SmallSwitchButton()
                        .padding(.top, 2)
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

                Section("已收录 \(filtered.count) 条 · 本次 \(ranked.filter { $0.session == 0 }.count) 条") {
                    if filtered.isEmpty {
                        Text("还没有收录。开启连续复制后，在别的 App 里复制的文字会出现在这里。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(ranked) { e in
                            Button {
                                if editMode {
                                    if selection.contains(e.text) {
                                        selection.remove(e.text)
                                    } else {
                                        selection.insert(e.text)
                                    }
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
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    if editMode {
                                        Image(systemName: selection.contains(e.text)
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(.accentColor)
                                    }
                                    if let label = sessionLabel(e.session) {
                                        Text(label)
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(e.session == 0 ? .white : (e.session == 1 ? .blue : .secondary))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(
                                                e.session == 0 ? Color.blue
                                                    : (e.session == 1 ? Color.blue.opacity(0.15)
                                                       : Color(UIColor.systemGray5))
                                            ))
                                    }
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
        let texts = selection.isEmpty
            ? filtered.map(\.text)
            : filtered.filter { selection.contains($0.text) }.map(\.text)
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
        let texts = selection.isEmpty ? filtered.map(\.text) : filtered.filter { selection.contains($0.text) }.map(\.text)
        guard !texts.isEmpty else { flash("没有可复制的内容"); return }
        UIPasteboard.general.string = texts.joined(separator: "\n\n————\n\n")
        NianshuFeedback.copied()
        flash("已复制 \(texts.count) 条到剪贴板，去任何输入框粘贴即可")
    }

    private func deleteSelected() {
        let texts = Array(selection)
        guard !texts.isEmpty else { return }
        let before = entries.count
        PiPManager.deleteTexts(texts)
        let after = PiPManager.mergedItems()
        entries = after
        selection.removeAll()
        let removed = before - after.count
        if removed > texts.count {
            flash("⚠️ 删除异常：应删 \(texts.count) 条，实际移除 \(removed) 条，请检查")
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
