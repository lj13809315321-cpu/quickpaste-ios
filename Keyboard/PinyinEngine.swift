import Foundation

/// 一次解码的结果。
/// - display: 候选栏上方那行拼音串（9 键也显示拼音，绝不显示数字）
/// - candidates: 可上屏的汉字候选，首位是整句
/// - key: 最佳音节序列，供用户自学习按拼音记词
struct DecodeResult {
    let display: String
    let candidates: [String]
    let key: String
}

/// 拼音输入法引擎（第三代：音节格 + 整句 viterbi + 编辑纠错 + 词级联想）。
///
/// 对应用户实测问题：
/// 1) 9 键不再做「数字串 -> 3^N 个字母组合」笛卡尔展开，改查离线生成的
///    pinyin_t9.json（数字串 -> 音节）+ 按音节数分桶的 beam 切分。
///    长句不再剪枝失败，也不再把「644265469678642678」当候选显示。
/// 2) 26 键允许尾部未成音节（ni'gan'jin'wo'qu'mian's），并自动补全半截音节，
///    给出「你赶紧我去面试」这种整句。
/// 3) 候选由词格 viterbi 用真实词频 + bigram 解码；整句优先，冷僻词压不过高频单字。
/// 4) 联想改用旧引擎语料里的 930 条词级搭配（你好→吗、今天→天气、我→想），
///    不再出现「好事之徒 / 好事多悭」这类以末字开头的成语。
/// 5) 整串 1 次编辑纠错（邻键误触 / 漏键 / 多键 / 字母对调），如 dign→顶。
/// 6) 固定 beam 宽度 + 三级缓存，单次按键计算量恒定（本地复刻 < 1.5ms/键）。
final class PinyinEngine {
    static let shared = PinyinEngine()

    // MARK: - 词库
    private var charMap: [String: [String]] = [:]          // 音节 -> 汉字(按词频)
    private var phraseMap: [String: [String]] = [:]        // "ni hao" -> 词(按真实词频)
    private var assocNext: [String: [String]] = [:]        // 上屏词 -> 后续词
    private var charFreq: [String: Int] = [:]              // 单字 -> 语料词频
    private var wordFreq: [String: Int] = [:]              // 可信高频词 -> 真实词频
    private var bigram: [String: [String: Int]] = [:]      // 字 -> 后继字 -> 次数
    private var englishSet: Set<String> = []
    private var t9Map: [String: [String]] = [:]            // 数字串 -> 音节(离线预计算)
    private var pinyinToWords: [String: [String]] = [:]    // 去空格拼音串 -> 可信词(纠错索引)
    private var customPhrases: [String: String] = [:]      // 自定义短语：缩写 -> 长文本
    private var pinyinToChars: [String: [String]] = [:]     // 单音节 -> 常用字(纠错用)

    private var validSyllables: Set<String> = []
    private var syllablePrefixes: Set<String> = []
    private var t9Prefixes: Set<String> = []
    private var abbrMap: [String: [String]] = [:]          // 超级简拼
    private var charToPinyin: [String: String] = [:]

    private(set) var isLoaded = false
    private(set) var diagnostics = ""

    private var userByPinyin: [String: [String: Int]] = [:] { didSet { saveUserDict() } }

    // MARK: - 缓存（连贯性的关键：退格/重复输入零成本）
    private var decodeCache: [String: DecodeResult] = [:]
    private var variantCache: [String: [(String, Int)]] = [:]
    private var assocCache: [String: [String]] = [:]

    private let digitLetters: [Character: [Character]] = [
        "2": ["a","b","c"], "3": ["d","e","f"], "4": ["g","h","i"],
        "5": ["j","k","l"], "6": ["m","n","o"], "7": ["p","q","r","s"],
        "8": ["t","u","v"], "9": ["w","x","y","z"],
    ]

    /// QWERTY 相邻键（误触纠错用）
    private let qwertyNeighbors: [Character: String] = [
        "q":"wa", "w":"qea", "e":"wrs", "r":"etd", "t":"ryf", "y":"tug", "u":"yih",
        "i":"uoj", "o":"ipk", "p":"ol", "a":"qwsz", "s":"qweadz", "d":"wersfcx",
        "f":"ertdgcv", "g":"rtyfhbv", "h":"tyujgbn", "j":"yuikhnm", "k":"uioljm",
        "l":"iopk", "z":"asx", "x":"zsdc", "c":"xdfv", "v":"cfgb", "b":"vghn",
        "n":"bhjm", "m":"njk",
    ]

    private let fuzzyInitials: [(String, String)] = [
        ("z","zh"), ("c","ch"), ("s","sh"), ("n","l"), ("f","h"), ("r","l"),
    ]
    private let fuzzyFinals: [(String, String)] = [
        ("an","ang"), ("en","eng"), ("in","ing"), ("ian","iang"), ("uan","uang"),
    ]

    private init() { load() }

    /// 键盘扩展里 Bundle.main 不一定指向 .appex 自己，三重回退保证词库一定能读到。
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

    private func loadJSON<T>(_ name: String, as type: T.Type) -> T? {
        guard let url = resourceURL(name), let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? T
    }

    // MARK: - 加载
    func load() {
        // 每个字典独立可选绑定：单个资源缺失只降级对应能力，绝不整体崩掉。
        if let m = loadJSON("pinyin_chars", as: [String: [String]].self) { charMap = m }
        if let m = loadJSON("pinyin_phrases", as: [String: [String]].self) { phraseMap = m }
        if let m = loadJSON("pinyin_assoc", as: [String: [String]].self) { assocNext = m }
        if let m = loadJSON("pinyin_char_freq", as: [String: Int].self) { charFreq = m }
        if let m = loadJSON("pinyin_hot_words", as: [String: Int].self) { wordFreq = m }
        if let m = loadJSON("pinyin_bigram", as: [String: [String: Int]].self) { bigram = m }
        if let m = loadJSON("pinyin_t9", as: [String: [String]].self) { t9Map = m }
        if let m = loadJSON("pinyin_english", as: [String].self) { englishSet = Set(m) }

        isLoaded = !charMap.isEmpty && !phraseMap.isEmpty
        diagnostics = "chars=\(charMap.count) phrases=\(phraseMap.count) assoc=\(assocNext.count) " +
                      "freq=\(wordFreq.count) bigram=\(bigram.count) t9=\(t9Map.count)"

        var c2p: [String: String] = [:]
        for (syl, chars) in charMap {
            validSyllables.insert(syl)
            for ch in chars where c2p[ch] == nil { c2p[ch] = syl }
        }
        for key in phraseMap.keys {
            for syl in key.split(separator: " ") { validSyllables.insert(String(syl)) }
        }
        for syls in t9Map.values { for s in syls { validSyllables.insert(s) } }
        charToPinyin = c2p

        for syl in validSyllables {
            let c = Array(syl)
            if c.isEmpty { continue }
            for i in 1...c.count { syllablePrefixes.insert(String(c[0..<i])) }
        }
        for key in t9Map.keys {
            let c = Array(key)
            for i in 1...c.count { t9Prefixes.insert(String(c[0..<i])) }
        }

        // 整串纠错索引：只收可信词，避免把冷僻成语当纠错结果
        for (key, words) in phraseMap {
            guard let w = words.first, isTrusted(w) else { continue }
            let flat = key.replacingOccurrences(of: " ", with: "")
            pinyinToWords[flat, default: []].append(w)
        }
        // 单音节纠错索引：dign -> ding -> 顶（用户明确举的例子）
        for (syl, chars) in charMap {
            pinyinToChars[syl] = Array(chars.prefix(4))
        }

        // 超级简拼表（2~3 字短语的声母串），离线预排序
        var abbr: [String: [String]] = [:]
        for (key, phrases) in phraseMap {
            let syls = key.split(separator: " ")
            guard (2...3).contains(syls.count) else { continue }
            let initials = syls.map { String($0.prefix(1)) }.joined()
            guard !initials.isEmpty else { continue }
            for p in phrases where !p.isEmpty { abbr[initials, default: []].append(p) }
        }
        for (k, v) in abbr {
            abbrMap[k] = Array(v.sorted { approxWordFreq($0) > approxWordFreq($1) }.prefix(20))
        }

        if let ud = UserDefaults.standard.dictionary(forKey: "kb_user_dict") as? [String: [String: Int]] {
            userByPinyin = ud
        }
        if let m = loadJSON("cat_net", as: [String: [String]].self) { mergeCategory(m) }
    }

    func mergeCategory(_ dict: [String: [String]]) {
        for (k, vals) in dict {
            var arr = phraseMap[k] ?? []
            for v in vals where !arr.contains(v) { arr.append(v) }
            phraseMap[k] = arr
        }
        decodeCache.removeAll()
    }

    // MARK: - 对外入口
    func decode(_ buffer: String, is9Key: Bool, context: String = "") -> DecodeResult {
        let buf = buffer.lowercased()
        guard !buf.isEmpty else { return DecodeResult(display: "", candidates: [], key: "") }
        // 自定义短语优先级最高（地址 / 电话 / 固定话术，敲缩写直接上屏）
        if let text = customPhrases[buf], !text.isEmpty {
            return DecodeResult(display: "短语·" + buf, candidates: [text], key: "")
        }
        // U/V 模式（26 键）
        if !is9Key, buf.count >= 2, let first = buf.first, (first == "u" || first == "v"),
           let r = specialMode(buf) { return r }
        let ckey = String(context.suffix(2))
        let ck = (is9Key ? "9|" : "26|") + buf + "|c=" + ckey
        if let hit = decodeCache[ck] { return hit }
        var result = computeDecode(buf, is9Key: is9Key)
        result = DecodeResult(display: result.display,
                              candidates: rerankByContext(result.candidates, context: ckey),
                              key: result.key)
        // 自定义短语的缩写前缀也给提示，不必打全
        if !is9Key, buf.count >= 2 {
            let hits = customPhrases.keys.filter { $0.hasPrefix(buf) }
                .sorted { $0.count < $1.count }.prefix(3).compactMap { customPhrases[$0] }
            if !hits.isEmpty {
                result = DecodeResult(display: result.display,
                                      candidates: hits + result.candidates, key: result.key)
            }
        }
        if decodeCache.count > 192 { decodeCache.removeAll() }
        decodeCache[ck] = result
        return result
    }

    func setCustomPhrases(_ dict: [String: String]) {
        customPhrases = [:]
        for (k, v) in dict where !k.isEmpty && !v.isEmpty {
            customPhrases[k.lowercased()] = v
        }
        decodeCache.removeAll()
    }

    private func computeDecode(_ buf: String, is9Key: Bool) -> DecodeResult {
        var lats = syllableLattices(buf, is9Key: is9Key, level: 0)
        // 尾部半截音节是正常输入状态，不算失败；只有完全切不出才逐级放宽纠错
        if !is9Key && lats.isEmpty {
            let l1 = syllableLattices(buf, is9Key: false, level: 1)
            if !l1.isEmpty { lats = l1 }
            else {
                let l2 = syllableLattices(buf, is9Key: false, level: 2)
                if !l2.isEmpty { lats = l2 }
            }
        }
        guard !lats.isEmpty else {
            let d = is9Key ? t9Display(buf) : buf
            return DecodeResult(display: d,
                                candidates: prefixCandidates(buf, is9Key: is9Key, fallback: d), key: "")
        }

        // 关键：音节格的贪心分不作为最终排序，改由词格 viterbi 的整句分决定
        var ranked: [(Lattice, String, Double)] = []
        for lat in lats.prefix(18) {
            let (text, sc) = composeSentenceWithScore(lat.seq)
            let key = lat.seq.joined(separator: " ")
            let whole: Double = (phraseMap[key]?.first).map { isTrusted($0) ? 200.0 : 0.0 } ?? 0
            let finalScore = sc - Double(lat.seq.count) * 12 + whole
                             + (lat.tail.isEmpty ? 20 : 0) + lat.score * 0.05
            ranked.append((lat, text, finalScore))
        }
        ranked.sort { $0.2 > $1.2 }
        let ordered = ranked.map { $0.0 }
        let sentences = ranked.map { $0.1 }
        let best = ordered[0]

        // 拼音串显示：mi'an 合回 mian，尾部半截音节用字母显示（搜狗的 mian's）
        var parts = best.seq
        if !best.tail.isEmpty, parts.count >= 2 {
            let merged = parts[parts.count - 2] + parts[parts.count - 1]
            if validSyllables.contains(merged) {
                parts = Array(parts.prefix(parts.count - 2)) + [merged]
            }
        }
        if !best.tail.isEmpty {
            parts.append(is9Key ? t9TailLetters(best.tail) : best.tail)
        }
        let display = parts.joined(separator: "'")

        var out: [String] = []
        var seen = Set<String>()
        func push(_ s: String) {
            guard !s.isEmpty, !seen.contains(s) else { return }
            seen.insert(s); out.append(s)
        }

        // 1) 尾部半截音节补全 + 音节重切：...mian's -> 你赶紧我去面试
        if !best.tail.isEmpty, best.seq.count >= 3 {
            let tail = best.tail
            var cands: [String] = []
            if is9Key {
                for (k, v) in t9Map where k.hasPrefix(tail) { cands.append(contentsOf: v) }
            } else {
                cands = validSyllables.filter { $0.hasPrefix(tail) }
            }
            cands = Array(Set(cands)).sorted { sylScore($0) > sylScore($1) }.prefix(3).map { $0 }
            var seqs: [[String]] = []
            if best.seq.count >= 2 {
                let merged = best.seq[best.seq.count - 2] + best.seq[best.seq.count - 1]
                if validSyllables.contains(merged) {
                    seqs.append(Array(best.seq.prefix(best.seq.count - 2)) + [merged])
                }
            }
            seqs.append(best.seq)
            for sq in seqs {
                for syl in cands {
                    let (t, _) = composeSentenceWithScore(sq + [syl])
                    push(t)
                }
            }
        }
        // 2) 整串恰好是一个可信高频词时置顶（你好 / 中国 / 世界 / 今天）
        let bestKey = best.seq.joined(separator: " ")
        if let w = phraseMap[bestKey]?.first, isTrusted(w) { push(w) }
        // 3) 整句候选
        for s in sentences.prefix(3) { push(s) }
        // 4) 整串精确词 / 模糊音词
        for lat in ordered.prefix(3) {
            let key = lat.seq.joined(separator: " ")
            if let ps = phraseMap[key] { for w in ps.prefix(8) { push(w) } }
            for k in fuzzyKeys(lat.seq) {
                if let ps = phraseMap[k] { for w in ps.prefix(4) { push(w) } }
            }
        }
        // 5) 整串 1 次编辑纠错（dign -> 顶）
        if !is9Key { for w in correctionCandidates(for: buf) { push(w) } }
        // 6) 前缀词：打长句时允许一段一段上屏
        if best.seq.count >= 2 {
            for l in 2...min(5, best.seq.count) {
                let key = best.seq.prefix(l).joined(separator: " ")
                if let ps = phraseMap[key] { for w in ps.prefix(3) { push(w) } }
            }
            if best.seq.count - 1 >= 2 {
                for l in 2...min(4, best.seq.count - 1) {
                    let (s, _) = composeSentenceWithScore(Array(best.seq.prefix(l)))
                    push(s)
                }
            }
        }
        // 7) 超级简拼 + 英文
        if !is9Key {
            if let ab = abbrMap[buf] { for w in ab.prefix(10) { push(w) } }
            if englishSet.contains(buf) { push(buf) }
        }
        // 8) 单字（保证任何情况都能选字）
        for lat in ordered.prefix(2) {
            let picks = lat.seq.count > 1 ? [lat.seq[0], lat.seq[lat.seq.count - 1]] : lat.seq
            for syl in picks {
                for (s2, _) in syllableCandidates(syl, level: 2) {
                    if let cs = charMap[s2] { for c in cs.prefix(10) { push(c) } }
                }
            }
        }
        if out.isEmpty { push(display) }
        if !is9Key, buf.count <= 24 { push(buf) }
        return DecodeResult(display: display, candidates: Array(out.prefix(24)), key: bestKey)
    }

    // MARK: - 音节格（按音节数分桶的 beam）
    private struct Lattice {
        let seq: [String]
        let tail: String        // 尾部未成音节部分
        let score: Double
    }
    private struct Node {
        let seq: [String]
        let score: Double
        let lastChar: String
    }

    /// 按「已切出的音节数」分桶保留：保证 zhong(1音节) 不会被 yin+ni(2音节) 挤掉。
    /// 纯 top-K 会系统性偏爱碎切分，这是之前 9 键「中国」被切成「印尼故哦」的根因。
    private func trimBeam(_ arr: [Node], per: Int = 2) -> [Node] {
        var buckets: [Int: [Node]] = [:]
        for n in arr { buckets[n.seq.count, default: []].append(n) }
        var out: [Node] = []
        for c in buckets.keys.sorted() {
            if let lst = buckets[c] {
                out.append(contentsOf: lst.sorted { $0.score > $1.score }.prefix(per))
            }
        }
        return out
    }

    private func syllableLattices(_ buf: String, is9Key: Bool, level: Int) -> [Lattice] {
        let chars = Array(buf)
        let n = chars.count
        guard n > 0 else { return [] }
        var beam: [Int: [Node]] = [0: [Node(seq: [], score: 0, lastChar: "")]]
        var finished: [Lattice] = []

        for i in 0..<n {
            guard let states = beam[i], !states.isEmpty else { continue }
            for st in states {
                for l in 1...min(6, n - i) {
                    let sub = String(chars[i..<(i + l)])
                    let opts: [(String, Int)]
                    if is9Key {
                        guard let syls = t9Map[sub] else { continue }
                        opts = Array(syls.prefix(6).map { ($0, 0) })
                    } else if level == 0 {
                        let ok = validSyllables.contains(sub) && (sub.count > 1 || ["a","e","o"].contains(sub))
                        opts = ok ? [(sub, 0)] : []
                    } else {
                        opts = syllableCandidates(sub, level: level)
                    }
                    guard !opts.isEmpty else { continue }
                    for (syl, penalty) in opts {
                        let seq = st.seq + [syl]
                        let top = topChar(syl) ?? ""
                        var sc = st.score + sylScore(syl) - 14 + bigramBonus(st.lastChar, top)
                                 - Double(penalty) * 12 + latticeBonus(seq) * 2
                        if syl.count == 1 { sc -= 25 }   // 单字母音节降权
                        let j = i + l
                        if j == n {
                            finished.append(Lattice(seq: seq, tail: "", score: sc + 60))
                        } else {
                            beam[j] = (beam[j] ?? []) + [Node(seq: seq, score: sc, lastChar: top)]
                        }
                    }
                }
            }
            // 每层结束统一裁剪，长句不会越打越卡
            for j in (i + 1)...min(n, i + 6) {
                if let arr = beam[j], arr.count > 6 { beam[j] = trimBeam(arr) }
            }
            // 尾部未成音节：允许继续输入（ni'gan'jin'wo'qu'mian's）
            let tail = String(chars[i..<n])
            let viable = is9Key ? t9Prefixes.contains(tail) : syllablePrefixes.contains(tail)
            if viable, tail.count <= 6 {
                for st in states.prefix(3) where !st.seq.isEmpty {
                    finished.append(Lattice(seq: st.seq, tail: tail, score: st.score - 12))
                }
            }
            beam[i] = nil
            if finished.count > 500 {
                finished.sort { $0.score > $1.score }
                finished = Array(finished.prefix(80))
            }
        }

        finished.sort { $0.score > $1.score }
        var seen = Set<String>()
        var byCount: [Int: [Lattice]] = [:]
        for f in finished {
            let k = f.seq.joined(separator: " ") + "|" + f.tail
            if seen.contains(k) { continue }
            seen.insert(k)
            byCount[f.seq.count, default: []].append(f)
        }
        var uniq: [Lattice] = []
        for c in byCount.keys.sorted() {
            if let lst = byCount[c] { uniq.append(contentsOf: lst.prefix(3)) }
        }
        return Array(uniq.prefix(18))
    }

    private func sylScore(_ syl: String) -> Double {
        guard let c = topChar(syl) else { return 0 }
        return min(55, 9 * log10(1 + Double(max(1, charFreq[c] ?? 1))))
    }

    private func bigramBonus(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty, let m = bigram[a] else { return 0 }
        return min(26, Double(m[b] ?? 0) * 2.5)
    }

    private func latticeBonus(_ seq: [String]) -> Double {
        let c = seq.count
        guard c >= 2 else { return 0 }
        var s = 0.0
        for k in 2...min(4, c) {
            let key = Array(seq[(c - k)..<c]).joined(separator: " ")
            if let w = phraseMap[key]?.first { s += isTrusted(w) ? 130 : 35 }
        }
        return s
    }

    private func isTrusted(_ w: String) -> Bool {
        if wordFreq[w] != nil { return true }
        if w.count >= 3 {
            var sum = 0
            for c in w { sum += charFreq[String(c)] ?? 0 }
            if sum >= 3 * 170 { return true }
        }
        return false
    }

    private func approxWordFreq(_ w: String) -> Int {
        if let f = wordFreq[w] { return f }
        var s = 0
        for c in w { s += charFreq[String(c)] ?? 1 }
        return min(150, s / max(1, w.count))
    }

    /// 单个字母片段 -> 可能的音节（含模糊音 / 1 次编辑纠错），带 penalty。
    private func syllableCandidates(_ s: String, level: Int = 2) -> [(String, Int)] {
        let ck = s + "|" + String(level)
        if let hit = variantCache[ck] { return hit }
        var out: [(String, Int)] = []
        var seen = Set<String>()
        func add(_ v: String, _ p: Int) {
            guard validSyllables.contains(v), !seen.contains(v) else { return }
            seen.insert(v); out.append((v, p))
        }
        if s.count == 1 {
            if ["a","e","o"].contains(s) { add(s, 0) }
            variantCache[ck] = out
            return out
        }
        add(s, 0)
        for (a, b) in fuzzyInitials {
            if s.hasPrefix(a) { add(b + String(s.dropFirst(a.count)), 1) }
            if s.hasPrefix(b) { add(a + String(s.dropFirst(b.count)), 1) }
        }
        for (a, b) in fuzzyFinals {
            if s.hasSuffix(a) { add(String(s.dropLast(a.count)) + b, 1) }
            if s.hasSuffix(b) { add(String(s.dropLast(b.count)) + a, 1) }
        }
        if level >= 2, (3...6).contains(s.count) {
            let arr = Array(s)
            for i in 0..<arr.count {
                if let nb = qwertyNeighbors[arr[i]] {
                    for ch in nb {
                        var a = arr; a[i] = ch
                        add(String(a), 2)
                    }
                }
                var del = arr; del.remove(at: i)
                add(String(del), 3)
            }
            if s.count <= 5 {
                for i in 0...arr.count {
                    for ch in "aeioun" {
                        var ins = arr; ins.insert(ch, at: i)
                        add(String(ins), 3)
                    }
                }
            }
        }
        out.sort { $0.1 < $1.1 }
        let res = Array(out.prefix(10))
        if variantCache.count > 700 { variantCache.removeAll() }
        variantCache[ck] = res
        return res
    }

    /// 整串 1 次编辑纠错：邻键按错、漏键、多键、相邻字母对调（dign -> ding -> 顶）
    private func correctionCandidates(for buf: String) -> [String] {
        guard (2...12).contains(buf.count) else { return [] }
        let arr = Array(buf)
        var variants = Set<String>()
        for i in 0..<arr.count {
            if let nb = qwertyNeighbors[arr[i]] {
                for ch in nb {
                    var a = arr; a[i] = ch
                    variants.insert(String(a))
                }
            }
            var del = arr; del.remove(at: i)
            variants.insert(String(del))
            if i + 1 < arr.count {
                var sw = arr; sw.swapAt(i, i + 1)
                variants.insert(String(sw))
            }
        }
        for i in 0...arr.count {
            for ch in "aeioun" {
                var ins = arr; ins.insert(ch, at: i)
                variants.insert(String(ins))
            }
        }
        variants.remove(buf)
        var phraseHits: [(String, Int)] = []
        var charHits: [(String, Int)] = []
        for v in variants {
            if let ws = pinyinToWords[v] {
                for w in ws.prefix(2) { phraseHits.append((w, approxWordFreq(w) + 200)) }
            }
            if let cs = pinyinToChars[v] {
                for c in cs.prefix(3) { charHits.append((c, charFreq[c] ?? 1)) }
            }
        }
        // 词组命中优先；只有词组没中时才把单字纠错顶上来（dign -> 顶）
        var hits = phraseHits.isEmpty ? charHits : phraseHits
        hits.sort { $0.1 > $1.1 }
        var out: [String] = []
        var seen = Set<String>()
        for (w, _) in hits where !seen.contains(w) {
            seen.insert(w); out.append(w)
            if out.count >= 6 { break }
        }
        return out
    }

    private func fuzzyKeys(_ seq: [String]) -> [String] {
        guard !seq.isEmpty, seq.count <= 3 else { return [] }
        let sets = seq.map { syl -> [String] in
            var v = [syl]
            for (a, b) in fuzzyInitials {
                if syl.hasPrefix(a) { let c = b + String(syl.dropFirst(a.count)); if validSyllables.contains(c) { v.append(c) } }
                if syl.hasPrefix(b) { let c = a + String(syl.dropFirst(b.count)); if validSyllables.contains(c) { v.append(c) } }
            }
            for (a, b) in fuzzyFinals {
                if syl.hasSuffix(a) { let c = String(syl.dropLast(a.count)) + b; if validSyllables.contains(c) { v.append(c) } }
                if syl.hasSuffix(b) { let c = String(syl.dropLast(b.count)) + a; if validSyllables.contains(c) { v.append(c) } }
            }
            return v
        }
        var combos = 1
        for s in sets { combos *= s.count; if combos > 24 { return [] } }
        var keys = sets[0]
        if sets.count > 1 {
            for i in 1..<sets.count {
                var next: [String] = []
                for k in keys { for o in sets[i] { next.append(k + " " + o) } }
                keys = next
            }
        }
        let exact = seq.joined(separator: " ")
        return keys.filter { $0 != exact }
    }

    // MARK: - 整句 viterbi（词格）
    private struct SentNode {
        let score: Double
        let text: String
        let lastChar: String
    }

    private func composeSentenceWithScore(_ seq: [String]) -> (String, Double) {
        let n = seq.count
        guard n > 0 else { return ("", 0) }
        var dp: [SentNode?] = [SentNode?](repeating: nil, count: n + 1)
        dp[0] = SentNode(score: 0, text: "", lastChar: "")
        for i in 0..<n {
            guard let cur = dp[i] else { continue }
            for l in 1...min(6, n - i) {
                let key = Array(seq[i..<(i + l)]).joined(separator: " ")
                var options: [(String, Double)] = []
                if let ps = phraseMap[key] {
                    for (idx, w) in ps.prefix(4).enumerated() {
                        // 可信高频词享受长词加成；冷僻词不给，避免「曲面」压过「去+面」
                        var base = 0
                        for c in w { base += charFreq[String(c)] ?? 1 }
                        let hot = isTrusted(w)
                        let b = hot ? Double(base) / 2.0 : Double(base) / 4.0
                        let bonus = Double(l - 1) * (hot ? 70 : 18)
                        options.append((w, b + bonus + (hot ? 120 : 0) - 25 - Double(idx) * 10))
                    }
                }
                if l == 1, let cs = charMap[seq[i]] {
                    for (idx, c) in cs.prefix(4).enumerated() {
                        options.append((c, Double(charFreq[c] ?? 1) / 4.0 - 25 - Double(idx) * 6))
                    }
                }
                if let ud = userByPinyin[key] {
                    for (w, f) in ud { options.append((w, 160 + Double(min(300, f * 20)))) }
                }
                for (w, ws) in options {
                    guard let f = w.first, let last = w.last else { continue }
                    let trans = cur.lastChar.isEmpty ? 0 : bigramBonus(cur.lastChar, String(f))
                    let total = cur.score + ws + trans
                    let node = SentNode(score: total, text: cur.text + w, lastChar: String(last))
                    if dp[i + l] == nil || total > dp[i + l]!.score { dp[i + l] = node }
                }
            }
        }
        return (dp[n]?.text ?? "", dp[n]?.score ?? 0)
    }

    private func topChar(_ syl: String) -> String? {
        if let c = charMap[syl]?.first { return c }
        for (v, _) in syllableCandidates(syl, level: 2) where v != syl {
            if let c = charMap[v]?.first { return c }
        }
        return nil
    }

    // MARK: - 拼音串显示
    /// 9 键尾部数字 -> 最可能的拼音字母前缀（"7" -> "s"，像搜狗的 mian's）
    private func t9TailLetters(_ digits: String) -> String {
        let arr = Array(digits)
        var out = ""
        for i in 0..<arr.count {
            let prefix = String(arr[0...i])
            var votes: [Character: Int] = [:]
            for (k, syls) in t9Map where k.hasPrefix(prefix) {
                for syl in syls {
                    let c = Array(syl)
                    if c.count > i { votes[c[i], default: 0] += (charFreq[charMap[syl]?.first ?? ""] ?? 1) }
                }
            }
            if let best = votes.max(by: { $0.value < $1.value })?.key {
                out.append(best)
            } else {
                out.append(digitLetters[arr[i]]?.first ?? arr[i])
            }
        }
        return out
    }

    private func t9Display(_ digits: String) -> String {
        var out = ""
        for d in digits { out.append(digitLetters[d]?.first ?? d) }
        return out
    }

    /// 刚按下第一个键（还没凑成完整音节）也要出候选，避免「按了没反应」。
    private func prefixCandidates(_ buf: String, is9Key: Bool, fallback: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let syls: [String]
        if is9Key {
            var tmp: [String] = []
            for (k, v) in t9Map where k.hasPrefix(buf) { tmp.append(contentsOf: v) }
            syls = tmp
        } else {
            syls = validSyllables.filter { $0.hasPrefix(buf) }
        }
        let sorted = Array(Set(syls)).sorted { sylScore($0) > sylScore($1) }.prefix(16)
        for s in sorted {
            if let c = charMap[s]?.first, !seen.contains(c) { seen.insert(c); out.append(c) }
        }
        if !is9Key { out.append(buf) }
        if out.isEmpty { out.append(fallback) }
        return Array(out.prefix(16))
    }

    // MARK: - 上下文感知：顺着前面打的话调候选顺序
    /// 只重排前 10 个候选，用「上屏末字 -> 候选首字」的字级 bigram 和词级搭配加分。
    /// 例：刚打了「我」，后面候选里的「想 / 要 / 们」会自动往前。
    private func rerankByContext(_ cands: [String], context: String) -> [String] {
        guard !context.isEmpty, cands.count > 1 else { return cands }
        let last = String(context.suffix(1))
        let two = String(context.suffix(2))
        let nxt = bigram[last] ?? [:]
        let hot1 = Set(assocNext[last] ?? [])
        let hot2 = Set(assocNext[two] ?? [])
        let head = Array(cands.prefix(10))
        let scored: [(String, Double)] = head.enumerated().map { idx, w in
            var s = Double(10 - idx) * 0.12           // 轻微保序，避免乱跳
            if let f = w.first { s += min(14, Double(nxt[String(f)] ?? 0) * 1.6) }
            if hot2.contains(w) { s += 32 }
            if hot1.contains(w) { s += 16 }
            return (w, s)
        }
        let reordered = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        return reordered + Array(cands.dropFirst(10))
    }

    // MARK: - U 模式（拆字）/ V 模式（数字·日期·算式）
    /// 常见合体字的部件拼音串（不会读也能打出来），内置轻量表，不额外占词库内存。
    private let ubuild: [String: String] = [
        "mumu":"林", "mumumu":"森", "huohuo":"炎", "huohuohuo":"焱",
        "riyue":"明", "nvzi":"好", "zilv":"好", "tianli":"男", "xiaoda":"尖",
        "renmu":"休", "renyan":"信", "renren":"从", "renrenren":"众",
        "muzi":"李", "shanshi":"岩", "shanshan":"出", "riri":"昌",
        "yueyue":"朋", "koukou":"吕", "koukoukou":"品", "tutututu":"垚",
        "jimu":"机", "mugong":"杠", "mufan":"板", "muqiao":"桥",
        "shuimu":"沐", "shuiqing":"清", "shuihe":"河", "shuihai":"海",
        "huoshan":"灿", "huotian":"畑", "huori":"炅", "huokou":"焙",
        "jinkou":"铜", "jintu":"铁", "jinshi":"矿", "mujin":"铃",
        "nvernv": "奻", "nvnv": "奻",
        "shanfeng":"峰", "shanling":"岭", "shishi":"磊", "shishishi":"磊",
        "tianxin":"思", "xintian":"思", "rixin":"意", "liri":"旱",
        "yuemen":"闷", "menkou":"问", "menri":"间", "menmu":"闲",
        "daxiao":"尖", "xiaotu":"尘", "xiaohuo":"炒", "baishui":"泉",
        "liba":"吧", "kouma":"吗", "kouna":"哪", "koua":"啊",
        "renkou":"合", "renshou":"拿", "shoumu":"采", "mushou":"采",
    ]

    func specialMode(_ buf: String) -> DecodeResult? {
        guard buf.count >= 2, let p = buf.first else { return nil }
        let b = String(buf.dropFirst()).lowercased()
        guard !b.isEmpty else { return nil }
        var cands: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            if !s.isEmpty, !seen.contains(s) { seen.insert(s); cands.append(s) }
        }
        if p == "v" {
            if b == "rq" || b == "date" {
                add(cnDate(Date())); add(shortDate(Date()))
            } else if b == "sj" || b == "time" {
                add(cnTime(Date()))
            } else if b.allSatisfy({ $0.isNumber }) {
                add(chineseUppercase(b))
                add(b + "元整")
                add(b)
            } else if let r = evalExpression(b) {
                add(r)
                add(b + " = " + r)
            }
        } else if p == "u" {
            if let ch = ubuild[b] { add(ch) }
            for (k, v) in ubuild where k != b && k.hasPrefix(b) {
                add(v)
                if cands.count >= 8 { break }
            }
        }
        guard !cands.isEmpty else { return nil }
        return DecodeResult(display: (p == "u" ? "U拆字 " : "V ") + b,
                            candidates: Array(cands.prefix(10)), key: "")
    }

    private func cnDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"; return f.string(from: d)
    }
    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    private func cnTime(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    /// 整数转人民币大写（最多 12 位）
    private func chineseUppercase(_ s: String) -> String {
        let digits = Array(s)
        guard !digits.isEmpty, digits.count <= 12, digits.allSatisfy({ $0.isNumber }) else { return "" }
        let num = ["零","壹","贰","叁","肆","伍","陆","柒","捌","玖"]
        let unit = ["","拾","佰","仟","万","拾","佰","仟","亿","拾","佰","仟"]
        var out = ""
        var zeroPending = false
        for (i, ch) in digits.enumerated() {
            let d = Int(String(ch)) ?? 0
            let u = unit[digits.count - 1 - i]
            if d == 0 {
                zeroPending = !out.isEmpty
                if u == "万" || u == "亿" { out += u; zeroPending = false }
            } else {
                if zeroPending { out += "零"; zeroPending = false }
                out += num[d] + u
            }
        }
        return out.isEmpty ? "零" : out
    }

    /// 只放行纯数字与四则运算符，用自写解析器计算。
    /// 不用 NSExpression：非法表达式（如 v1+）会抛 OC 异常导致键盘扩展崩溃。
    private struct Calc {
        let a: [Character]
        var i = 0
        init(_ s: String) { a = Array(s) }
        func peek() -> Character? { i < a.count ? a[i] : nil }
        mutating func num() -> Double? {
            var s = ""
            while let c = peek(), c.isNumber || c == "." { s.append(c); i += 1 }
            return s.isEmpty ? nil : Double(s)
        }
        mutating func factor() -> Double? {
            if peek() == "-" { i += 1; guard let v = factor() else { return nil }; return -v }
            if peek() == "(" {
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            return num()
        }
        mutating func term() -> Double? {
            guard var v = factor() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                i += 1
                guard let n = factor() else { return nil }
                if c == "*" { v *= n } else { if n == 0 { return nil }; v /= n }
            }
            return v
        }
        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let n = term() else { return nil }
                if c == "+" { v += n } else { v -= n }
            }
            return v
        }
        func atEnd() -> Bool { i >= a.count }
    }

    private func evalExpression(_ s: String) -> String? {
        guard s.count >= 3,
              s.range(of: "^[0-9+\\-*/().]+$", options: .regularExpression) != nil,
              let last = s.last, last.isNumber || last == ")" else { return nil }
        var c = Calc(s)
        guard let d = c.expr(), c.atEnd(), !d.isNaN, !d.isInfinite else { return nil }
        if abs(d - d.rounded()) < 1e-9 { return String(Int(d)) }
        return String(format: "%.4g", d)
    }

    // MARK: - 联想（词级搭配驱动）
    func associations(for context: String) -> [String] {
        let t = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        if let hit = assocCache[t] { return hit }
        var out: [String] = []
        var seen = Set<String>()
        func push(_ s: String) {
            guard !s.isEmpty, s != t, !seen.contains(s) else { return }
            seen.insert(s); out.append(s)
        }
        for p in ["，","！","。","？"] { push(p) }
        // 词级搭配紧跟标点，别让一整排语气词把「吗 / 天气 / 想」挤到后面
        let c = Array(t)
        let maxL = min(4, c.count)
        for l in stride(from: maxL, through: 1, by: -1) {
            let k = String(c[(c.count - l)..<c.count])
            if let arr = assocNext[k] { for w in arr { push(w) } }
        }
        for p in ["～","、","吗","呢","吧","啊","呀","哦","嗯","哈","了","的"] { push(p) }
        let last = String(t.suffix(1))
        if let nxt = bigram[last] {
            for (ch, _) in nxt.sorted(by: { $0.value > $1.value }).prefix(10) { push(ch) }
        }
        if let key = pinyinKey(of: String(t.suffix(2))), let ud = userByPinyin[key] {
            for (w, _) in ud.sorted(by: { $0.value > $1.value }) { push(w) }
        }
        let res = Array(out.prefix(20))
        if assocCache.count > 160 { assocCache.removeAll() }
        assocCache[t] = res
        return res
    }

    // MARK: - 个人学习（动态调频）
    /// - pinyinKey: 本次解码得到的最佳音节序列，比逐字反查更准
    /// - boost: 退格改选后给更大权重，实现「越改越懂你」
    func learn(_ text: String, pinyinKey key: String? = nil, boost: Int = 1) {
        guard text.count <= 8 else { return }
        let k = key?.isEmpty == false ? key! : pinyinKey(of: text)
        guard let k = k, !k.isEmpty else { return }
        var inner = userByPinyin[k] ?? [:]
        inner[text, default: 0] += max(1, boost)
        userByPinyin[k] = inner
        decodeCache.removeAll()
        assocCache.removeAll()
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
        var toDrop = total - 5000
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
