import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 「文件」页：任意格式的收录与转发
//
// 两条入口：
//   ① 自动：别的 App 复制文件时，若它把文件字节放进了剪贴板，
//      PiPManager → FileStore.capture 会自动收进这里；
//   ② 手动：点「从「文件」App 导入」，用系统文件选择器选任意文件，
//      粘鼠存进自己沙盒。视频 / PSD / PPT / WPS 表格 等基本都走这条。
// 出去：点文件 → 系统分享面板发到微信 / WPS / 任意 App（最可靠），
//       或「复制到剪贴板」（仅目标 App 认该格式时有效）。
//
// ★ 导入为什么改用 UIKit 直接 present：
//   本页同时挂了 .sheet（分享）、.confirmationDialog（文件操作）、.alert（清空），
//   再叠一个 SwiftUI .fileImporter 时，多个 presentation 修饰符挤在同一视图层级，
//   会把文件选择器挤掉（表现为点按钮没反应 / 弹一下就消失）。另外原来每 1.5 秒
//   reload() 会不断重算 body，也会干扰系统弹窗。改为：
//     · UIKit UIDocumentPickerViewController 由最上层控制器直接 present；
//     · 去掉定时器，只在进页面 / 回前台 / 导入完成通知时刷新；
//     · asCopy: true 让系统把文件复制一份给本 App，不依赖 iCloud 权限。
//   asCopy 的 URL 是 App 可读的本地副本，FileStore.importFiles 里的
//   startAccessingSecurityScopedResource() 返回 false 也不会影响读取。

private let nsFilesChanged = Notification.Name("ns.files.changed")

/// 系统文件选择器（单例持有 delegate，避免被 SwiftUI 视图重建时释放）。
private final class DocPickerPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = DocPickerPresenter()
    private var onResult: ((String) -> Void)?

    func present(onResult: @escaping (String) -> Void) {
        self.onResult = onResult
        // .item = 任意文件的抽象基类；后面几个是常见具类，兜住部分文件提供者的过滤差异。
        let types: [UTType] = [
            .item, .content, .data, .pdf, .image, .movie, .audio,
            .text, .plainText, .html, .json, .xml
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        guard let top = Self.topViewController() else {
            onResult("找不到当前界面，无法打开文件选择器；请退回主屏再进一次粘鼠")
            self.onResult = nil
            return
        }
        top.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        let cb = onResult
        onResult = nil
        let n = FileStore.importFiles(urls)
        let msg = n > 0 ? "已导入 \(n) 个文件"
                        : "这些文件已存在，或未能读取（超过 50MB 会被跳过）"
        controller.dismiss(animated: true) {
            NotificationCenter.default.post(name: nsFilesChanged, object: msg)
            cb?(msg)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onResult = nil
        controller.dismiss(animated: true)
    }
}

struct FileTransferView: View {
    @State private var files: [FileMeta] = FileStore.all()
    @State private var notice = ""
    @State private var sharePayload: [Any]?
    @State private var pending: FileMeta?
    @State private var confirmClear = false
    @Environment(\.scenePhase) private var scenePhase

    private func reload() { files = FileStore.all() }

    private func flash(_ s: String) {
        notice = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { notice = "" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        DocPickerPresenter.shared.present { msg in flash(msg) }
                    } label: {
                        Label("从「文件」App 导入文件（任意格式）", systemImage: "folder.badge.plus")
                            .font(.body.weight(.semibold))
                    }
                    Text("视频 / PDF / PSD / HTML / TXT / WPS 表格 / PPT / Word / Excel / 压缩包… 常见格式都能导入。导入后点文件，用系统分享面板发到微信、WPS 等目标 App。")
                        .font(.footnote).foregroundColor(.secondary)
                    if !notice.isEmpty {
                        Text(notice).font(.footnote).foregroundColor(.blue)
                    }
                } footer: {
                    Text("单个文件上限 50MB，仓库最多 100 个；重复文件按内容自动去重。更大的视频请直接用系统「文件」App 分享。下拉可刷新列表。")
                }

                Section("能自动收录 vs 必须导入") {
                    Label("自动：图片、文字，以及把字节放进剪贴板的 PDF / HTML / RTF / 小音视频（≤20MB）",
                          systemImage: "bolt.fill")
                        .font(.footnote)
                    Label("需导入：大视频、PSD、PPT、WPS 表格、Word、Excel 等（系统只给文件链接，不给内容）",
                          systemImage: "hand.tap.fill")
                        .font(.footnote)
                    Text("这是 iOS 系统规则：剪贴板不是文件传输通道，源 App 复制文件时多数只放一个指向自己沙盒的链接，别的 App 没有权限打开。任何 App 都一样，不是粘鼠的限制。")
                        .font(.caption).foregroundColor(.secondary)
                    Text("文字和图片显示在「连续复制」/「历史」列表；文件类内容单独放在本页，不会混进那两个列表。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("已收录文件（\(files.count)）") {
                    if files.isEmpty {
                        Text("还没有文件。可以先点上面「导入文件」，或在别的 App 里复制 PDF / HTML 等看是否自动出现。")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(files) { m in
                            Button { pending = m } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: FileStore.icon(for: m.name))
                                        .font(.title3)
                                        .foregroundColor(.accentColor)
                                        .frame(width: 30)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(m.name).lineLimit(1).font(.subheadline)
                                        Text("\(FileStore.sizeLabel(m.size)) · \(FileStore.timeLabel(m.ts))")
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "square.and.arrow.up").foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { idx in
                            let ids = idx.map { files[$0].id }
                            FileStore.delete(ids)
                            reload()
                            flash("已删除 \(ids.count) 个文件")
                        }
                        Button(role: .destructive) { confirmClear = true } label: {
                            Text("清空全部文件").font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("文件")
            .refreshable { reload() }
            .onAppear { reload() }
            .onChange(of: scenePhase) { phase in if phase == .active { reload() } }
            .onReceive(NotificationCenter.default.publisher(for: nsFilesChanged)) { note in
                reload()
                if let s = note.object as? String, !s.isEmpty { flash(s) }
            }
            .sheet(isPresented: Binding(
                get: { sharePayload != nil },
                set: { if !$0 { sharePayload = nil } })) {
                if let payload = sharePayload { ActivityView(items: payload) }
            }
            .confirmationDialog("文件操作", isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } })) {
                Button("分享到 App（推荐，全格式可用）") {
                    if let m = pending { sharePayload = [FileStore.url(for: m)] }
                }
                Button("复制到剪贴板") {
                    if let m = pending { copyToPasteboard(m) }
                }
                Button("删除", role: .destructive) {
                    if let m = pending { FileStore.delete([m.id]); reload(); flash("已删除") }
                }
                Button("取消", role: .cancel) { pending = nil }
            }
            .alert("清空全部文件？", isPresented: $confirmClear) {
                Button("取消", role: .cancel) { }
                Button("清空", role: .destructive) {
                    FileStore.delete(files.map { $0.id })
                    reload()
                    flash("已清空")
                }
            } message: {
                Text("将永久删除仓库内全部 \(files.count) 个文件（仅本机，不可撤销）。")
            }
        }
    }

    private func copyToPasteboard(_ m: FileMeta) {
        guard let d = try? Data(contentsOf: FileStore.url(for: m)) else {
            flash("读取文件失败"); return
        }
        UIPasteboard.general.items = [[m.uti: d]]
        NianshuFeedback.copied()
        flash("已复制 \(m.name) 到剪贴板；若目标 App 没反应，请改用「分享到 App」")
    }
}
