import Foundation

/// 拼音输入法核心引擎：候选生成、9键(T9)展开、语境联想、个人学习、细胞词库。
/// 全部本地运行，不依赖网络。
final class PinyinEngine {
    static let shared = PinyinEngine()

    // 基础词库
    private var charMap: [String: [String]] = [:]        // toneless音节 -> [汉字]
    private var phraseMap: [String: [String]] = [:]      // "ni hao" -> [短语]
    private var assocMap: [String: [String]] = [:]       // 单/双字前缀 -> [以之开头的短语]（联想）
    private var validSyllables: Set<String> = []

    // 反向表：汉字 -> 首选音节（用于把"用户词"换算成拼音，做学习记忆）
    private var charToPinyin: [String: String] = [:]

    // 个人学习：拼音key -> [短语: 词频]
    private var userByPinyin: [String: [String: Int]] = [:] {
        didSet { saveUserDict() }
    }

    // 9键数字->字母
    private let digitLetters: [Character: [Character]] = [
        "2": ["a","b","c"], "3": ["d","e","f"],
        "4": ["g","h","i"], "5": ["j","k","l"],
        "6": ["m","n","o"], "7": ["p","q","r","s"],
        "8": ["t","u","v"], "9": ["w","x","y","z"],
    ]

    private init() { load() }

    // MARK: - 加载
    func load() {
        guard let c = Bundle.main.url(forResource: "pinyin_chars", withExtension: "json"),
              let p = Bundle.main.url(forResource: "pinyin_phrases", withExtension: "json"),
              let a = Bundle.main.url(forResource: "pinyin_assoc", withExtension: "json") else { return }
        if let d = try? Data(contentsOf: c),
           let m = try? JSONSerialization.jsonObject(with: d) as? [String: [String]] { charMap = m }
        if let d = try? Data(contentsOf: p),
           let m = try? JSONSerialization.jsonObject(with: d) as? [String: [String]] { phraseMap = m }
        if let d = try? Data(contentsOf: a),
           let m = try? JSONSerialization.jsonObject(with: d) as? [String: [String]] { assocMap = m }

        // 反向表 & 合法音节集
        var c2p: [String: String] = [:]
        for (syl, chars) in charMap {
            validSyllables.insert(syl)
            for ch in chars where c2p[ch] == nil { c2p[ch] = syl }
        }
        for key in phraseMap.keys {
            for syl in key.split(separator: " ") { validSyllables.insert(String(syl)) }
        }
        charToPinyin = c2p

        // 加载个人词库
        if let ud = UserDefaults.standard.dictionary(forKey: "kb_user_dict") as? [String: [String: Int]] {
            userByPinyin = ud
        }
        // 加载细胞词库（示例：网络热词）
        if let url = Bundle.main.url(forResource: "cat_net", withExtension: "json"),
           let d = try? Data(contentsOf: url),
           let m = try? JSONSerialization.jsonObject(with: d) as? [String: [String]] {
            mergeCategory(m)
        }
    }

    /// 合并一个细胞词库（key="ni hao" -> [短语]），可被多个领域词库反复调用
    func mergeCategory(_ dict: [String: [String]]) {
        for (k, vals) in dict {
            var arr = phraseMap[k] ?? []
            for v in vals where !arr.contains(v) { arr.append(v) }
            phraseMap[k] = arr
            if let first = k.split(separator: " ").first.map(String.init) {
                var a = assocMap[first] ?? []
                for v in vals where !a.contains(v) { a.append(v) }
                assocMap[first] = a
            }
        }
    }

    // MARK: - 候选生成
    /// buffer: 26键为字母串；9键为数字串(2-9)。返回按优先级排序的候选。
    func candidates(for buffer: String, is9Key: Bool) -> [String] {
        let buf = buffer.lowercased()
        let seqs: [[String]]
        if is9Key {
            seqs = expand9(buf).compactMap { segment($0) }
        } else if let seg = segment(buf) {
            seqs = [seg]
        } else {
            seqs = []
        }

        var result: [String] = []
        var seen = Set<String>()
        func push(_ s: String) { if !s.isEmpty && !seen.contains(s) { seen.insert(s); result.append(s) } }

        // 1) 个人学习词（最优先，按词频）
        for seq in seqs {
            let key = seq.joined(separator: " ")
            if let ud = userByPinyin[key] {
                for phrase in ud.sorted(by: { $0.value > $1.value }).map({ $0.key }) { push(phrase) }
            }
        }
        // 2) 词组库
        for seq in seqs {
            let key = seq.joined(separator: " ")
            if let phrases = phraseMap[key] { for p in phrases { push(p) } }
            let composed = seq.compactMap { charMap[$0]?.first }.joined()
            push(composed)
        }
        // 3) 单字兜底
        if result.isEmpty, let seg = seqs.first, let last = seg.last, let chars = charMap[last] {
            for c in chars { push(c) }
        }
        return Array(result.prefix(50))
    }

    // 9键 T9 展开（数字->字母笛卡尔积，限流）
    private func expand9(_ digits: String) -> [String] {
        let arr = Array(digits)
        var acc = [""]
        for d in arr {
            guard let letters = digitLetters[d] else { return [] }
            var next: [String] = []
            for pre in acc { for l in letters { next.append(pre + String(l)) } }
            acc = next
            if acc.count > 3000 { break }
        }
        return acc
    }

    // 最长匹配切分（优先长音节）
    private func segment(_ s: String) -> [String]? {
        let chars = Array(s); let n = chars.count
        guard n > 0 else { return nil }
        var dp = Array(repeating: false, count: n + 1); dp[0] = true
        var from = Array(repeating: -1, count: n + 1)
        for i in 0..<n where dp[i] {
            for l in stride(from: min(6, n - i), through: 1, by: -1) {
                let sub = String(chars[i..<i + l])
                if validSyllables.contains(sub) && !dp[i + l] {
                    dp[i + l] = true; from[i + l] = i
                }
            }
        }
        guard dp[n] else { return nil }
        var seq: [String] = []; var i = n
        while i > 0 { let p = from[i]; seq.append(String(chars[p..<i])); i = p }
        return seq.reversed()
    }

    // MARK: - 联想（语境）
    /// context: 光标前的中文文本。返回基于末1~2字的联想词。
    func associations(for context: String) -> [String] {
        let t = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        func push(_ s: String) { if !s.isEmpty && !seen.contains(s) { seen.insert(s); out.append(s) } }
        let s2 = String(t.suffix(2)); let s1 = String(t.suffix(1))
        // 个人学习词优先
        for pre in [s2, s1] {
            if let ud = userByPinyin[pinyinKey(of: pre) ?? ""] {
                for p in ud.sorted(by: { $0.value > $1.value }).map({ $0.key }) { push(p) }
            }
        }
        if let a = assocMap[s2] { for p in a { push(p) } }
        if let a = assocMap[s1] { for p in a { push(p) } }
        return Array(out.prefix(20))
    }

    // MARK: - 个人学习
    /// 提交一个词/短语时调用，记入个人词库并按词频累加。
    func learn(_ text: String) {
        guard let key = pinyinKey(of: text) else { return }
        var inner = userByPinyin[key] ?? [:]
        inner[text, default: 0] += 1
        userByPinyin[key] = inner
        trimIfNeeded()
    }

    /// 把任意中文串换算成拼音key（如 "你好" -> "ni hao"）；含非中文则跳过该字
    private func pinyinKey(of text: String) -> String? {
        var syls: [String] = []
        for ch in text {
            if let s = charToPinyin[String(ch)] { syls.append(s) }
            else if ch.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) { /* 英文原样 */ syls.append(String(ch).lowercased()) }
        }
        guard !syls.isEmpty else { return nil }
        return syls.joined(separator: " ")
    }

    private func trimIfNeeded() {
        let total = userByPinyin.values.reduce(0) { $0 + $1.count }
        guard total > 5000 else { return }
        // 丢弃词频最低的条目
        var flat: [(String, String, Int)] = []
        for (k, inner) in userByPinyin { for (w, f) in inner { flat.append((k, w, f)) } }
        flat.sort { $0.2 < $1.2 }
        let drop = total - 5000
        var toDrop = drop
        var newDict: [String: [String: Int]] = [:]
        for (k, w, f) in flat {
            if toDrop > 0 { toDrop -= 1; continue }
            newDict[k, default: [:]][w] = f
        }
        userByPinyin = newDict
    }

    private func saveUserDict() {
        UserDefaults.standard.set(userByPinyin, forKey: "kb_user_dict")
    }
}
