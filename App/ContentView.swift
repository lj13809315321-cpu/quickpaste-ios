import SwiftUI
import UIKit

/// 主应用：键盘扩展的宿主与启用说明页。
/// 键盘的设置与数据都保存在扩展自身，主应用不与扩展共享容器，
/// 因此手机端用一份通配符应用标识的描述文件重签即可，不需要额外的应用组授权。
struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("启用键盘") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. 打开「设置」→「通用」→「键盘」→「键盘」")
                        Text("2. 点「添加新键盘…」选择 QuickPaste")
                        Text("3. 进入 QuickPaste，开启「允许完全访问」")
                    }
                    .font(.subheadline)
                    Button("打开本应用设置页") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section("键盘操作") {
                    Label("剪贴板 / 常用语：顶部两个标签切换", systemImage: "rectangle.split.2x1")
                    Label("点一条内容：插入到光标处", systemImage: "text.insert")
                    Label("长按一条内容：置顶或删除", systemImage: "hand.tap")
                    Label("✕ 轻点退格，上滑清空，下滑恢复", systemImage: "delete.left")
                    Label("⌄ 轻点收起键盘，长按 2 秒打开设置", systemImage: "chevron.down.circle")
                    Label("⧉ 连续复制：蓝色为开启，自动记录新复制的文字", systemImage: "doc.on.doc")
                    Label("空格键按住左右滑动：移动光标", systemImage: "arrow.left.and.right")
                    Label("ƒ(x) 计算：算完可把结果插进输入框", systemImage: "function")
                    Label("🌐 切换到下一个键盘", systemImage: "globe")
                }

                Section("设置入口") {
                    Text("长按左上角的「⌄」或最右侧的「✕」两秒，可以打开键盘设置：列数、键盘高度、空格滑动、发送后收起、快捷符号。")
                        .font(.subheadline)
                }

                Section("已知限制") {
                    Text("「发送」只能插入换行，iOS 不允许第三方键盘直接触发宿主应用里的发送按钮。")
                    Text("剪贴板记录需要开启「允许完全访问」，未开启时键盘无法读取系统剪贴板。")
                    Text("密码框、电话号码框中系统会强制使用原生键盘。")
                }
            }
            .navigationTitle("QuickPaste")
        }
    }
}
