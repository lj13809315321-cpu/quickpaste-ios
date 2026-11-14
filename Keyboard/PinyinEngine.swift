import Foundation

/// 拼音输入法核心引擎：9键(T9)/26键拼音、多字拼音、整句合成、模糊音、超级简拼、
/// 中英混输、语境联想(字符 bigram)、个人学习、细胞词库。全部本地运行，不依赖网络。
final class PinyinEngine {
    static let shared = PinyinEngine()

    // 基础词库
    private var charMap: [String: [String]] = [:]        // toneless音节 -> [汉字](已按词频排前)
    private var phraseMap: [String: [String]] = [:]      // "ni hao" -> [短语]
    private var assocMap: [String: [String]] = [:]      // 单/双字前缀 -> [以之开头的短语](联想)
    private var validSyllables: Set<String> = []
    private var charFreq: [String: Int] = [:]           // 汉字 -> 语料词频（用于候选打分）
    private var bigram: [String: [String: Int]] = [:]   // 字 -> 后继字 -> 次数（联想/上下文选词）
    private var hotWords: Set<String> = []              // 可信高频日常词（整句合成只接受这些整词）
    private var syllablePrefixes: Set<String> = []      // 合法音节的所有前缀（T9 边展开边剪枝）

    /// 词库是否加载成功。UI 用它显示诊断，避免候选一片空白时无从判断。
    private(set) var isLoaded = false
    /// 各字典加载情况（调试用）
    private(set) var diagnostics: String = ""

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

    // 超级简拼：声母串 -> [短语]（如 nh -> 你好；wm -> 我们）
    private var abbrMap: [String: [String]] = [:]

    // 模糊音（借鉴旧引擎 IME_FLAG_FUZZY），严格分两类，避免把英文单词硬切成汉字：
    //  - 声母模糊：只做「前缀」替换（z/zh、c/ch、s/sh、n/l、f/h、r/l）
    //  - 韵母模糊：只做「后缀」替换（前后鼻音 an/ang、en/eng、in/ing、ian/iang、uan/uang）
    private let fuzzyInitials: [(String, String)] = [
        ("z","zh"), ("c","ch"), ("s","sh"), ("n","l"), ("f","h"), ("r","l"),
    ]
    private let fuzzyFinals: [(String, String)] = [
        ("an","ang"), ("en","eng"), ("in","ing"), ("ian","iang"), ("uan","uang"),
    ]

    private init() { load() }

    /// 【关键加固】键盘扩展里 Bundle.main 不一定指向 .appex 自己，
    /// 之前只从 Bundle.main 读资源，一旦拿不到就是「全部字典为空 → 候选一片空白 → 打不了字」。
    /// 优先用类所在的 bundle（一定是扩展自己），再回退 Bundle.main，最后遍历所有已加载 bundle。
    private func resourceURL(_ name: String) -> URL? {
        let primary: [Bundle] = [Bundle(for: PinyinEngine.self), Bundle.main]
        for b in primary {
            if let u = b.url(forResource: name, withExtension: "json") { return u }
        }
        for b in Bundle.allBundles {
            if let u = b.url(forResource: name, withExtension: "json") { return u }
        }
        return nil
    }

    // MARK: - 加载
    func load() {
        // 每个字典独立可选绑定：单个资源缺失只降级对应能力，绝不因为一个文件
        // 就让整台引擎不加载（之前 pinyin_char_freq.json 缺失就导致键盘启动即崩）。
        if let url = resourceURL("pinyin_chars"),
           let d = try? Data(contentsOf: url),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String]] { charMap = m }
        if let url = resourceURL("pinyin_phrases"),
           let d = try? Data(contentsOf: url),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String]] { phraseMap = m }
        if let url = resourceURL("pinyin_assoc"),
           let d = try? Data(contentsOf: url),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String]] { assocMap = m }
        if let url = resourceURL("pinyin_char_freq"),
           let d = try? Data(contentsOf: url),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Int] { charFreq = m }
        if let url = resourceURL("pinyin_bigram"),
           let d = try? Data(contentsOf: url),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: Int]] { bigram = m }
        if let url = resourceURL("pinyin_hot_words"),
           let d = try? Data(contentsOf: url),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String] { hotWords = Set(m) }

        isLoaded = !charMap.isEmpty && !phraseMap.isEmpty
        diagnostics = "chars=\(charMap.count) phrases=\(phraseMap.count) assoc=\(assocMap.count) " +
                      "freq=\(charFreq.count) bigram=\(bigram.count) hot=\(hotWords.count)"

        var c2p: [String: String] = [:]
        for (syl, chars) in charMap {
            validSyllables.insert(syl)
            for ch in chars where c2p[ch] == nil { c2p[ch] = syl }
        }
        for key in phraseMap.keys {
            for syl in key.split(separator: " ") { validSyllables.insert(String(syl)) }
        }
        charToPinyin = c2p

        // 合法音节的全部前缀，用于 T9 边展开边剪枝
        for syl in validSyllables {
            let c = Array(syl)
            if c.isEmpty { continue }
            for i in 1...c.count { syllablePrefixes.insert(String(c[0..<i])) }
        }

        // 超级简拼表：2~3 字短语的声母串 -> 短语列表
        for (key, phrases) in phraseMap {
            let syls = key.split(separator: " ")
            guard (2...3).contains(syls.count) else { continue }
            let initials = syls.map { String($0.prefix(1)) }.joined()
            guard !initials.isEmpty else { continue }
            for p in phrases where !p.isEmpty {
                abbrMap[initials, default: []].append(p)
            }
        }
        // 一次预排序（真实字频），每次按键不再重复排
        for (k, v) in abbrMap {
            abbrMap[k] = Array(v.sorted { score($0) > score($1) }.prefix(24))
        }

        if let ud = UserDefaults.standard.dictionary(forKey: "kb_user_dict") as? [String: [String: Int]] {
            userByPinyin = ud
        }
        if let url = resourceURL("cat_net"),
           let d = try? Data(contentsOf: url),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String]] {
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
        guard !buf.isEmpty else { return [] }
        let seqs: [[String]]
        if is9Key {
            seqs = expand9(buf).compactMap { segment($0) }
        } else if let seg = segment(buf) {
            seqs = [seg]
        } else {
            seqs = []
        }
        var result = rank(seqs)
        // 超级简拼：拼音切分无结果时把声母串当简拼命中（如 nh -> 你好、wm -> 我们）
        // 顺序已在 load() 里按真实词频预排好，这里直接用。
        if seqs.isEmpty, !is9Key, let ab = abbrMap[buf], !ab.isEmpty {
            result = ab
        }
        // 中英混输：26 键下始终保留「原始字母串」作为最后候选，
        // 即使某个英文单词碰巧被切成汉字（hello/world/iphone），用户也能选到英文原串。
        if !is9Key, buf.count <= 24, !result.contains(buf) {
            result.append(buf)
        }
        // 【关键兜底】任何模式都至少返回一个可上屏候选。
        // 之前 9 键在词库加载失败 / T9 切分不中时返回空数组，候选栏一片空白，
        // 用户既看不到也点不到任何东西 —— 就是「拼音打不了字」的直接表现。
        if result.isEmpty { result = [buf] }
        return Array(result.prefix(50))
    }

    /// 9 键会展开出几十个音节组合，必须先判断「哪一组更像一个真词」。
    /// 整串有词且是高频日常词（你好 / 中国 / 世界）给绝对优先，
    /// 否则垃圾组合（米干 / 西末滚）会全排在真词前面。
    private func seqScore(_ seq: [String]) -> Int {
        let key = seq.joined(separator: " ")
        var s = 0
        if let phrases = phraseMap[key], let first = phrases.first {
            s += 100000
            if hotWords.contains(first) { s += 500000 }
        }
        for syl in seq {
            if let c = topChar(syl) { s += charFreq[c] ?? 0 }
        }
        s -= seq.count * 30      // 音节切得越碎越不像整词
        return s
    }

    /// 按音节序列生成候选
    private func rank(_ seqs: [[String]]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func push(_ s: String) {
            guard !s.isEmpty, !seen.contains(s) else { return }
            seen.insert(s); result.append(s)
        }

        // 26 键只有 1 个序列；9 键会有一堆，按「像不像真词」排序
        let ordered = seqs.count > 1 ? seqs.sorted { seqScore($0) > seqScore($1) } : seqs

        // 1) 个人学习词（最优先）
        for seq in ordered.prefix(8) {
            let key = seq.joined(separator: " ")
            if let ud = userByPinyin[key] {
                for phrase in ud.sorted(by: { $0.value > $1.value }).map({ $0.key }) { push(phrase) }
            }
        }
        // 2) 词组库：只取排序靠前的组合，每组最多前 6 个词（离线已按真实词频排好）
        for seq in ordered.prefix(12) {
            let key = seq.joined(separator: " ")
            for k in [key] + fuzzyKeys(seq) {
                if let phrases = phraseMap[k] {
                    for p in phrases.prefix(6) { push(p) }
                }
            }
        }
        // 3) 整句合成：只对最佳 2 个组合做，避免几十个垃圾串刷屏
        for seq in ordered.prefix(2) {
            let composed = greedyCompose(seq)
            if !composed.isEmpty { push(composed) }
        }
        // 4) 单字候选（用最佳组合的首/末音节），始终可翻页
        if let best = ordered.first {
            let syllables = (best.count > 1 ? [best[0], best[best.count - 1]] : best)
            for syl in syllables {
                for v in fuzzyVariants(syl) {
                    if let chars = charMap[v] {
                        for c in chars.prefix(12) { push(c) }
                    }
                }
            }
        }
        // 5) 完全无命中时的保底
        if result.isEmpty, let best = ordered.first, let last = best.last, let c = topChar(last) {
            push(c)
        }
        return Array(result.prefix(50))
    }

    /// 短语打分：词组基础分 + 各字语料词频之和（仅用于简拼候选排序）
    private func score(_ phrase: String) -> Int {
        var s = 1000
        for c in phrase { s += charFreq[String(c)] ?? 0 }
        return s
    }

    /// 整句合成：从左到右贪心匹配最长的已知词，未命中的音节取首选单字。
    /// 例：wo ai zhong guo -> 我 + 爱 + 中国（而非逐字拼出的「我爱中过」）。
    private func greedyCompose(_ seq: [String]) -> String {
        var out = ""
        var i = 0
        while i < seq.count {
            var matched: String? = nil
            var used = 1
            let maxLen = min(5, seq.count - i)
            if maxLen >= 2 {
                for l in stride(from: maxLen, through: 2, by: -1) {
                    let key = seq[i..<(i + l)].joined(separator: " ")
                    if let phrases = phraseMap[key], let first = phrases.first,
                       hotWords.contains(first) {   // 只接受可信高频日常词
                        matched = first; used = l; break
                    }
                }
            }
            if let m = matched {
                out += m; i += used
            } else {
                if let c = topChar(seq[i]) { out += c }
                i += 1
            }
        }
        return out
    }

    // 9键 T9 展开：边展开边按「拼音前缀可行性」剪枝，并设硬上限。
    // 之前是全组合展开（4^6=4096 条），每条再跑 DP 切分，长串时每次按键都会卡住，
    // 用户感觉就是「按了没反应 / 打不了字」。
    private func expand9(_ digits: String) -> [String] {
        let arr = Array(digits)
        guard !arr.isEmpty else { return [] }
        var acc = [""]
        for d in arr {
            guard let letters = digitLetters[d] else { return [] }
            var next: [String] = []
            for pre in acc {
                for l in letters {
                    let cand = pre + String(l)
                    if isViablePrefix(cand) { next.append(cand) }
                }
            }
            // 剪枝过严时退化为全展开，仍交给 segment() 做最终判定
            if next.isEmpty {
                for pre in acc { for l in letters { next.append(pre + String(l)) } }
            }
            acc = next
            if acc.count > 512 { acc = Array(acc.prefix(512)) }
        }
        return acc
    }

    /// cand 能否切成「若干完整音节 + 一个合法音节前缀」
    private func isViablePrefix(_ s: String) -> Bool {
        let chars = Array(s); let n = chars.count
        guard n > 0 else { return false }
        var dp = Array(repeating: false, count: n + 1); dp[0] = true
        for i in 0..<n where dp[i] {
            for l in 1...min(6, n - i) {
                let sub = String(chars[i..<(i + l)])
                if validSyllables.contains(sub) { dp[i + l] = true }
            }
        }
        for i in 0..<n where dp[i] {
            let tail = String(chars[i..<n])
            if syllablePrefixes.contains(tail) { return true }
        }
        return dp[n]
    }

    // 最长匹配切分（支持模糊音：切分时按 canon 归一化到数据存在的音节）
    private func segment(_ s: String) -> [String]? {
        let chars = Array(s); let n = chars.count
        guard n > 0 else { return nil }
        var dp = Array(repeating: false, count: n + 1); dp[0] = true
        var from = Array(repeating: -1, count: n + 1)
        for i in 0..<n where dp[i] {
            for l in stride(from: min(6, n - i), through: 1, by: -1) {
                let sub = String(chars[i..<i + l])
                if canonForSegment(sub) != nil, !dp[i + l] {
                    dp[i + l] = true; from[i + l] = i
                }
            }
        }
        guard dp[n] else { return nil }
        var seq: [String] = []; var i = n
        while i > 0 {
            let p = from[i]
            guard p >= 0, let c = canonForSegment(String(chars[p..<i])) else { return nil }
            seq.append(c); i = p
        }
        return Array(seq.reversed())
    }

    /// 切分专用：把子串归一到合法音节。
    /// 关键：禁止单字母辅音（n/m/r/l 等叹词音节）单独成音节，
    /// 否则英文单词会被硬切成汉字（hello -> hel/l/o -> 很㕶喔）。
    private func canonForSegment(_ sub: String) -> String? {
        if sub.count == 1 { return ["a","e","o"].contains(sub) ? sub : nil }
        return canon(sub)
    }

    /// 把任意拼音串归一到数据中存在的最接近音节（含模糊音等价）。不存在返回 nil。
    /// 声母模糊只做前缀替换、韵母模糊只做后缀替换，避免误伤正常拼写。
    private func canon(_ s: String) -> String? {
        if validSyllables.contains(s) { return s }
        for (a, b) in fuzzyInitials {
            if s.hasPrefix(a) { let c = b + String(s.dropFirst(a.count)); if validSyllables.contains(c) { return c } }
            if s.hasPrefix(b) { let c = a + String(s.dropFirst(b.count)); if validSyllables.contains(c) { return c } }
        }
        for (a, b) in fuzzyFinals {
            if s.hasSuffix(a) { let c = String(s.dropLast(a.count)) + b; if validSyllables.contains(c) { return c } }
            if s.hasSuffix(b) { let c = String(s.dropLast(b.count)) + a; if validSyllables.contains(c) { return c } }
        }
        return nil
    }

    /// 返回 s 及其所有「模糊音等价且数据中存在」的音节（s 自身在前）
    private func fuzzyVariants(_ s: String) -> [String] {
        var out = [s]
        func add(_ c: String) { if validSyllables.contains(c), !out.contains(c) { out.append(c) } }
        for (a, b) in fuzzyInitials {
            if s.hasPrefix(a) { add(b + String(s.dropFirst(a.count))) }
            if s.hasPrefix(b) { add(a + String(s.dropFirst(b.count))) }
        }
        for (a, b) in fuzzyFinals {
            if s.hasSuffix(a) { add(String(s.dropLast(a.count)) + b) }
            if s.hasSuffix(b) { add(String(s.dropLast(b.count)) + a) }
        }
        return out
    }

    /// 取某音节的首选汉字（含模糊音回退）
    private func topChar(_ syl: String) -> String? {
        if let c = charMap[syl]?.first { return c }
        for v in fuzzyVariants(syl) where v != syl {
            if let c = charMap[v]?.first { return c }
        }
        return nil
    }

    /// 对整条音节序列生成「逐音节模糊音替换」的候选 key（不含精确 key 自身）。
    /// 限长句不做笛卡尔积、组合数上限 32，防止键盘扩展每次按键卡顿。
    private func fuzzyKeys(_ seq: [String]) -> [String] {
        guard !seq.isEmpty, seq.count <= 3 else { return [] }
        let sets = seq.map { fuzzyVariants($0) }
        var combos = 1
        for s in sets { combos *= s.count; if combos > 32 { return [] } }
        var keys = sets[0]
        for i in 1..<sets.count {
            var next: [String] = []
            for k in keys { for o in sets[i] { next.append(k + " " + o) } }
            keys = next
        }
        let exact = seq.joined(separator: " ")
        return keys.filter { $0 != exact }
    }

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
