import Foundation

/// v1.8.35「定制工具栏 / 定制菜单栏」的共用功能池。
///
/// 主 App 设置页与键盘扩展读同一份定义：同一个 id 在工具栏显示图标、在菜单栏
/// 显示文字，两栏可以互相挪（上面放啥可以挪下来、下面放啥可以放到上边）。
/// 动作由键盘侧 performBarAction(_:) 统一分发，一个 id 一处实现。
enum QPBarCatalog {

    struct Item {
        let id: String
        let name: String       // 设置页全名（对齐参考图二 / 图三）
        let symbol: String     // 工具栏用的 SF Symbol
        let title: String      // 菜单栏短文字
        let fullAccess: Bool   // 是否需要「允许完全访问」
    }

    /// 参考图二 / 图三 的 14 项 + 工具栏原有 7 项，一个不砍。
    static let all: [Item] = [
        Item(id: "nextKeyboard", name: "切换输入法", symbol: "globe",                  title: "切换",   fullAccess: false),
        Item(id: "dismiss",      name: "关闭键盘",   symbol: "keyboard.chevron.compact.down", title: "关闭", fullAccess: false),
        Item(id: "translate",    name: "中文转译",   symbol: "arrow.triangle.2.circlepath", title: "转译", fullAccess: true),
        Item(id: "screenshot",   name: "截图",       symbol: "camera",                 title: "截图",   fullAccess: true),
        Item(id: "undo",         name: "撤销",       symbol: "arrow.uturn.backward",  title: "撤销",   fullAccess: false),
        Item(id: "cursorLeft",   name: "光标向左",   symbol: "chevron.left",          title: "←",      fullAccess: false),
        Item(id: "cursorRight",  name: "光标向右",   symbol: "chevron.right",         title: "→",      fullAccess: false),
        Item(id: "selectAll",    name: "全选",       symbol: "doc.text",              title: "全选",   fullAccess: true),
        Item(id: "cut",          name: "剪切",       symbol: "scissors",              title: "剪切",   fullAccess: true),
        Item(id: "copy",         name: "复制",       symbol: "doc.on.doc",            title: "复制",   fullAccess: true),
        Item(id: "paste",        name: "粘贴",       symbol: "doc.on.clipboard",      title: "粘贴",   fullAccess: true),
        Item(id: "redo",         name: "重做",       symbol: "arrow.uturn.forward",   title: "重做",   fullAccess: false),
        Item(id: "delete",       name: "删除",       symbol: "delete.left",           title: "删除",   fullAccess: false),
        Item(id: "moveStart",    name: "移动开头",   symbol: "arrow.left.to.line",    title: "开头",   fullAccess: false),
        Item(id: "moveEnd",      name: "移动结尾",   symbol: "arrow.right.to.line",   title: "结尾",   fullAccess: false),
        // 工具栏原有 7 项，同样纳入池子，可以挪到菜单栏
        Item(id: "collapse",     name: "收起键盘",   symbol: "chevron.down",          title: "收起",   fullAccess: false),
        Item(id: "filter",       name: "筛选",       symbol: "line.3.horizontal.decrease", title: "筛选", fullAccess: false),
        Item(id: "sort",         name: "排序",       symbol: "arrow.up.arrow.down",   title: "排序",   fullAccess: false),
        Item(id: "phrase",       name: "常用语",     symbol: "note.text",             title: "常用语", fullAccess: false),
        Item(id: "symbols",      name: "快捷符号",   symbol: "textformat",            title: "符号",   fullAccess: false),
        Item(id: "status",       name: "连接状态",   symbol: "circle.fill",           title: "状态",   fullAccess: false),
        Item(id: "clear",        name: "清除键 ✕",   symbol: "xmark",                 title: "清除",   fullAccess: false)
    ]

    /// 不改设置时的默认版面 = 与 v1.8.34 真机验证通过的版面 1:1 一致。
    static let defaultToolbar = ["collapse", "filter", "sort", "phrase", "symbols", "status", "clear"]
    static let defaultMenu    = ["nextKeyboard", "dismiss", "paste", "undo", "selectAll"]

    static func item(_ id: String) -> Item? { all.first { $0.id == id } }
    static func name(_ id: String) -> String { item(id)?.name ?? id }
    static func symbol(_ id: String) -> String { item(id)?.symbol ?? "questionmark.circle" }
    static func title(_ id: String) -> String { item(id)?.title ?? name(id) }
    static func needsFullAccess(_ id: String) -> Bool { item(id)?.fullAccess ?? false }

    /// 去重 + 丢掉不认识的 id：旧版本残留 / 手改坏的配置不会让键盘崩。
    static func sanitize(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids where item(id) != nil && !seen.contains(id) {
            seen.insert(id)
            out.append(id)
        }
        return out
    }
}
