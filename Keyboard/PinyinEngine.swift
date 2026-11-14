import Foundation

/// 拼音输入法核心引擎：候选生成、9键(T9)/双拼解码、多字拼音、语境联想(基于字符bigram)、
/// 个人学习、细胞词库。全部本地运行，不依赖网络。
final class PinyinEngine {
    static let shared = PinyinEngine()

    // 基础词库
    private var charMap: [String: [String]] = [:]        // toneless音节 -> [汉字](已按词频排前)
    private var phraseMap: [String: [String]] = [:]      // "ni hao" -> [短语]
    private var assocMap: [String: [String]] = [:]      // 单/双字前缀 -> [以之开头的短语](联想)
    private var validSyllables: Set<String> = []
    private var charFreq: [String: Int] = [:]           // 汉字 -> 语料词频（用于候选打分）
    private var bigram: [String: [String: Int]] = [:]   // 字 -> 后继字 -> 次数（联想/上下文选词）

    // 反向表：汉字 -> 首选音节
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

    // MARK: - 双拼方案
    /// 声母映射（首键 -> 声母）。a/e/o 不在表内 => 零声母。
    private let spInitial: [Character: String] = [
        "b":"b","p":"p","m":"m","f":"f","d":"d","t":"t","n":"n","l":"l",
        "g":"g","k":"k","h":"h","j":"j","q":"q","x":"x","r":"r","z":"z","c":"c","s":"s",
        "y":"y","w":"w",
        "v":"zh","i":"ch","u":"sh",
    ]
    /// 各方案：次键 -> [候选韵母]（已按存储拼写：ü 写作 v；j/q/x/y 后 ü 写作 u；如 yuan/yue/jun）
    /// 上下文消歧在 decodeShuangpin 中处理：o->uo/o、v->v/ui；r/t 各方案不同，已写入下表。
    private let spFinal: [String: [Character: [String]]] = [
        "小鹤": [
            "a":["a"],"b":["in"],"c":["ao"],"d":["ai"],"e":["e"],"f":["en"],"g":["eng"],
            "h":["ang"],"i":["i"],"j":["an"],"k":["ing","uai"],"l":["iang","uang"],
            "m":["ian"],"n":["iao"],"o":["uo","o"],"p":["ie"],"q":["iu"],"r":["uan","er"],
            "s":["iong","ong"],"t":["ue","ve"],"u":["u"],"v":["v","ui"],"w":["ei"],
            "x":["ia","ua"],"y":["un"],"z":["ou"],
        ],
        "自然码": [
            "a":["a"],"b":["ou"],"c":["iao"],"d":["uang","iang"],"e":["e"],"f":["en"],
            "g":["eng"],"h":["ang"],"i":["i"],"j":["an"],"k":["ao"],"l":["ai"],"m":["ian"],
            "n":["in"],"o":["uo","o"],"p":["un"],"q":["iu"],"r":["uan","er"],
            "s":["iong","ong"],"t":["ue","ve"],"u":["u"],"v":["v","ui"],"w":["ua","ia"],
            "x":["ie"],"y":["uai","ing"],"z":["ei"],
        ],
        "智能ABC": [
            "a":["a"],"b":["ou"],"c":["in","uai"],"d":["ua","ia"],"e":["e"],"f":["en"],
            "g":["eng"],"h":["ang"],"i":["i"],"j":["an"],"k":["ao"],"l":["ai"],"m":["ue","ui"],
            "n":["un"],"o":["uo","o"],"p":["uan"],"q":["ei"],"r":["iu","er"],
            "s":["ong","iong"],"t":["uang","iang"],"u":["u"],"v":["v"],"w":["ian"],
            "x":["ie"],"y":["ing"],"z":["iao"],
        ],
    ]
    private let spSchemes = ["小鹤","自然码","智能ABC"]

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

        // 词频 + bigram（增强联想/排序）
        if let d = try? Data(contentsOf: Bundle.main.url(forResource: "pinyin_char_freq", withExtension: "json")!),
           let m = try? JSONSerialization.jsonObject(with: d) as? [String: Int] { charFreq = m }
        if let d = try? Data(contentsOf: Bundle.main.url(forResource: "pinyin_bigram", withExtension: "json")!),
           let m = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Int]] { bigram = m }

        var c2p: [String: String] = [:]
        for (syl, chars) in charMap {
            validSyllables.insert(syl)
            for ch in chars where c2p[ch] == nil { c2p[ch] = syl }
        }
        for key in phraseMap.keys {
            for syl in key.split(separator: " ") { validSyllables.insert(String(syl)) }
        }
        charToPinyin = c2p

        if let ud = UserDefaults.standard.dictionary(forKey: "kb_user_dict") as? [String: [String: Int]] {
            userByPinyin = ud
        }
        if let url = Bundle.main.url(forResource: "cat_net", withExtension: "json"),
           let d = try? Data(contentsOf: url),
           let m = try? JSONSerialization.jsonObject(with: d) as? [String: [String]] {
            mergeCategory(m)
        }
    }

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

    // MARK: - 候选生成（多字拼音 / 长句）
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
        return rank(seqs)
    }

    /// 双拼：把字母串解码为音节序列再候选
    /// 支持「实时候选」：奇数长度时自动忽略最后一个未成对的字母（用户正在输入第二键）。
    func candidatesForShuangpin(_ buffer: String, scheme: String) -> [String] {
        let b = buffer.lowercased()
        guard !b.isEmpty else { return [] }
        var work = Array(b)
        if work.count % 2 == 1 { work.removeLast() }
        guard work.count > 0 else { return [] }
        guard let seq = decodeShuangpin(String(work), scheme: scheme) else { return [] }
        return rank([seq])
    }

    /// 按音节序列生成并排序候选
    private func rank(_ seqs: [[String]]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func push(_ s: String, base: Int) {
            guard !s.isEmpty, !seen.contains(s) else { return }
            seen.insert(s); result.append(s)
            _ = base
        }
        // 1) 个人学习词（最优先，按词频）
        for seq in seqs {
            let key = seq.joined(separator: " ")
            if let ud = userByPinyin[key] {
                for phrase in ud.sorted(by: { $0.value > $1.value }).map({ $0.key }) {
                    push(phrase, base: 0)
                }
            }
        }
        // 2) 词组库（按字符词频打分排序）
        for seq in seqs {
            let key = seq.joined(separator: " ")
            if let phrases = phraseMap[key] {
                for p in phrases.sorted(by: { score($0) > score($1) }) { push(p, base: 0) }
            }
            // 单字兜底：逐音节取首字
            let composed = seq.compactMap { charMap[$0]?.first }.joined()
            if !composed.isEmpty { push(composed, base: 0) }
        }
        // 3) 单字兜底
        if result.isEmpty, let seg = seqs.first, let last = seg.last, let chars = charMap[last] {
            for c in chars { push(c, base: 0) }
        }
        return Array(result.prefix(50))
    }

    /// 短语打分：词组基础分 + 各字语料词频之和
    private func score(_ phrase: String) -> Int {
        var s = 1000
        for c in phrase { s += charFreq[String(c)] ?? 0 }
        return s
    }

    // 9键 T9 展开
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

    // 最长匹配切分
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

    // MARK: - 双拼解码
    /// 把双拼字母串按方案解码为音节数组；无法解码返回 nil
    private func decodeShuangpin(_ letters: String, scheme: String) -> [String]? {
        guard let fin = spFinal[scheme] else { return nil }
        let arr = Array(letters)
        guard arr.count % 2 == 0 else { return nil }
        var seq: [String] = []
        var i = 0
        while i < arr.count {
            let k1 = arr[i], k2 = arr[i+1]; i += 2
            let initial = spInitial[k1]                 // nil => 零声母
            let finals: [String]
            if let ini = initial {
                finals = afterInitialFinals(fin, k2, initial: ini)
            } else {
                finals = fin[k2] ?? []
            }
            // 选第一个合法音节（按存储拼写校验）
            var hit: String? = nil
            for f in finals {
                let syl = (initial ?? "") + f
                if validSyllables.contains(syl) { hit = syl; break }
            }
            guard let syl = hit else { return nil }
            seq.append(syl)
        }
        return seq
    }

    /// 有声母时：o->uo(优先)/o，v->v/ui；其余直接查表（r/t 各方案已写入表内）
    private func afterInitialFinals(_ fin: [Character: [String]], _ k2: Character, initial: String) -> [String] {
        if k2 == "o" { return ["uo", "o"] }
        if k2 == "v" { return ["v", "ui"] }
        return fin[k2] ?? []
    }

    func availableShuangpinSchemes() -> [String] { spSchemes }

    // MARK: - 联想（语境，基于字符 bigram）
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
        // bigram 驱动：上一字 -> 高频后继字 -> 组词
        if let nxt = bigram[s1] {
            for (nc, _) in nxt.sorted(by: { $0.value > $1.value }).prefix(12) {
                if let arr = assocMap[s1 + nc] {
                    for p in arr { push(p) }
                }
                if let firstChars = charMap.first(where: { $0.value.contains(nc) })?.value,
                   let ch = firstChars.first(where: { $0 == nc }) {
                    push(s1 + String(ch)) // 退而求其次：上字+后继字
                }
            }
        }
        if let a = assocMap[s2] { for p in a { push(p) } }
        if let a = assocMap[s1] { for p in a { push(p) } }
        return Array(out.prefix(20))
    }

    // MARK: - 个人学习
    func learn(_ text: String) {
        guard let key = pinyinKey(of: text) else { return }
        var inner = userByPinyin[key] ?? [:]
        inner[text, default: 0] += 1
        userByPinyin[key] = inner
        trimIfNeeded()
    }

    private func pinyinKey(of text: String) -> String? {
        var syls: [String] = []
        for ch in text {
            if let s = charToPinyin[String(ch)] { syls.append(s) }
            else if String(ch).rangeOfCharacter(from: .letters) != nil { syls.append(String(ch).lowercased()) }
        }
        guard !syls.isEmpty else { return nil }
        return syls.joined(separator: " ")
    }

    private func trimIfNeeded() {
        let total = userByPinyin.values.reduce(0) { $0 + $1.count }
        guard total > 5000 else { return }
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
