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
        /// v1.8.12 卡顿优化：电脑端内容与客户端签名一致时服务端只回这个小对象，
        /// items 为空 —— 免去每 3 秒全量下载（含图片 base64）+ JSON 全量解码。
        var unchanged = false
        var sig = ""
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

    /// - parameter sig: 上一轮的服务端签名；命中时服务端返回 unchanged（体积只有几十字节，
    ///   不再带 items / 图片 base64）。传 nil 或空 = 全量拉取。
    func fetch(limit: Int = 30, sig: String? = nil,
               completion: @escaping (Result?, String?) -> Void) {
        var path = "/api/items?limit=\(limit)"
        if let s = sig, !s.isEmpty {
            // sig 里含 "|" 与 "#"，只放行 URL 安全字符，其余全部百分号编码
            let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let e = s.addingPercentEncoding(withAllowedCharacters: safe) ?? s
            path += "&sig=\(e)"
        }
        guard var req = request(path) else {
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
            r.unchanged = (obj["unchanged"] as? Bool) ?? false
            r.sig = obj["sig"] as? String ?? ""
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

    /// v1.8.20：LocalSend v2 风格两步上传（参照开源项目 localsend 的协议形状）：
    ///   ① POST /api/prepare-upload  登记文件清单（文件名/大小/MIME）→ 拿 sessionId + token
    ///   ② POST /api/upload?sessionId=..&fileId=..&token=..  文件本体作为 HTTP body 直传
    /// 电脑端把文件落进「可见」的接收文件夹（默认 下载\墨指导出）。
    /// 老版电脑端（< v1.8.20）没有这两个接口 → 自动回退旧的 POST /api/file。
    func sendFile(_ data: Data, name: String, mime: String,
                  completion: @escaping (String?) -> Void) {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        let fileId = "f" + UUID().uuidString.prefix(8)
        guard var req = request("/api/prepare-upload", method: "POST") else {
            completion("未设置电脑地址")
            return
        }
        let body: [String: Any] = [
            "alias": "墨指手机", "platform": "ios", "deviceType": "headless",
            "files": [fileId: ["fileName": name, "mime": mime, "size": data.count]],
        ]
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { d, r, e in
            // 老服务端没有 prepare-upload → 回退旧接口
            if let http = r as? HTTPURLResponse, http.statusCode == 404 {
                self.pushFile(data, name: name, mime: mime, completion: completion)
                return
            }
            if let err = self.check(d, r, e) { completion(err); return }
            guard let d = d,
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sid = o["sessionId"] as? String,
                  let token = o["token"] as? String else {
                completion("电脑端返回格式不对")
                return
            }
            var path = "/api/upload?sessionId=\(enc(sid))&fileId=\(enc(fileId))&token=\(enc(token))"
            if !self.pair.isEmpty { path += "&pair=\(enc(self.pair))" }
            guard var up = self.request(path, method: "POST") else {
                completion("未设置电脑地址")
                return
            }
            up.setValue(mime.isEmpty ? "application/octet-stream" : mime,
                        forHTTPHeaderField: "Content-Type")
            up.httpBody = data
            URLSession.shared.dataTask(with: up) { d2, r2, e2 in
                completion(self.check(d2, r2, e2))
            }.resume()
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
