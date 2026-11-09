import Foundation

/// 电脑端 v1.6 同步服务的 HTTP 客户端（在键盘扩展里运行，需要「允许完全访问」）。
/// - GET  /api/items?limit=30   拉取剪贴板列表（文字 + 图片）
/// - POST /api/items            发送文字 {"text":..,"source":"phone","pair":..}
/// - POST /api/image            发送图片二进制 body（LocalSend 风格）
/// - DELETE /api/items?id=..    删除单条；不带 id 清空
final class SyncClient {

    struct Result {
        var count = 0
        var backend = ""
        var items: [SyncItem] = []
    }

    private let base: String
    private let pair: String

    init(url: String, pair: String) {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        self.base = u
        self.pair = pair.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest? {
        guard !base.isEmpty, let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 3.5)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !pair.isEmpty { req.setValue(pair, forHTTPHeaderField: "X-Pair-Code") }
        return req
    }

    private func check(_ data: Data?, _ response: URLResponse?, _ error: Error?) -> String? {
        if let e = error { return e.localizedDescription }
        guard let http = response as? HTTPURLResponse else { return "无响应" }
        guard (200..<300).contains(http.statusCode) else { return "HTTP \(http.statusCode)" }
        if let d = data,
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let ok = o["ok"] as? Bool, !ok {
            return o["error"] as? String ?? "服务返回失败"
        }
        return nil
    }

    func fetch(limit: Int = 30, completion: @escaping (Result?, String?) -> Void) {
        guard var req = request("/api/items?limit=\(limit)") else {
            completion(nil, "未设置电脑地址")
            return
        }
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let err = self.check(data, response, error) {
                completion(nil, err)
                return
            }
            guard let d = data,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                completion(nil, "返回格式不对")
                return
            }
            var r = Result()
            r.count = (obj["count"] as? NSNumber)?.intValue ?? 0
            r.backend = obj["backend"] as? String ?? ""
            if let arr = obj["items"] as? [[String: Any]] {
                r.items = arr.map { SyncItem.from($0) }
            }
            completion(r, nil)
        }.resume()
    }

    func pushText(_ text: String, completion: @escaping (String?) -> Void) {
        guard var req = request("/api/items", method: "POST") else {
            completion("未设置电脑地址")
            return
        }
        var body: [String: Any] = ["text": text, "source": "phone"]
        if !pair.isEmpty { body["pair"] = pair }
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, response, error in
            completion(self.check(data, response, error))
        }.resume()
    }

    func pushImage(_ data: Data, mime: String,
                   completion: @escaping (String?) -> Void) {
        let m = mime.isEmpty ? "image/png" : mime
        let encoded = m.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "image/png"
        var path = "/api/image?source=phone&mime=\(encoded)"
        if !pair.isEmpty {
            let p = pair.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pair
            path += "&pair=\(p)"
        }
        guard var req = request(path, method: "POST") else {
            completion("未设置电脑地址")
            return
        }
        req.setValue(m, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { respData, response, error in
            completion(self.check(respData, response, error))
        }.resume()
    }

    /// 发送任意文件到电脑（v1.8.8 导出用）：二进制 body，元数据走 query，
    /// 与电脑端 sync/server.js 的 POST /api/file 约定一致。
    func pushFile(_ data: Data, name: String, mime: String,
                  completion: @escaping (String?) -> Void) {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        var path = "/api/file?name=\(enc(name))&mime=\(enc(mime))&source=phone"
        if !pair.isEmpty { path += "&pair=\(enc(pair))" }
        guard var req = request(path, method: "POST") else {
            completion("未设置电脑地址")
            return
        }
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { d, r, e in
            completion(self.check(d, r, e))
        }.resume()
    }

    func delete(id: String?, completion: @escaping (String?) -> Void) {
        var path = "/api/items"
        if let id = id, !id.isEmpty {
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
            path += "?id=\(encoded)"
        }
        guard let req = request(path, method: "DELETE") else {
            completion("未设置电脑地址")
            return
        }
        URLSession.shared.dataTask(with: req) { data, response, error in
            completion(self.check(data, response, error))
        }.resume()
    }
}
