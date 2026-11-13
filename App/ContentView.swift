import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("九宫格拼音键盘")
                        .font(.largeTitle).bold()
                    Text("本 App 是「自定义键盘扩展」的宿主。真正的键盘不会在这里出现，而是要在系统设置里启用后，在任意输入框切换使用。")
                        .foregroundColor(.secondary)

                    Group {
                        Text("如何启用").font(.headline)
                        Text("1. 先在 Xcode 里把本工程跑到真机或模拟器（需要开发者账号）。")
                        Text("2. 打开 iPhone「设置 › 通用 › 键盘 › 键盘 › 添加新键盘」，选择本键盘。")
                        Text("3. 在同一页点进本键盘，打开「允许完全访问」（剪贴板功能需要）。")
                        Text("4. 在任意输入框，长按 🌐 或地球键切换到本键盘。")
                    }

                    Group {
                        Text("功能").font(.headline)
                        Text("· 中文 9 键（T9 拼音）+ 中文 26 键切换")
                        Text("· 英文 26 键 / 数字 / 符号")
                        Text("· 剪贴板（需完全访问）")
                        Text("· 语境联想 + 个人词频学习 + 细胞词库（网络热词示例）")
                    }

                    Text("说明：本键盘为本地运行，不联网。词库来自开源 pinyin-data / phrase-pinyin-data。与商业输入法相比仍属早期，后续可继续迭代。")
                        .font(.footnote).foregroundColor(.secondary)
                }
                .padding()
            }
            .navigationTitle("说明")
        }
    }
}
