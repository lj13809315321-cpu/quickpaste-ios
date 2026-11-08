import SwiftUI
import UIKit
import WebKit

/// QuickPaste 同步版（iOS）：全屏 WKWebView 打开电脑上的同步服务页面。
/// 功能（文字 / 图片 / 缩略图 / 来源图标 / 发送图片）全部由电脑端 v1.6 同步页提供。
/// App 只负责：记住电脑地址、允许 HTTP 局域网、首次引导填写地址。
/// 前提：电脑端同步服务已启动，且 iPhone 与电脑在同一 WiFi。
struct ContentView: View {
    @AppStorage("qp_server_url") private var serverURL: String = ""
    @State private var showSetup = false
    @State private var draft = ""
    @State private var reloadToken = 0
    @State private var errorText = ""

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WebView(urlString: serverURL, reloadToken: reloadToken) { msg in
                errorText = msg
            }
            .ignoresSafeArea()

            HStack(spacing: 10) {
                Button { reloadToken += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.blue.opacity(0.9))
                        .clipShape(Circle())
                }
                Button {
                    draft = serverURL
                    showSetup = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.blue.opacity(0.9))
                        .clipShape(Circle())
                }
            }
            .padding(16)
        }
        .onAppear {
            if serverURL.isEmpty {
                draft = "http://192.168.1.2:8787"
                showSetup = true
            }
        }
        .sheet(isPresented: $showSetup) {
            SetupView(draft: $draft, errorText: errorText) { url in
                serverURL = normalize(url)
                reloadToken += 1
                showSetup = false
            }
        }
    }

    private func normalize(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { u = "http://192.168.1.2:8787" }
        if !u.hasPrefix("http://") && !u.hasPrefix("https://") { u = "http://" + u }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }
}

struct SetupView: View {
    @Binding var draft: String
    let errorText: String
    let onConnect: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("电脑地址") {
                    TextField("http://192.168.1.2:8787", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                Section("使用前请确认") {
                    Text("1. 电脑上已启动 QuickPaste 同步服务\n"
                       + "2. iPhone 与电脑连的是同一个 WiFi\n"
                       + "3. 端口默认 8787（若电脑端改过端口，请一并填写）")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("保存后会自动记住，之后打开 App 直接连接。\n"
                       + "文字、截图、图片、来源小图标都能双向同步。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if !errorText.isEmpty {
                    Section("上次连接提示") {
                        Text(errorText).font(.footnote).foregroundColor(.orange)
                    }
                }
            }
            .navigationTitle("连接电脑")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") { onConnect(draft) }
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let urlString: String
    let reloadToken: Int
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.dataDetectorTypes = []
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        wv.isOpaque = false
        wv.backgroundColor = .systemBackground
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        let key = urlString + "#" + String(reloadToken)
        guard !urlString.isEmpty, context.coordinator.lastKey != key,
              let url = URL(string: urlString + "/") else { return }
        context.coordinator.lastKey = key
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        wv.load(req)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastKey = ""
        let onError: (String) -> Void
        init(onError: @escaping (String) -> Void) { self.onError = onError }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError("连不上电脑：" + error.localizedDescription
                    + "。请确认电脑服务已启动、同一 WiFi，右下角齿轮可改地址。")
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError("加载失败：" + error.localizedDescription)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            let ac = UIAlertController(title: "QuickPaste", message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            present(ac)
        }
        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            let ac = UIAlertController(title: "QuickPaste", message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            ac.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
            present(ac)
        }

        private func present(_ ac: UIAlertController) {
            guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                  let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                return
            }
            var top = root
            while let p = top.presentedViewController { top = p }
            top.present(ac, animated: true)
        }
    }
}
