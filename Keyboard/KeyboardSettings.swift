import UIKit
import SwiftUI

/// v1.8.26：键盘设置页里的「打开 墨指 主 App」入口。
/// SwiftUI Link 由系统的 openURL 环境在用户点击时处理，不走 UIApplication；
/// 这是 KeyboardKit 8.8.6 在 iOS 18 封掉 selector 方案后采用的官方 workaround，
/// 也是目前唯一有框架级证据、能在新版 iOS 键盘扩展里打开 containing app 的方式。
private struct MozhiMainAppLink: View {
    private let target = URL(string: "mozhi://tab/pip?from=keyboard-link")

    var body: some View {
        if let url = target {
            Link(destination: url) {
                HStack(spacing: 8) {
                    Text("📱 打开 墨指 主 App")
                        .font(.system(size: 15, weight: .medium))
                    Spacer(minLength: 4)
                    Text("连续复制")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)
        }
    }
}

/// v1.6 设置界面（真·输入法内，按 quickpaste-ios-prototype.html 的 PAGES 注册表 1:1 实现）。
///
/// 页面：设置首页 / 键盘设置（开关）/ 快捷符号设置 / 连续复制设置 /
///       局域网同步（CopyQ）/ 使用教程（6 篇）/ 剪贴板历史 / 最近删除 / 引导页。
/// 全部开关都写入 KeyboardPrefs 并即时作用到键盘，不是摆设。
///
/// 注意：这是键盘扩展内部的 UIView 面板，不是 WebView，也不是独立的 App 页面。
/// 键盘扩展不能 present 新的 UIViewController，所以用覆盖层 + 页面栈实现导航。

protocol KeyboardSettingsDelegate: AnyObject {
    func settingsDidChange()
    func settingsSyncNow()
    func settingsSendInputText()
    func settingsSendPasteboardText()
    func settingsSendPasteboardImage()
    func settingsAdoptURL() -> Bool
    func settingsResetURL()
    func settingsClearAll()
    func settingsSwitchKeyboard()
    func settingsInsertText(_ text: String)
    func settingsToast(_ text: String)
    func settingsStatus() -> (title: String, count: Int, url: String, backend: String)
}

final class KeyboardSettings: NSObject, UITextFieldDelegate {

    enum Page: Equatable {
        case root, kbd, symbols, continuous, sync, tutorials
        case tutorial(String), history, recentDeleted, onboarding, about
        case confirmClearHistory
    }

    weak var delegate: KeyboardSettingsDelegate?
    /// v1.8.26：Link 要挂在真实 UIViewController 上，openURL 环境才完整。
    weak var hostController: UIViewController?
    private var linkHost: UIHostingController<MozhiMainAppLink>?
    private var prefs = KeyboardPrefs()

    private let panel = UIView()
    private let navBar = UIView()
    private let navTitle = UILabel()
    private let navBack = QPHapticButton(type: .system)
    private let scroll = UIScrollView()
    private let body = UIStackView()
    private var stack: [Page] = []

    private var current: Page { stack.last ?? .root }
    private var urlField: UITextField?
    private var pairField: UITextField?
    private var symbolField: UITextField?

    // MARK: - 安装 / 显隐

    func install(in host: UIView) {
        panel.backgroundColor = QPColor.bg
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.topAnchor.constraint(equalTo: host.topAnchor),
            panel.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        navBar.backgroundColor = .secondarySystemBackground
        navBar.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(navBar)
        NSLayoutConstraint.activate([
            navBar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            navBar.topAnchor.constraint(equalTo: panel.topAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 38)
        ])

        navBack.setTitle("‹ 返回", for: .normal)
        navBack.titleLabel?.font = .systemFont(ofSize: 14)
        navBack.contentHorizontalAlignment = .leading
        navBack.translatesAutoresizingMaskIntoConstraints = false
        navBack.addAction(UIAction { [weak self] _ in self?.back() }, for: .touchUpInside)
        navBar.addSubview(navBack)
        NSLayoutConstraint.activate([
            navBack.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 10),
            navBack.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            navBack.widthAnchor.constraint(equalToConstant: 80)
        ])

        navTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        navTitle.textAlignment = .center
        navTitle.translatesAutoresizingMaskIntoConstraints = false
        navBar.addSubview(navTitle)
        NSLayoutConstraint.activate([
            navTitle.centerXAnchor.constraint(equalTo: navBar.centerXAnchor),
            navTitle.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            navTitle.leadingAnchor.constraint(greaterThanOrEqualTo: navBack.trailingAnchor, constant: 4)
        ])

        let close = QPHapticButton(type: .system)
        close.setTitle("完成", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        navBar.addSubview(close)
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: navBar.centerYAnchor)
        ])

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .onDrag
        panel.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])

        body.axis = .vertical
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false
        body.isLayoutMarginsRelativeArrangement = true
        body.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 24, right: 12)
        scroll.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }

    func show(_ page: Page = .root) {
        stack = [page]
        panel.isHidden = false
        panel.superview?.bringSubviewToFront(panel)
        render()
    }

    func push(_ page: Page) {
        stack.append(page)
        render()
    }

    func back() {
        panel.endEditing(true)
        if stack.count > 1 { stack.removeLast(); render() }
        else { close() }
    }

    func close() {
        panel.endEditing(true)
        panel.isHidden = true
        stack = []
    }

    var isVisible: Bool { !panel.isHidden }

    // MARK: - 渲染

    private func render() {
        panel.endEditing(true)
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        navTitle.text = title(of: current)
        navBack.setTitle(stack.count > 1 ? "‹ 返回" : "关闭", for: .normal)

        switch current {
        case .root:           renderRoot()
        case .kbd:            renderKbd()
        case .symbols:        renderSymbols()
        case .continuous:     renderContinuous()
        case .sync:           renderSync()
        case .tutorials:      renderTutorialList()
        case .tutorial(let k):renderTutorial(k)
        case .history:        renderHistory()
        case .recentDeleted:  renderRecentDeleted()
        case .onboarding:     renderOnboarding()
        case .about:          renderAbout()
        case .confirmClearHistory: renderConfirmClear()
        }
        scroll.contentOffset = .zero
    }

    private func title(of p: Page) -> String {
        switch p {
        case .root: return "设置"
        case .kbd: return "键盘设置"
        case .symbols: return "快捷符号"
        case .continuous: return "连续复制"
        case .sync: return "局域网同步（CopyQ）"
        case .tutorials: return "使用教程"
        case .tutorial(let k): return Tutorial.data[k]?.title ?? "教程"
        case .history: return "剪贴板历史"
        case .recentDeleted: return "最近删除"
        case .onboarding: return "启用引导"
        case .about: return "关于"
        case .confirmClearHistory: return "清除历史记录"
        }
    }

    // MARK: - v1.8.26 打开主 App（SwiftUI Link 行）

    /// 把 SwiftUI Link 用 UIHostingController 包成设置页里的一行。
    /// 只复用一个 hosting controller，避免每次重绘设置页都往 VC 层级里加一个 child。
    private func openMainAppLinkRow() -> UIView {
        if linkHost == nil {
            let h = UIHostingController(rootView: MozhiMainAppLink())
            h.view.backgroundColor = .clear
            if let vc = hostController {
                vc.addChild(h)
                h.didMove(toParent: vc)
            }
            linkHost = h
        }
        let box = UIView()
        box.backgroundColor = .clear
        // UIHostingController.view 是隐式解包可选；赋给局部变量后会变成 UIView?，
        // 这里显式解包，避免 iOS 16 SDK 下「optional 未解包」的编译错误。
        let v: UIView = linkHost!.view!
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            v.topAnchor.constraint(equalTo: box.topAnchor),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        box.heightAnchor.constraint(equalToConstant: 46).isActive = true
        return box
    }

    // MARK: - 设置首页

    private func renderRoot() {
        let s = delegate?.settingsStatus() ?? (title: "未连接", count: 0, url: "", backend: "")
        body.addArrangedSubview(bigTitle("设置"))
        body.addArrangedSubview(promoCard())

        // v1.8.26：二级设置页里的原生 SwiftUI Link 入口。
        // 新版 iOS 会拦掉键盘扩展的程序化 openURL，但由系统 openURL 环境
        // 处理的 Link 仍可打开主 App；轻点工具条「连续复制」图标仍保留作另一条路径。
        body.addArrangedSubview(groupTitle("打开主 App"))
        body.addArrangedSubview(card([openMainAppLinkRow()]))
        body.addArrangedSubview(foot("点这一行直接进主 App「连续复制」页并自动开启。工具条「连续复制」图标轻点一下＝跳过去并开启，再轻点一下＝关闭（长按该图标就是本设置页）；若系统都没放行，手动点桌面「墨指」图标同样落到这一页并完成开关。"))

        body.addArrangedSubview(groupTitle("使用"))
        body.addArrangedSubview(card([
            navRow("局域网同步（CopyQ）", value: s.title) { [weak self] in self?.push(.sync) },
            navRow("键盘设置") { [weak self] in self?.push(.kbd) },
            navRow("快捷符号") { [weak self] in self?.push(.symbols) },
            // v1.8.22：删掉「连续复制」入口 —— 整页都是画中画说明，
            // 和主 App 的连续复制 Tab 重复；真有用的开关已搬进「键盘设置」。
            navRow("使用教程") { [weak self] in self?.push(.tutorials) }
        ]))

        body.addArrangedSubview(groupTitle("数据"))
        body.addArrangedSubview(card([
            cycleRow("历史保留时间", values: ["7 天", "30 天", "90 天", "永久"],
                     selected: [7, 30, 90, 0].firstIndex(of: prefs.historyDays) ?? 1) { [weak self] idx in
                guard let self = self else { return }
                self.prefs.historyDays = [7, 30, 90, 0][idx]
                let n = self.prefs.pruneHistory()
                self.delegate?.settingsDidChange()
                self.delegate?.settingsToast("已设为 " + ["7 天", "30 天", "90 天", "永久"][idx]
                                             + (n > 0 ? "，清理 \(n) 条" : ""))
                self.render()
            },
            navRow("最近删除", value: "\(prefs.recentDeleted.count) 条") { [weak self] in self?.push(.recentDeleted) },
            navRow("清除历史记录", value: "", tint: .systemRed) { [weak self] in self?.confirmClearHistory() },
            switchRow("仅看未分类（隐藏置顶）", sub: "开启后列表只显示未置顶的剪贴板记录",
                      isOn: prefs.onlyUnsorted) { [weak self] v in
                self?.prefs.onlyUnsorted = v
                self?.delegate?.settingsDidChange()
            }
        ]))
        body.addArrangedSubview(foot("置顶的记录不会被自动清理。历史记录保存在本机键盘内，不上传云端。"))

        body.addArrangedSubview(groupTitle("快捷操作"))
        body.addArrangedSubview(card([
            actionRow("⟳ 立即同步（\(s.count) 条）") { [weak self] in
                self?.delegate?.settingsSyncNow()
                self?.delegate?.settingsToast("正在同步…")
            },
            actionRow("↑ 发送输入框文字到电脑") { [weak self] in self?.delegate?.settingsSendInputText() },
            actionRow("📋 发送剪贴板文字到电脑") { [weak self] in self?.delegate?.settingsSendPasteboardText() },
            actionRow("🖼 发送剪贴板图片到电脑") { [weak self] in self?.delegate?.settingsSendPasteboardImage() }
        ]))

        body.addArrangedSubview(groupTitle("预览"))
        body.addArrangedSubview(card([
            actionRow("打开输入法键盘") { [weak self] in self?.close() },
            navRow("查看剪贴板历史") { [weak self] in self?.push(.history) },
            navRow("重新播放引导页") { [weak self] in self?.push(.onboarding) },
            navRow("关于本版本") { [weak self] in self?.push(.about) }
        ]))
        body.addArrangedSubview(foot("墨指 v1.8.41 · 真·系统输入法 · 数据仅在同一 WiFi 内传输"))
    }

    // MARK: - 键盘设置（开关）

    private func renderKbd() {
        body.addArrangedSubview(card([
            navRow("使用教程") { [weak self] in self?.push(.tutorials) },
            actionRow("打开系统设置（请手动进入）") { [weak self] in
                self?.delegate?.settingsToast("设置 → 通用 → 键盘 → 墨指 → 允许完全访问")
            }
        ]))
        body.addArrangedSubview(foot("本键盘是系统键盘扩展，iOS 不允许直接跳转系统设置；请按上面路径手动进入。「允许完全访问」是联网同步与读取剪贴板的前提。"))

        // v1.8.22：删掉这里重复的「快捷符号 / 连续复制 / 局域网同步」三个入口。
        // 设置首页已经各有一份，点进「键盘设置」又看到一层同样的入口就是版面重复。

        body.addArrangedSubview(groupTitle("键盘开关"))
        body.addArrangedSubview(card([
            switchRow("浮层关闭按钮", sub: "键盘内图片预览等浮层右上角显示关闭按钮；系统画中画用自带的 ✕ 关闭",
                      isOn: prefs.floatClose) { [weak self] v in self?.prefs.floatClose = v },
            switchRow("点击直接切换", sub: "长按 ✕ 时直接切换剪贴板／常用语，不再弹出选择列表",
                      isOn: prefs.directSwitch) { [weak self] v in self?.prefs.directSwitch = v },
            switchRow("显示「新内容已保存」提示", isOn: prefs.savedTip) { [weak self] v in
                self?.prefs.savedTip = v
            },
            switchRow("显示清空按钮", sub: "放在剪贴板列表最下边，不单独占一行", isOn: prefs.clearBtn) { [weak self] v in
                self?.prefs.clearBtn = v
                self?.delegate?.settingsDidChange()
            },
            switchRow("空格键滑动移动光标", sub: "按住空格左右滑动移动光标，轻点仍输入空格",
                      isOn: prefs.spaceCursor) { [weak self] v in self?.prefs.spaceCursor = v },
            switchRow("按键震动", sub: "按下任意按键轻震一下；空格滑光标每移动一格也会震",
                      isOn: prefs.cursorHaptic) { [weak self] v in
                self?.prefs.cursorHaptic = v
                QPHapticButton.hapticEnabled = v
            },
            // v1.8.35：按键声音（系统点击音），两端共用同一个开关
            switchRow("按键声音",
                      sub: "按下任意按键播放系统键盘点击音，跟随系统键盘反馈与静音键；主 App 设置 → 键盘设置里是同一个开关",
                      isOn: QPSharedHistory.keySoundOn()) { [weak self] v in
                QPSharedHistory.setKeySound(v)
                self?.delegate?.settingsDidChange()
            },
            // v1.8.23：复制成功的确认震动，与「按下按键就震」分开；两端共用同一个开关
            switchRow("复制成功震动",
                      sub: "复制成功后轻震一下，确认内容已经进剪贴板；主 App 设置 → 局域网同步里是同一个开关",
                      isOn: QPSharedHistory.copyHapticOn()) { [weak self] v in
                QPSharedHistory.setCopyHaptic(v)
                self?.delegate?.settingsDidChange()
            },
            switchRow("发送后自动收起键盘", sub: "默认关闭，可连续发送",
                      isOn: prefs.autoCollapse) { [weak self] v in self?.prefs.autoCollapse = v },
            switchRow("键盘可见时自动抓取", sub: "键盘弹着的时候，连续复制第 2、3、N 段都会实时进列表，无需收起再弹出",
                      isOn: prefs.continuous) { [weak self] v in self?.prefs.continuous = v },
            // v1.8.22：两端共用开关。点一条旧记录上屏后把它排到列表最前，
            // 主 App 设置 → 局域网同步里是同一个开关。
            switchRow("复制后移到最前",
                      sub: "点一条旧记录使用后自动排到列表最前；系统里复制新内容一直都会置顶。两端共用这个开关",
                      isOn: QPSharedHistory.moveUsedToTopOn()) { [weak self] v in
                QPSharedHistory.setMoveUsedToTop(v)
                self?.delegate?.settingsDidChange()
            },
            // 原「连续复制」子页里唯一真正有用的设置，搬到开关区，页面本身不再保留入口
            cycleRow("存储位置", values: ["剪贴板历史", "常用语"],
                     selected: prefs.storage == "常用语" ? 1 : 0) { [weak self] i in
                self?.prefs.storage = i == 0 ? "剪贴板历史" : "常用语"
                self?.render()
            }
        ]))

        body.addArrangedSubview(groupTitle("✕ 键删除手势"))
        body.addArrangedSubview(card([
            info("轻点删除光标前一个字；原地长按连续逐字删、每删一个轻震并出轻音；上滑清空、下滑恢复、按住左滑逐字删全部保留。快捷菜单在左边「收起键盘」键长按。"),
            info("※ 这些手势在真键盘里已实现，不需要额外开关。")
        ]))

        body.addArrangedSubview(groupTitle("布局"))
        body.addArrangedSubview(card([
            stepperRow("键盘增高", value: "\(Int(prefs.height))") { [weak self] d in
                guard let self = self else { return }
                self.prefs.height = min(max(self.prefs.height + CGFloat(d * 20), 240), 360)
                self.delegate?.settingsDidChange()
                self.render()
            },
            cycleRow("列表列数", values: ["1 列", "2 列"], selected: prefs.columns - 1) { [weak self] i in
                self?.prefs.columns = i + 1
                self?.delegate?.settingsDidChange()
                self?.render()
            },
            cycleRow("工具条按钮对齐", values: ["居左", "居中", "居右"],
                     selected: ["left", "center", "right"].firstIndex(of: prefs.align) ?? 0) { [weak self] i in
                self?.prefs.align = ["left", "center", "right"][i]
                self?.syncSymbolsToApp()
                self?.delegate?.settingsDidChange()
                self?.render()
            }
        ]))
        body.addArrangedSubview(foot("键盘高度与列数即时生效；工具条对齐在下次呼出键盘时完全刷新。"))

        body.addArrangedSubview(groupTitle("如何启用键盘"))
        body.addArrangedSubview(card(
            ["打开「设置」应用", "进入「通用」→「键盘」→「键盘」", "点击「添加新键盘…」",
             "选择「墨指」", "点击「墨指」并开启「允许完全访问」"]
                .enumerated().map { numberedRow($0.offset + 1, $0.element) }
        ))

        body.addArrangedSubview(groupTitle("使用说明"))
        body.addArrangedSubview(card([
            qa("为什么每次复制都会出现「是否允许粘贴」？",
               "点「允许」即可；也可在系统设置里把「从其他 App 粘贴」设为「允许」。"),
            qa("键盘里看不到同步记录？",
               "确认已开启「允许完全访问」、电脑服务已启动、手机与电脑在同一 WiFi，且地址正确。"),
            qa("密码框里没有 墨指 键盘？",
               "iOS 在密码框等敏感输入会强制使用系统键盘，这是系统限制。")
        ]))
    }

    // MARK: - 快捷符号设置

    /// v1.8.22：键盘里改了符号 / 数量 / 对齐，回写共享通道，主 App 跟随。
    /// 记下写入时间戳，免得下次 refreshSymbols 又拿同一份值覆盖键盘。
    private func syncSymbolsToApp() {
        prefs.symbolsAt = QPSharedHistory.setSharedSymbols(
            prefs.symbols, count: prefs.symbolCount, align: prefs.align)
    }

    private func renderSymbols() {
        body.addArrangedSubview(foot("工具条中间显示常用符号，点一下插入光标处。排在前面的优先显示，放不下的可在符号区左右滑动查看。"))

        body.addArrangedSubview(groupTitle("工具条按钮对齐"))
        body.addArrangedSubview(card([
            cycleRow("对齐方式", values: ["居左", "居中", "居右"],
                     selected: ["left", "center", "right"].firstIndex(of: prefs.align) ?? 0) { [weak self] i in
                self?.prefs.align = ["left", "center", "right"][i]
                self?.syncSymbolsToApp()
                self?.delegate?.settingsDidChange()
                self?.render()
            },
            info("键盘、地球、连续复制这三个按钮可整体居左、居中或居右。")
        ]))

        body.addArrangedSubview(groupTitle("当前符号（\(prefs.symbols.count)）"))
        var rows: [UIView] = []
        for (i, sym) in prefs.symbols.enumerated() {
            rows.append(symbolRow(index: i, symbol: sym,
                                  canUp: i > 0, canDown: i < prefs.symbols.count - 1,
                                  canDelete: prefs.symbols.count > 1))
        }
        rows.append(addSymbolRow())
        body.addArrangedSubview(card(rows))

        body.addArrangedSubview(groupTitle("工具条显示数量"))
        body.addArrangedSubview(card([
            cycleRow("显示数量", values: ["2 个", "3 个", "4 个", "5 个"],
                     selected: max(0, min(3, prefs.symbolCount - 2))) { [weak self] i in
                self?.prefs.symbolCount = i + 2
                self?.syncSymbolsToApp()
                self?.delegate?.settingsDidChange()
                self?.render()
            },
            info("空间不足时自动收起，最少保留两个。")
        ]))

        body.addArrangedSubview(groupTitle("收起键盘键"))
        body.addArrangedSubview(card([
            info("工具条左一：轻点收起／展开键盘；长按 2 秒打开设置与菜单，菜单里可切换系统键盘。切换下一个键盘仍是旁边的地球按钮。")
        ]))
        body.addArrangedSubview(groupTitle("剪贴板／常用语切换"))
        body.addArrangedSubview(card([
            info("最右 ✕ 键手势：轻点删除光标前一个字；上滑清空文字；下滑恢复刚删的文字。长按 2 秒打开菜单。")
        ]))

        body.addArrangedSubview(card([
            actionRow("恢复默认符号") { [weak self] in
                self?.prefs.symbols = ["。", "，", "？", "！", "：", "；", "、", "…", "～", "「", "」", "（", "）", "·", "—"]
                self?.prefs.symbolCount = 4
                self?.prefs.align = "left"
                self?.syncSymbolsToApp()
                self?.delegate?.settingsDidChange()
                self?.delegate?.settingsToast("已恢复默认符号")
                self?.render()
            }
        ]))
    }

    // MARK: - 连续复制设置

    private func renderContinuous() {
        body.addArrangedSubview(foot("连续复制分两种：键盘弹着时自动实时抓取；以及主 App 的系统画中画（PiP）——键盘收起后靠它继续在后台收录。"))

        body.addArrangedSubview(groupTitle("存储位置"))
        body.addArrangedSubview(card([
            cycleRow("存储位置", values: ["剪贴板历史", "常用语"],
                     selected: prefs.storage == "常用语" ? 1 : 0) { [weak self] i in
                self?.prefs.storage = i == 0 ? "剪贴板历史" : "常用语"
                self?.render()
            },
            switchRow("连续复制（键盘内实时抓取）", sub: "键盘弹着时每 0.5 秒比一次剪贴板版本号，变了才读正文；按钮变蓝 + 绿点 = 主 App 后台小窗也在抓",
                      isOn: prefs.continuous) { [weak self] v in self?.prefs.continuous = v }
        ]))

        body.addArrangedSubview(groupTitle("系统画中画（跨 App 连续复制）"))
        body.addArrangedSubview(card([
            numberedRow(1, "打开 墨指 主 App → 连续复制页 → 点「开启连续复制」（自动开小窗）"),
            numberedRow(2, "跳不动就回主屏点 墨指 图标，进去照样会自动开"),
            numberedRow(3, "★ 设置 → 墨指 → 从其他 App 粘贴 → 允许（不设成允许，后台只能读到空内容）"),
            numberedRow(4, "小窗出现 = 正在后台监控；拖到屏幕边缘会缩成图标，点小窗上的 ✕ 结束")
        ]))
        body.addArrangedSubview(foot("还需为键盘开启「允许完全访问」、系统「自动开启画中画」。小窗关掉、App 被划掉就停止后台收录。"))

        body.addArrangedSubview(groupTitle("补充说明"))
        body.addArrangedSubview(card([
            qa("相同内容会重复保存吗？", "不会。相同文字会去重处理，不会不断新增相同记录。"),
            qa("为什么一开始只收录一条？", "iOS 16 起，后台读剪贴板必须先在 设置 → 墨指 → 从其他 App 粘贴 里选「允许」。没设成允许时，App 在前台能读到、切后台就只能读到空内容，于是永远停在「已收录 1 条」。"),
            qa("多久会清理一次？", "按设置里的「历史保留时间」执行，置顶的记录不会被自动清理。"),
            qa("能像悬浮窗那样一直监控吗？", "能。打开主 App 的「连续复制」页开启系统画中画（PiP），小窗由 iOS 渲染，自带 ✕、可拖到屏幕边缘缩小贴边。键盘扩展本身不能在别处常驻，所以这一步必须由主 App 启动。")
        ]))
        body.addArrangedSubview(card([
            actionRow("在键盘里试一下 →") { [weak self] in self?.close() }
        ]))
    }

    // MARK: - 局域网同步设置

    private func renderSync() {
        let s = delegate?.settingsStatus() ?? (title: "未连接", count: 0, url: "", backend: "")
        body.addArrangedSubview(groupTitle("连接状态"))
        body.addArrangedSubview(card([
            info("状态：\(s.title)　·　记录 \(s.count) 条"),
            info("后端：\(s.backend.isEmpty ? "—" : s.backend)"),
            info("当前地址：\(s.url)")
        ]))

        body.addArrangedSubview(groupTitle("电脑地址"))
        let urlRow = textFieldRow(placeholder: "http://192.168.1.2:8787", text: prefs.syncURL)
        urlField = urlRow.1
        body.addArrangedSubview(card([
            urlRow.0,
            actionRow("保存地址并立即同步") { [weak self] in
                guard let self = self, let raw = self.urlField?.text else { return }
                self.prefs.syncURL = raw
                self.delegate?.settingsToast("已保存：" + self.prefs.syncURL)
                self.delegate?.settingsSyncNow()
                self.render()
            },
            actionRow("📥 用剪贴板里的电脑地址") { [weak self] in
                guard let self = self else { return }
                let ok = self.delegate?.settingsAdoptURL() ?? false
                self.delegate?.settingsToast(ok ? "地址已更新：" + self.prefs.syncURL
                                             : "剪贴板里没有有效地址（需 http://…:8787）")
                if ok { self.delegate?.settingsSyncNow() }
                self.render()
            },
            actionRow("↺ 重置为默认地址 192.168.1.2") { [weak self] in
                self?.delegate?.settingsResetURL()
                self?.delegate?.settingsSyncNow()
                self?.render()
            }
        ]))

        body.addArrangedSubview(groupTitle("配对码（电脑端设了才填）"))
        let pairRow = textFieldRow(placeholder: "可留空", text: prefs.syncPair)
        pairField = pairRow.1
        body.addArrangedSubview(card([
            pairRow.0,
            actionRow("保存配对码") { [weak self] in
                self?.prefs.syncPair = self?.pairField?.text ?? ""
                self?.delegate?.settingsToast("配对码已保存")
                self?.delegate?.settingsSyncNow()
            }
        ]))

        body.addArrangedSubview(groupTitle("连接开关"))
        body.addArrangedSubview(card([
            switchRow("连接电脑",
                      sub: "两端共用这一个开关（主 App 端改了，键盘下次出现跟随；这里改了，主 App 也跟随）。断开后不再轮询、不再自动推送；手动「立即同步」仍可临时连一次",
                      isOn: !QPSharedHistory.syncOff()) { [weak self] v in
                QPSharedHistory.setSyncOff(!v)
                self?.delegate?.settingsDidChange()
            },
            switchRow("复制后自动发到电脑",
                      sub: "手机上一复制，电脑那边立刻就有这条（电脑没连上会排队，连上补发）",
                      isOn: prefs.autoPush) { [weak self] v in
                self?.prefs.autoPush = v
            },
            switchRow("自动同步（每 3 秒）", isOn: prefs.syncAuto) { [weak self] v in
                self?.prefs.syncAuto = v
                self?.delegate?.settingsDidChange()
            },
            switchRow("断网自动暂停同步",
                      sub: "手机断开 Wi-Fi（或只剩流量）时自动停止同步轮询，不再反复刷新浪费电；回到 Wi-Fi 自动恢复。两端共用这个开关",
                      isOn: QPSharedHistory.netGuardOn()) { [weak self] v in
                QPSharedHistory.setNetGuard(v)
                self?.delegate?.settingsDidChange()
            },
            switchRow("导出到电脑",
                      sub: "开：剪贴板面板的导出文件发送到电脑「下载\\墨指导出」文件夹；关：文本导出直接复制到剪贴板（二进制格式请到主 App 分享）。两端共用这个开关",
                      isOn: QPSharedHistory.exportToPcOn()) { [weak self] v in
                QPSharedHistory.setExportToPc(v)
                self?.delegate?.settingsDidChange()
            },
            actionRow("⟳ 立即同步") { [weak self] in
                self?.delegate?.settingsSyncNow()
                self?.delegate?.settingsToast("正在同步…")
            }
        ]))

        body.addArrangedSubview(groupTitle("发送到电脑"))
        body.addArrangedSubview(card([
            actionRow("↑ 发送输入框文字") { [weak self] in self?.delegate?.settingsSendInputText() },
            actionRow("📋 发送剪贴板文字") { [weak self] in self?.delegate?.settingsSendPasteboardText() },
            actionRow("🖼 发送剪贴板图片") { [weak self] in self?.delegate?.settingsSendPasteboardImage() },
            actionRow("🗑 清空电脑上的全部同步记录", tint: .systemRed) { [weak self] in
                self?.delegate?.settingsClearAll()
            }
        ]))
        body.addArrangedSubview(foot("电脑端需启动 墨指 同步服务（v1.8.41），手机与电脑连同一 WiFi。图片以 HTTP 二进制直传，不经公网。"))
    }

    // MARK: - 教程

    private func renderTutorialList() {
        body.addArrangedSubview(foot("按最新原型的 6 篇使用教程，内容对应真输入法的实际操作。"))
        body.addArrangedSubview(card(Tutorial.order.map { key in
            navRow(Tutorial.data[key]?.title ?? key) { [weak self] in self?.push(.tutorial(key)) }
        }))
    }

    private func renderTutorial(_ key: String) {
        guard let t = Tutorial.data[key] else { return }
        body.addArrangedSubview(card([info(t.summary)]))
        for (i, sec) in t.sections.enumerated() {
            body.addArrangedSubview(groupTitle("\(i + 1). \(sec.0)"))
            body.addArrangedSubview(card([info(sec.1)]))
        }
        body.addArrangedSubview(card([
            actionRow("在键盘里试一下 →") { [weak self] in self?.close() }
        ]))
    }

    // MARK: - 历史 / 最近删除 / 引导 / 关于

    private func renderHistory() {
        let list = prefs.items(for: "clip")
        body.addArrangedSubview(foot("本机剪贴板历史（键盘内保存，最多 100 条）。点一条插入到当前输入框。"))
        if list.isEmpty {
            body.addArrangedSubview(card([info("还没有记录。在别的 App 复制文字后，回到 墨指 键盘即可收录。")]))
        } else {
            body.addArrangedSubview(card(list.map { text in
                actionRow(String(text.prefix(40))) { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.settingsInsertText(text)
                    self.close()
                }
            }))
        }
        body.addArrangedSubview(card([
            navRow("最近删除", value: "\(prefs.recentDeleted.count) 条") { [weak self] in self?.push(.recentDeleted) },
            actionRow("清除本机全部历史", tint: .systemRed) { [weak self] in self?.confirmClearHistory() }
        ]))
    }

    private func renderRecentDeleted() {
        let list = prefs.recentDeleted
        if list.isEmpty {
            body.addArrangedSubview(card([info("最近删除是空的。")]))
        } else {
            body.addArrangedSubview(card(list.map { text in
                actionRow("↺ " + String(text.prefix(36))) { [weak self] in
                    self?.prefs.restore(text)
                    self?.delegate?.settingsDidChange()
                    self?.delegate?.settingsToast("已恢复")
                    self?.render()
                }
            }))
            body.addArrangedSubview(card([
                actionRow("清空最近删除", tint: .systemRed) { [weak self] in
                    self?.prefs.recentDeleted = []
                    self?.render()
                }
            ]))
        }
    }

    private func renderOnboarding() {
        body.addArrangedSubview(bigTitle("启用 墨指"))
        body.addArrangedSubview(card([
            numberedRow(1, "安装后用爱思助手 / 手机端签名工具完成 7 天签名"),
            numberedRow(2, "设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 墨指"),
            numberedRow(3, "点开 墨指 → 开启「允许完全访问」"),
            numberedRow(4, "打开主 App，填电脑地址 http://192.168.1.2:8787 并保存"),
            numberedRow(5, "在任意 App 输入框按地球仪切到 墨指 即可使用")
        ]))
        body.addArrangedSubview(foot("键盘里：点卡片直接上屏；💻 = 电脑复制，📱 = 手机发的；图片显示缩略图；底行蓝色「发送」把输入框文字发回电脑。"))
        body.addArrangedSubview(card([
            actionRow("开始使用 →") { [weak self] in self?.close() }
        ]))
    }

    private func renderAbout() {
        body.addArrangedSubview(card([
            info("墨指 v1.8.17 · 真·系统输入法"),
            info("iOS：键盘扩展 .appex（com.apple.keyboard-service）"),
            info("安卓：系统输入法 InputMethodService"),
            info("界面按 最新版原型原生实现，无 WebView、无演示动画。"),
            info("数据只在你的局域网内传输，不经过公网。"),
            info("免费 Apple ID 签名 7 天到期后需重签，键盘内数据不会丢失。")
        ]))
    }

    // MARK: - 交互动作

    /// 键盘扩展里不弹系统 UIAlertController（会跳出键盘边界），用本面板内的确认页
    private func confirmClearHistory() { push(.confirmClearHistory) }

    private func renderConfirmClear() {
        body.addArrangedSubview(card([
            info("将清空本机剪贴板历史与最近删除，并删除电脑上的全部同步记录。此操作不可撤销。")
        ]))
        body.addArrangedSubview(card([
            actionRow("确认清除", tint: .systemRed) { [weak self] in
                guard let self = self else { return }
                self.prefs.clips = []
                self.prefs.clipTimes = []
                self.prefs.recentDeleted = []
                self.delegate?.settingsClearAll()
                self.delegate?.settingsDidChange()
                self.delegate?.settingsToast("历史已清除")
                self.back()
            },
            actionRow("取消") { [weak self] in self?.back() }
        ]))
    }

    private func moveSymbol(from: Int, to: Int) {
        var arr = prefs.symbols
        guard from >= 0, from < arr.count, to >= 0, to < arr.count else { return }
        arr.swapAt(from, to)
        prefs.symbols = arr
        syncSymbolsToApp()
        delegate?.settingsDidChange()
        render()
    }

    private func deleteSymbol(at: Int) {
        var arr = prefs.symbols
        guard arr.count > 1, at >= 0, at < arr.count else { return }
        arr.remove(at: at)
        prefs.symbols = arr
        syncSymbolsToApp()
        delegate?.settingsDidChange()
        render()
    }

    // MARK: - 通用行组件

    private func bigTitle(_ text: String) -> UIView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 24, weight: .bold)
        l.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return l
    }

    private func groupTitle(_ text: String) -> UIView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabel
        l.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return l
    }

    private func foot(_ text: String) -> UIView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }

    private func card(_ rows: [UIView]) -> UIView {
        let box = UIView()
        box.backgroundColor = .secondarySystemBackground
        box.layer.cornerRadius = 10
        box.clipsToBounds = true
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2)
        ])
        for (i, r) in rows.enumerated() where i > 0 {
            let sep = UIView()
            sep.backgroundColor = .separator
            sep.isUserInteractionEnabled = false
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
            r.addSubview(sep)
            NSLayoutConstraint.activate([
                sep.leadingAnchor.constraint(equalTo: r.leadingAnchor, constant: 14),
                sep.trailingAnchor.constraint(equalTo: r.trailingAnchor),
                sep.topAnchor.constraint(equalTo: r.topAnchor)
            ])
        }
        return box
    }

    private func promoCard() -> UIView {
        let box = UIView()
        box.backgroundColor = QPColor.blueSoft
        box.layer.cornerRadius = 10
        let l = UILabel()
        l.text = "墨指 v1.8.17 · 真·系统输入法\n按 HTML 最新版效果原生实现，无网页、无演示动画"
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = QPColor.blue
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            l.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)
        ])
        return box
    }

    private func navRow(_ title: String, value: String = "", tint: UIColor? = nil,
                        action: @escaping () -> Void) -> UIView {
        let row = UIView()
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        let l = UILabel()
        l.text = title
        l.font = .systemFont(ofSize: 14)
        l.textColor = tint ?? .label
        let v = UILabel()
        v.text = value
        v.font = .systemFont(ofSize: 12)
        v.textColor = .secondaryLabel
        let chev = UILabel()
        chev.text = "›"
        chev.font = .systemFont(ofSize: 18)
        chev.textColor = .tertiaryLabel
        let s = UIStackView(arrangedSubviews: [l, v, chev])
        s.axis = .horizontal
        s.spacing = 8
        s.alignment = .center
        s.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            s.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            s.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            s.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6)
        ])
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let b = QPHapticButton(type: .custom)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        row.addSubview(b)
        NSLayoutConstraint.activate([
            b.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            b.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            b.topAnchor.constraint(equalTo: row.topAnchor),
            b.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    private func actionRow(_ title: String, tint: UIColor? = nil,
                           action: @escaping () -> Void) -> UIView {
        let b = QPHapticButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14)
        b.setTitleColor(tint ?? QPColor.blue, for: .normal)
        b.contentHorizontalAlignment = .leading
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func switchRow(_ title: String, sub: String = "", isOn: Bool,
                           onChange: @escaping (Bool) -> Void) -> UIView {
        let row = UIView()
        let texts = UIStackView()
        texts.axis = .vertical
        texts.spacing = 2
        let l = UILabel()
        l.text = title
        l.font = .systemFont(ofSize: 14)
        l.numberOfLines = 0
        texts.addArrangedSubview(l)
        if !sub.isEmpty {
            let s = UILabel()
            s.text = sub
            s.font = .systemFont(ofSize: 11)
            s.textColor = .secondaryLabel
            s.numberOfLines = 0
            texts.addArrangedSubview(s)
        }
        let sw = UISwitch()
        sw.isOn = isOn
        sw.onTintColor = QPColor.blue
        sw.setContentHuggingPriority(.required, for: .horizontal)
        sw.addAction(UIAction { [weak sw] _ in onChange(sw?.isOn ?? false) }, for: .valueChanged)
        let h = UIStackView(arrangedSubviews: [texts, sw])
        h.axis = .horizontal
        h.spacing = 10
        h.alignment = .center
        h.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            h.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8)
        ])
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return row
    }

    private func stepperRow(_ title: String, value: String,
                            onStep: @escaping (Int) -> Void) -> UIView {
        let row = UIView()
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        let l = UILabel()
        l.text = title
        l.font = .systemFont(ofSize: 14)
        let v = UILabel()
        v.text = value
        v.font = .systemFont(ofSize: 14, weight: .medium)
        v.textColor = QPColor.blue
        let minus = QPHapticButton(type: .system)
        minus.setTitle("−", for: .normal)
        minus.titleLabel?.font = .systemFont(ofSize: 20)
        minus.widthAnchor.constraint(equalToConstant: 40).isActive = true
        minus.addAction(UIAction { _ in onStep(-1) }, for: .touchUpInside)
        let plus = QPHapticButton(type: .system)
        plus.setTitle("+", for: .normal)
        plus.titleLabel?.font = .systemFont(ofSize: 20)
        plus.widthAnchor.constraint(equalToConstant: 40).isActive = true
        plus.addAction(UIAction { _ in onStep(1) }, for: .touchUpInside)
        let h = UIStackView(arrangedSubviews: [l, v, minus, plus])
        h.axis = .horizontal
        h.spacing = 8
        h.alignment = .center
        h.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            h.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func cycleRow(_ title: String, values: [String], selected: Int,
                          onSelect: @escaping (Int) -> Void) -> UIView {
        let row = UIView()
        let l = UILabel()
        l.text = title
        l.font = .systemFont(ofSize: 14)
        l.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            l.topAnchor.constraint(equalTo: row.topAnchor, constant: 10)
        ])
        let seg = UISegmentedControl(items: values)
        seg.selectedSegmentIndex = selected
        seg.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 12)], for: .normal)
        seg.translatesAutoresizingMaskIntoConstraints = false
        seg.addAction(UIAction { [weak seg] _ in onSelect(seg?.selectedSegmentIndex ?? 0) }, for: .valueChanged)
        row.addSubview(seg)
        NSLayoutConstraint.activate([
            seg.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            seg.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            seg.topAnchor.constraint(equalTo: l.bottomAnchor, constant: 6),
            seg.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            seg.heightAnchor.constraint(equalToConstant: 28)
        ])
        return row
    }

    private func info(_ text: String) -> UIView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12)
        l.textColor = .label
        l.numberOfLines = 0
        let box = UIView()
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            l.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9)
        ])
        return box
    }

    private func numberedRow(_ n: Int, _ text: String) -> UIView {
        let badge = UILabel()
        badge.text = "\(n)"
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = QPColor.blue
        badge.textAlignment = .center
        badge.layer.cornerRadius = 10
        badge.clipsToBounds = true
        badge.widthAnchor.constraint(equalToConstant: 20).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 13)
        l.numberOfLines = 0
        let h = UIStackView(arrangedSubviews: [badge, l])
        h.axis = .horizontal
        h.spacing = 10
        h.alignment = .top
        h.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        box.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            h.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            h.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            h.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9)
        ])
        return box
    }

    private func qa(_ q: String, _ a: String) -> UIView {
        let ql = UILabel()
        ql.text = "问：\(q)"
        ql.font = .systemFont(ofSize: 12, weight: .medium)
        ql.numberOfLines = 0
        let al = UILabel()
        al.text = "答：\(a)"
        al.font = .systemFont(ofSize: 12)
        al.textColor = .secondaryLabel
        al.numberOfLines = 0
        let s = UIStackView(arrangedSubviews: [ql, al])
        s.axis = .vertical
        s.spacing = 4
        s.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        box.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            s.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            s.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            s.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9)
        ])
        return box
    }

    /// 返回 (供 card 使用的容器行, 可读取文本的 field)
    private func textFieldRow(placeholder: String, text: String) -> (UIView, UITextField) {
        let f = UITextField()
        f.placeholder = placeholder
        f.text = text
        f.font = .systemFont(ofSize: 13)
        f.borderStyle = .roundedRect
        f.backgroundColor = .tertiarySystemBackground
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.keyboardType = .URL
        f.returnKeyType = .done
        f.delegate = self
        f.heightAnchor.constraint(equalToConstant: 34).isActive = true
        f.translatesAutoresizingMaskIntoConstraints = false
        let holder = UIView()
        holder.addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
            f.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14),
            f.topAnchor.constraint(equalTo: holder.topAnchor, constant: 8),
            f.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -8)
        ])
        return (holder, f)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func symbolRow(index: Int, symbol: String, canUp: Bool, canDown: Bool,
                           canDelete: Bool) -> UIView {
        let row = UIView()
        row.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let idx = UILabel()
        idx.text = "\(index + 1)"
        idx.font = .systemFont(ofSize: 12)
        idx.textColor = .secondaryLabel
        idx.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let ch = UILabel()
        ch.text = symbol
        ch.font = .systemFont(ofSize: 17)
        let grow = UIView()
        grow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let up = miniButton("↑", enabled: canUp) { [weak self] in self?.moveSymbol(from: index, to: index - 1) }
        let down = miniButton("↓", enabled: canDown) { [weak self] in self?.moveSymbol(from: index, to: index + 1) }
        let del = miniButton("✕", enabled: canDelete, danger: true) { [weak self] in self?.deleteSymbol(at: index) }
        let h = UIStackView(arrangedSubviews: [idx, ch, grow, up, down, del])
        h.axis = .horizontal
        h.spacing = 6
        h.alignment = .center
        h.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            h.topAnchor.constraint(equalTo: row.topAnchor),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    private func addSymbolRow() -> UIView {
        let row = UIView()
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let f = UITextField()
        f.placeholder = "输入要添加的符号"
        f.font = .systemFont(ofSize: 13)
        f.borderStyle = .roundedRect
        f.backgroundColor = .tertiarySystemBackground
        f.returnKeyType = .done
        f.delegate = self
        f.translatesAutoresizingMaskIntoConstraints = false
        symbolField = f
        let add = QPHapticButton(type: .system)
        add.setTitle("添加", for: .normal)
        add.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        add.widthAnchor.constraint(equalToConstant: 52).isActive = true
        add.addAction(UIAction { [weak self] _ in
            guard let self = self,
                  let s = self.symbolField?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return }
            var arr = self.prefs.symbols
            arr.append(String(s.prefix(4)))
            self.prefs.symbols = arr
            self.syncSymbolsToApp()
            self.delegate?.settingsDidChange()
            self.delegate?.settingsToast("已添加 " + s)
            self.render()
        }, for: .touchUpInside)
        let h = UIStackView(arrangedSubviews: [f, add])
        h.axis = .horizontal
        h.spacing = 8
        h.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            h.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4)
        ])
        return row
    }

    private func miniButton(_ title: String, enabled: Bool, danger: Bool = false,
                            action: @escaping () -> Void) -> UIButton {
        let b = QPHapticButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14)
        b.setTitleColor(danger ? .systemRed : QPColor.blue, for: .normal)
        b.isEnabled = enabled
        b.alpha = enabled ? 1 : 0.3
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }
}

// MARK: - 教程数据（按原型 TUT 原文整理）

private enum Tutorial {
    static let order = ["keyboard", "history", "category", "split", "continuous", "calc"]

    struct Item {
        let title: String
        let summary: String
        let sections: [(String, String)]
    }

    static let data: [String: Item] = [
        "keyboard": Item(title: "启用键盘与发送", summary: "系统设置 → 通用 → 键盘，添加 墨指，并开启完全访问。", sections: [
            ("首次启用", "1. 打开 iPhone / iPad 的系统「设置」。\n2. 进入「通用」→「键盘」→「键盘」→「添加新键盘」。\n3. 选择 墨指，再进入 墨指 键盘设置，开启「允许完全访问」。\n也可在「键盘设置」页查看完整步骤。"),
            ("切换与插入", "在聊天、笔记等 App 中点输入框，长按系统地球键选择 墨指。点一条剪贴板记录或常用语，即可在光标处插入；连续点多条会依次插入。键盘顶部的地球按钮可切到下一个键盘。"),
            ("发送后保持展开", "关闭自动收起时，点「发送」只向输入框提交回车，墨指 不会主动收起键盘，你可以继续选内容。「发送」实际触发发消息还是换行，由当前 App 决定。如果对方 App 主动结束输入，第三方键盘无法强制保持展开，请再次点输入框。"),
            ("完全访问的用途", "用于键盘读取剪贴板、访问局域网同步服务与本机历史/常用语。密码框、部分电话输入框或不允许第三方键盘的 App 可能自动使用系统键盘。"),
            ("发送后自动收起键盘", "默认关闭，可连续发送；开启后，点击「发送」会收起键盘。「输入」计算结果或分词不会收起。")
        ]),
        "history": Item(title: "剪贴板历史", summary: "复制文字后，打开 墨指；点记录即可复用。", sections: [
            ("保存文字", "在其他 App 中复制文字后，切换到 墨指 键盘即可看到。键盘弹着时会实时抓取多段复制；开启主 App 的系统画中画后，切到任意 App 复制也会被后台收录。图片和文件不属于文字历史。"),
            ("搜索与复制", "在键盘的「剪贴板」页上下滚动查找记录。点一条记录直接插入当前输入框；长按记录可复制到系统剪贴板、发送到电脑、放大图片或删除。"),
            ("整理历史", "置顶内容优先显示，也不受历史保留天数的自动清理影响。删除的记录可在设置 →「最近删除」中恢复。"),
            ("显示范围", "本机历史最多保存 100 条；键盘同步列表一次最多显示 30 条电脑记录，可上下滚动。"),
            ("电脑同步记录", "电脑上按 Ctrl+C 的文字和截图，约 1 秒后出现在键盘列表里，💻 表示电脑复制，📱 表示手机发的。图片显示小缩略图，点开可放大。")
        ]),
        "category": Item(title: "常用语与分类", summary: "把常用回复放进分类，在键盘里点一下就输入。", sections: [
            ("新建分类", "在键盘的「常用语」页管理常用回复；本版本用「置顶」代替分类分组，长按条目可置顶。"),
            ("添加常用语", "在「常用语」页长按菜单可编辑；也可在设置页的「连续复制 → 存储位置」里选择把抓取到的文字存到常用语。"),
            ("在键盘中使用", "切换到 墨指 键盘，点顶部的「常用语」Tab；点一条即可在光标处插入，连续点多条会依次插入。"),
            ("整理与排序", "长按常用语可置顶或删除。置顶内容优先显示，方便把高频回复放在最前面。")
        ]),
        "split": Item(title: "拆分选词", summary: "长按历史卡片拆分文字，按点击顺序拼成新句子。", sections: [
            ("进入拆分", "在键盘的剪贴板卡片上长按，选择拆分选词相关操作；文字会被切成多个词块。"),
            ("依次点选", "按顺序点词块，选中的词会依次拼进结果框。点错可以再点一次取消，或点「清空」重新选。"),
            ("插入结果", "点结果框右侧的蓝色上箭头，把拼好的句子插入当前输入框。使用「输入」插入结果时不会自动收起键盘。"),
            ("本版本说明", "拆分选词的完整分词面板需要主 App 配合；当前键盘版提供长按卡片菜单里的「插入到输入框 / 复制到剪贴板 / 发送到电脑」等核心操作。")
        ]),
        "continuous": Item(title: "连续复制与系统画中画", summary: "键盘弹着时实时抓取；开画中画可跨 App 后台监控。", sections: [
            ("键盘里连续复制", "键盘弹着时每 0.5 秒读一次系统剪贴板，复制第 2、3、N 段都会自动进列表，不用收起再弹出。"),
            ("开启系统画中画", "1. 确认键盘已开启完全访问。\n2. 打开 墨指 主 App → 连续复制页 → 点「开启连续复制」，自动开小窗。\n3. ★ 设置 → 墨指 → 从其他 App 粘贴 → 允许，否则后台读不到内容。\n4. 出现系统 PiP 小窗后，切到微信、Safari 等任意 App 继续复制。"),
            ("小窗怎么用", "PiP 小窗由 iOS 渲染，自带 ✕ 关闭；拖到屏幕左边框会自动缩小贴边（只露一个小箭头），点箭头可展开。小窗里大字的「已收录 N 条」才是真正抓到的条数，主 App「连续复制」页的计数同步更新。"),
            ("重复内容与使用范围", "相同文字会去重。画中画收录的文字会写进共享历史，回到键盘自动出现在剪贴板列表里；系统粘贴授权弹窗需点「允许」。")
        ]),
        "calc": Item(title: "键盘计算器", summary: "按键直接写进输入框，点 = 才出结果。", sections: [
            ("开始计算", "点键盘左下角「f(x) 计算」。数字、小数点、括号、加减乘除都直接写进当前 App 的输入框，键盘自己不显示算式。"),
            ("什么时候出结果", "点「=」时，取光标前最后一段算式求值，并把它替换成结果。例如输入 7+8 再点 =，输入框里就变成 15；接着按 +2= 就是 17。"),
            ("改错与退出", "「⌫」删掉输入框里光标前一个字符；「收起」退出计算器面板，回到剪贴板列表。适合快速算金额、数量或比例。")
        ])
    ]
}

