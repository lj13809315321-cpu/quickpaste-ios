import Foundation

/// mmap 二进制词表（build_lexicon.py 生成）。
/// 文件用 Data(.mappedIfSafe) 映射，系统按需分页；索引按 key 的 UTF-8 字节排序，
/// 二分查到后只解码命中的那一小段 value。因此词库从 2 万扩到 50 万条，
/// 键盘扩展的常驻内存几乎不变 —— 这是大词库不闪退的关键。
final class MappedTable {
    private let data: Data
    private let count: Int
    private let dataBase: Int
    private var cache: [String: String] = [:]     // 空串表示「查过但没有」

    init?(name: String) {
        var url: URL?
        let bundles: [Bundle] = [Bundle(for: MappedTable.self), Bundle.main] + Bundle.allBundles
        for b in bundles {
            if let u = b.url(forResource: name, withExtension: "bin") { url = u; break }
        }
        guard let u = url,
              let d = try? Data(contentsOf: u, options: .mappedIfSafe),
              d.count >= 24,
              [UInt8](d[0..<4]) == [UInt8]("MZLX".utf8) else { return nil }
        let c = Int(MappedTable.u32(d, 8))
        let db = Int(MappedTable.u32(d, 12))
        guard c > 0, db >= 24, db <= d.count, db + c * 12 <= d.count else { return nil }
        data = d
        count = c
        dataBase = db
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }
    private static func u32(_ p: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
        UInt32(p[o]) | (UInt32(p[o + 1]) << 8) | (UInt32(p[o + 2]) << 16) | (UInt32(p[o + 3]) << 24)
    }
    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) }
    private static func u16(_ p: UnsafeRawBufferPointer, _ o: Int) -> Int {
        Int(p[o]) | (Int(p[o + 1]) << 8)
    }

    var keyCount: Int { count }

    func value(for key: String) -> String? {
        if let hit = cache[key] { return hit.isEmpty ? nil : hit }
        let kb = Array(key.utf8)
        let found: String? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            var lo = 0, hi = count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let io = 24 + mid * 12
                let ko = dataBase + Int(MappedTable.u32(raw, io))
                let kl = MappedTable.u16(raw, io + 4)
                guard ko >= 0, ko + kl <= raw.count else { return nil }
                var cmp = 0
                let lim = min(kb.count, kl)
                for i in 0..<lim {
                    let a = kb[i], b = raw[ko + i]
                    if a < b { cmp = -1; break }
                    if a > b { cmp = 1; break }
                }
                if cmp == 0 { cmp = kb.count - kl }
                if cmp == 0 {
                    let vo = dataBase + Int(MappedTable.u32(raw, io + 6))
                    let vl = MappedTable.u16(raw, io + 10)
                    guard vo >= 0, vo + vl <= raw.count else { return nil }
                    let slice = UnsafeRawBufferPointer(
                        start: raw.baseAddress?.advanced(by: vo), count: vl)
                    return String(decoding: slice, as: UTF8.self)
                } else if cmp < 0 { hi = mid - 1 } else { lo = mid + 1 }
            }
            return nil
        }
        if cache.count > 512 { cache.removeAll() }
        cache[key] = found ?? ""
        return found
    }

    func words(for key: String) -> [String] {
        guard let v = value(for: key), !v.isEmpty else { return [] }
        return v.split(separator: "\t", omittingEmptySubsequences: true).map(String.init)
    }
}

/// 一次解码的结果。
/// - display: 候选栏上方那行拼音串（9 键也显示拼音，绝不显示数字）
/// - candidates: 可上屏的汉字候选，首位是整句
/// - key: 最佳音节序列，供用户自学习按拼音记词
struct DecodeResult {
    let display: String
    let candidates: [String]
    let key: String
    /// 9 键音节候选（搜狗左侧那列 ming / ning / min / nin）
    var alternates: [String] = []
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
    // 大表走 mmap 二进制（任意规模不占常驻内存），小表留内存字典。
    private var lexicon: MappedTable?                       // "ni hao" -> 词（主词库，可扩 50 万+）
    private var flatTable: MappedTable?                     // 去空格拼音串 -> 可信词（整串纠错）
    private var abbrTable: MappedTable?                     // 声母串 -> 词（超级简拼）
    private var freqTable: MappedTable?                     // 词 -> 真实词频
    private var phraseOverlay: [String: [String]] = [:]     // cat_net / 动态扩库覆盖层
    private var flatFallback: [String: [String]] = [:]      // bin 缺失时的 JSON 回退
    private var abbrFallback: [String: [String]] = [:]      // bin 缺失时的 JSON 回退

    private var charMap: [String: [String]] = [:]          // 音节 -> 汉字(按词频)
    private var phraseMap: [String: [String]] = [:]        // bin 不可用时的 JSON 回退
    private var assocNext: [String: [String]] = [:]        // 上屏词 -> 后续词
    private var charFreq: [String: Int] = [:]              // 单字 -> 语料词频
    private var wordFreq: [String: Int] = [:]              // bin 不可用时的 JSON 回退
    private var bigram: [String: [String: Int]] = [:]      // 字 -> 后继字 -> 次数
    private var englishSet: Set<String> = []
    private var t9Map: [String: [String]] = [:]            // 数字串 -> 音节(离线预计算)
    private var t9WordTable: [String: [[String]]] = [:]    // 数字串 -> [[词, 拼音key], ...] 9键整词直查
    private var pinyinToChars: [String: [String]] = [:]     // 单音节 -> 常用字(纠错用)
    private var customPhrases: [String: String] = [:]      // 自定义短语：缩写 -> 长文本

    private var validSyllables: Set<String> = []
    private var syllablePrefixes: Set<String> = []
    private var t9Prefixes: Set<String> = []
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

    /// 关键：初始化器里绝不读词库。键盘扩展在 UIInputViewController 构造阶段
    /// 同步解析 1MB+ JSON 会被 watchdog / jetsam 直接杀掉（表现就是「弹一下就没了」）。
    /// 改由 viewDidLoad 把 UI 先呈现出来，再分两帧加载。
    private init() { }

    private var coreLoaded = false
    private var extrasLoaded = false

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
        // autoreleasepool 让 JSONSerialization 产生的 NSDictionary/NSArray 中间对象
        // 在桥接成 Swift 字典后立刻释放。否则 11 个文件的中间对象会一路堆到
        // runloop 末尾，内存峰值直接翻倍 —— 这是键盘扩展被 jetsam 杀掉的主因。
        return autoreleasepool { () -> T? in
            guard let url = resourceURL(name), let d = try? Data(contentsOf: url) else { return nil }
            let obj = try? JSONSerialization.jsonObject(with: d, options: [])
            return obj as? T
        }
    }

    // MARK: - 加载（分两帧：UI 先出来，词库后补）

    /// 第 1 帧：打字必需的最小词库，跑完就能正常出整句候选。
    func loadCore() {
        guard !coreLoaded else { return }
        coreLoaded = true
        // 每个字典独立可选绑定：单个资源缺失只降级对应能力，绝不整体崩掉。
        if let m = loadJSON("pinyin_chars", as: [String: [String]].self) { charMap = m }
        if let m = loadJSON("pinyin_t9", as: [String: [String]].self) { t9Map = m }
        if let m = loadJSON("pinyin_char_freq", as: [String: Int].self) { charFreq = m }

        // 主词库与词频表走 mmap：这两个是唯一会随 50 万+ 语料线性膨胀的东西。
        lexicon = MappedTable(name: "lexicon")
        freqTable = MappedTable(name: "freq")
        if lexicon == nil, let m = loadJSON("pinyin_phrases", as: [String: [String]].self) { phraseMap = m }
        if freqTable == nil, let m = loadJSON("pinyin_hot_words", as: [String: Int].self) { wordFreq = m }

        isLoaded = !charMap.isEmpty && (lexicon != nil || !phraseMap.isEmpty)
        diagnostics = "chars=\(charMap.count) lexicon=\(lexicon?.keyCount ?? phraseMap.count)(mmap) " +
                      "freq=\(freqTable?.keyCount ?? wordFreq.count)"

        // 轻量索引只碰 414 个音节 + 219 个 T9 键。
        // 旧版在这里遍历 2 万个 phrase keys 做 split + 逐键 sorted，启动期 O(n log n)
        // 且临时字符串成堆，是「切过去弹一下就没了」的另一半原因。
        for syl in charMap.keys { validSyllables.insert(syl) }
        for syls in t9Map.values { for s in syls { validSyllables.insert(s) } }
        var c2p: [String: String] = [:]
        for (syl, chars) in charMap {
            for ch in chars where c2p[ch] == nil { c2p[ch] = syl }
        }
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
        // 单音节纠错索引：dign -> ding -> 顶
        for (syl, chars) in charMap { pinyinToChars[syl] = Array(chars.prefix(4)) }
    }

    /// 第 2 帧：联想 / bigram / 纠错 / 简拼 / 英文等增强数据，全部离线预计算好，
    /// 运行时只做 JSON 解析，零排序零遍历，把内存峰值摊到两个 runloop 周期。
    func loadExtras() {
        guard coreLoaded, !extrasLoaded else { return }
        extrasLoaded = true
        if let m = loadJSON("pinyin_assoc", as: [String: [String]].self) { assocNext = m }
        if let m = loadJSON("pinyin_t9_word", as: [String: [[String]]].self) { t9WordTable = m }
        if let m = loadJSON("pinyin_bigram", as: [String: [String: Int]].self) { bigram = m }
        if let m = loadJSON("pinyin_english", as: [String].self) { englishSet = Set(m) }
        flatTable = MappedTable(name: "flat")
        abbrTable = MappedTable(name: "abbr")
        if flatTable == nil, let m = loadJSON("pinyin_flat", as: [String: String].self) {
            for (k, w) in m { flatFallback[k] = [w] }
        }
        if abbrTable == nil, let m = loadJSON("pinyin_abbr", as: [String: [String]].self) {
            abbrFallback = m
        }
        if let ud = UserDefaults.standard.dictionary(forKey: "kb_user_dict") as? [String: [String: Int]] {
            userByPinyin = ud
        }
        if let m = loadJSON("cat_net", as: [String: [String]].self) { mergeCategory(m) }
        diagnostics += " assoc=\(assocNext.count) bigram=\(bigram.count) " +
                       "flat=\(flatTable?.keyCount ?? 0)(mmap) abbr=\(abbrTable?.keyCount ?? 0)(mmap)"
        decodeCache.removeAll()
    }

    func mergeCategory(_ dict: [String: [String]]) {
        for (k, vals) in dict {
            var arr = phraseOverlay[k] ?? []
            for v in vals where !arr.contains(v) { arr.append(v) }
            phraseOverlay[k] = arr
        }
        decodeCache.removeAll()
    }

    // MARK: - 统一词库入口（mmap 优先 → 覆盖层 → JSON 回退）
    private var wordsSortedCache: [String: [String]] = [:]

    private func words(forPinyinKey key: String) -> [String] {
        if let hit = wordsSortedCache[key] { return hit }
        func rank(_ x: String) -> Double {
            // hot JSON 人工精选序保持原序（闺蜜>归你），其余语料词按词频降序
            // （订单77 > 定单53）。与 verify_engine.py words_for 严格一致。
            if wordFreq[x] != nil { return -1e9 }
            return -Double(freqValue(x) ?? 0)
        }
        var res: [String]
        if let t = lexicon {
            let w = t.words(for: key)
            if !w.isEmpty {
                if let extra = phraseOverlay[key], !extra.isEmpty {
                    var all = extra
                    for x in w where !all.contains(x) { all.append(x) }
                    res = all.sorted(by: { rank($0) < rank($1) })
                } else {
                    res = w.sorted(by: { rank($0) < rank($1) })
                }
            } else {
                var out = phraseOverlay[key] ?? []
                for w in phraseMap[key] ?? [] where !out.contains(w) { out.append(w) }
                res = out.sorted(by: { rank($0) < rank($1) })
            }
        } else {
            var out = phraseOverlay[key] ?? []
            for w in phraseMap[key] ?? [] where !out.contains(w) { out.append(w) }
            res = out.sorted(by: { rank($0) < rank($1) })
        }
        if wordsSortedCache.count > 4096 { wordsSortedCache.removeAll() }
        wordsSortedCache[key] = res
        return res
    }

    private func freqValue(_ w: String) -> Int? {
        if let f = wordFreq[w] { return f }
        if let s = freqTable?.value(for: w), let f = Int(s) { return f }
        return nil
    }

    private func flatWords(_ k: String) -> [String] {
        if let t = flatTable { return t.words(for: k) }
        return flatFallback[k] ?? []
    }

    private func abbrWords(_ k: String) -> [String] {
        if let t = abbrTable { return t.words(for: k) }
        return abbrFallback[k] ?? []
    }

    /// 用户点选搜狗式音节候选（ming / ning / min / nin）后，给这个音节的常用字词。
    func candidates(forSyllable syl: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func push(_ s: String) { if !s.isEmpty, seen.insert(s).inserted { out.append(s) } }
        for w in words(forPinyinKey: syl).prefix(8) { push(w) }
        for c in (charMap[syl] ?? []).prefix(16) { push(c) }
        return Array(out.prefix(20))
    }

    /// 9 键音节候选：把当前数字串末尾 2~6 位能切出的所有合法音节列出来。
    /// 这就是搜狗左侧 wen / zen / ye / ze 那一列，用户按错数字也能一键改回来。
    func t9Alternates(_ buf: String) -> [String] {
        let chars = Array(buf)
        guard !chars.isEmpty else { return [] }
        var seen = Set<String>()
        var scored: [(String, Int)] = []
        let maxL = min(6, chars.count)
        if maxL < 2 { return [] }
        for l in stride(from: maxL, through: 2, by: -1) {
            let sub = String(chars[(chars.count - l)..<chars.count])
            for s in t9Map[sub] ?? [] {
                guard seen.insert(s).inserted else { continue }
                let f = topChar(s).flatMap { charFreq[$0] } ?? 1
                scored.append((s, f + l * 24))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(10).map { $0.0 }
    }

    /// 9 键左列音节候选（带该音节对应的数字位数）。
    /// 竞品标准（搜狗官方帮助 + qingjian 设计文档）：左列针对**第一个未确定的
    /// 位置**，即缓冲区前缀能读出的音节 —— 点选锁定该位置，剩余数字继续组词
    /// （gui 锁定后再打 64 → 闺蜜）。位数 == 音节字母数（一字母一数字）。
    func t9SyllableOptions(_ buf: String) -> [(String, Int)] {
        let chars = Array(buf)
        guard !chars.isEmpty else { return [] }
        let maxL = min(6, chars.count)
        guard maxL >= 2 else { return [] }
        var seen = Set<String>()
        var scored: [(String, Int, Int)] = []
        for l in stride(from: maxL, through: 2, by: -1) {
            let sub = String(chars[0..<l])          // 前缀：第一个未定位置
            for s in t9Map[sub] ?? [] {
                guard seen.insert(s).inserted else { continue }
                let f = topChar(s).flatMap { charFreq[$0] } ?? 1
                scored.append((s, f + l * 24, l))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(8).map { ($0.0, $0.2) }
    }

    /// 数字串 1 次误触变体：相邻键替换 / 漏按 / 多按。9 键模糊纠错用。
    private let t9Neighbors: [Character: String] = [
        "1": "24", "2": "135", "3": "265", "4": "175", "5": "2468",
        "6": "359", "7": "48", "8": "5709", "9": "68", "0": "8",
    ]
    private var t9VariantCache: [String: [String]] = [:]
    private func t9Variants(_ s: String) -> [String] {
        if let hit = t9VariantCache[s] { return hit }
        let c = Array(s)
        var out = Set<String>()
        // 替换一位为相邻键
        for i in 0..<c.count {
            for d in t9Neighbors[c[i]] ?? "" {
                var v = c; v[i] = d
                out.insert(String(v))
            }
        }
        // 漏按一位
        if c.count > 2 {
            for i in 0..<c.count {
                var v = c; v.remove(at: i)
                out.insert(String(v))
            }
        }
        // 多按一位
        if c.count < 6 {
            for i in 0...c.count {
                for d in "23456789" {
                    var v = c; v.insert(d, at: i)
                    out.insert(String(v))
                }
            }
        }
        let res = Array(out.filter { $0 != s && ($0.count >= 2) })
        if t9VariantCache.count > 256 { t9VariantCache.removeAll() }
        t9VariantCache[s] = res
        return res
    }

    // MARK: - 对外入口
    /// - locked: 用户已通过左列音节候选 / 分词键锁定的音节（搜狗式连贯输入）。
    ///   锁定音节与新数字串在词图里拼接打分：gui + mi 可以成词「闺蜜」，
    ///   点一下音节继续打字，正是竞品「越打越顺」的关键交互。
    func decode(_ buffer: String, is9Key: Bool, context: String = "", locked: [String] = [], deep: Bool = false) -> DecodeResult {
        let buf = buffer.lowercased()
        guard !buf.isEmpty || !locked.isEmpty else { return DecodeResult(display: "", candidates: [], key: "") }
        if locked.isEmpty {
            // 自定义短语优先级最高（地址 / 电话 / 固定话术，敲缩写直接上屏）
            if let text = customPhrases[buf], !text.isEmpty {
                return DecodeResult(display: "短语·" + buf, candidates: [text], key: "")
            }
            // 系统文本替换（UILexicon）同级优先：用户在 设置›键盘›文本替换 里配的
            if let text = appleShortcuts[buf], !text.isEmpty {
                return DecodeResult(display: "替换·" + buf, candidates: [text], key: "")
            }
            // U/V 模式（26 键）
            if !is9Key, buf.count >= 2, let first = buf.first, (first == "u" || first == "v"),
               let r = specialMode(buf) { return r }
        }
        let ckey = String(context.suffix(2))
        let lk = locked.joined(separator: " ")
        var ck = (is9Key ? "9|" : "26|") + buf + "|c=" + ckey + "|L=" + lk
        if deep { ck += "|D" }   // deep（停顿深度纠错）结果单独缓存
        if let hit = decodeCache[ck] { return hit }
        var result = computeDecode(buf, is9Key: is9Key, locked: locked, deep: deep)
        result = DecodeResult(display: result.display,
                              candidates: rerankByContext(result.candidates, context: ckey),
                              key: result.key, alternates: result.alternates)
        // 自定义短语的缩写前缀也给提示，不必打全
        if !is9Key, buf.count >= 2 {
            let hits = customPhrases.keys.filter { $0.hasPrefix(buf) }
                .sorted { $0.count < $1.count }.prefix(3).compactMap { customPhrases[$0] }
            if !hits.isEmpty {
                result = DecodeResult(display: result.display,
                                      candidates: hits + result.candidates,
                                      key: result.key, alternates: result.alternates)
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

    // MARK: - 苹果官方补充词库（UILexicon：系统「文本替换」+ 通讯录姓名 + 常用词）
    /// 这是苹果唯一对第三方键盘开放的官方词库 API（requestSupplementaryLexicon）。
    /// 系统里配的文本替换（如 omw→马上到）走缩写短语通道；
    /// 通讯录中文名转拼音注入候选（打人名不用再选字）；英文名进中英混输候选。
    private var appleShortcuts: [String: String] = [:]     // 系统文本替换：缩写 -> 长文本
    private var supplementByPinyin: [String: [String]] = [:] // 拼音键 -> 通讯录中文名
    private var extraEnglish: Set<String> = []              // 英文名/常用英文词
    private var appleLexiconLoaded = false

    func ingestAppleLexicon(_ entries: [(input: String, document: String)]) {
        guard !appleLexiconLoaded else { return }
        appleLexiconLoaded = true
        for e in entries {
            let input = e.input.trimmingCharacters(in: .whitespacesAndNewlines)
            let doc = e.document.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty, !doc.isEmpty, doc.count <= 60 else { continue }
            if input != doc {
                // 系统文本替换：用户主动配置的缩写，与自定义短语同级
                appleShortcuts[input.lowercased()] = doc
            } else if doc.count <= 12, doc.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil {
                extraEnglish.insert(doc.lowercased())
            } else if doc.count >= 2, doc.count <= 4 {
                // 中文名：逐字转拼音（charToPinyin 为首读音，多数人名准确）
                var syls: [String] = []
                var ok = true
                for ch in doc {
                    guard let s = charToPinyin[String(ch)] else { ok = false; break }
                    syls.append(s)
                }
                if ok {
                    let key = syls.joined(separator: " ")
                    var arr = supplementByPinyin[key] ?? []
                    if !arr.contains(doc) { arr.append(doc) }
                    supplementByPinyin[key] = arr
                }
            }
        }
        decodeCache.removeAll()
    }

    private func computeDecode(_ buf: String, is9Key: Bool, locked: [String] = [], deep: Bool = false) -> DecodeResult {
        var lats = syllableLattices(buf, is9Key: is9Key, level: 0)
        // 9 键按键层纠错（最多 1 次编辑错误，与搜狗同类实现）。
        // 触发条件：
        // 1) 没有任何完整切分（切不出）——必救；
        // 2) deep（停顿深度纠错）下头部完整路径全是碎片（没有任何「词长==音节数」
        //    整词命中）——真机：984 打成 dao'ren'zui'xiao'yi'tao 含 trusted 碎片词
        //    但整句是垃圾，搜狗能救回 凡人修仙传。
        // 锁定音节组词（用户明确意图）不进纠错。
        if is9Key, locked.isEmpty {
            let complete0 = lats.filter { $0.tail.isEmpty }
            var needRescue = complete0.isEmpty
            var weakSentences = false
            if !needRescue, deep {
                weakSentences = !complete0.prefix(6).contains { lat in
                    let full = lat.seq
                    let k = full.joined(separator: " ")
                    let w = words(forPinyinKey: k)
                    return w.prefix(4).contains { $0.count == full.count && isTrusted($0) }
                }
                needRescue = weakSentences
            }
            if needRescue {
                // 「切不出」才走放宽切分 l1；「deep 无整词」场景 l1 只会切出
                // 更多垃圾完整路径提前接管，直接进按键层纠错。
                let l1 = syllableLattices(buf, is9Key: true, level: 1, wide: deep)
                if !weakSentences, l1.contains(where: { $0.tail.isEmpty }) {
                    lats = l1
                } else {
                    // 四类按键纠错（搜狗五类中的四类，惩罚差异化）：
                    //   邻键替换(低) / 换位(中) / 多键删位(高) / 漏键插入(高)
                    var rescue: [Lattice] = []
                    let digits = Array(buf)
                    let positions: [Int] = digits.count <= 8
                        ? Array(0..<digits.count) : [digits.count - 1]

                    // 候选数字串整词直查（O(1)）：长串正确切分会被 beam 挤掉，
                    // 数字签名直查是唯一可靠通道（真机：984→948 换位救回凡人修仙传）
                    func t9Hit(_ cand: String, pen: Double) {
                        guard !t9WordTable.isEmpty else { return }
                        for hit in (t9WordTable[cand] ?? []).prefix(2) where hit.count >= 2 {
                            rescue.append(Lattice(seq: hit[1].split(separator: " ").map(String.init),
                                                  tail: "", score: 8000 - pen))
                        }
                    }
                    // 统一的候选串重切：lv0 找到完整路径即停（性能）
                    func reseek(_ cand: String, pen: Double) {
                        for lv in 0...1 {
                            let lr = syllableLattices(cand, is9Key: true, level: lv, wide: deep)
                            let ok = lr.filter { $0.tail.isEmpty }
                            if !ok.isEmpty {
                                rescue.append(contentsOf: ok.map {
                                    Lattice(seq: $0.seq, tail: "", score: $0.score - pen)
                                })
                                break
                            }
                        }
                    }

                    // 多键（多按一下）：删位重试，惩罚 300
                    for i in positions {
                        let cand = String(digits[0..<i]) + String(digits[(i+1)...])
                        t9Hit(cand, pen: 6000)
                        if cand.count >= 2 { reseek(cand, pen: 6000) }
                    }
                    // 邻键替换（最容易误触，惩罚最低 200）
                    let nb: [Character: String] = ["2":"13","3":"246","4":"357","5":"468",
                                                   "6":"359","7":"48","8":"579","9":"68"]
                    for i in positions {
                        for d in nb[digits[i]] ?? "" {
                            let cand = String(digits[0..<i]) + String(d) + String(digits[(i+1)...])
                            t9Hit(cand, pen: 4000)
                            reseek(cand, pen: 4000)
                        }
                    }
                    // 相邻位换位（Damerau，手速快顺序颠倒）：惩罚 250。
                    // 轻量模式长串只试尾两位；deep 全位扫描（真机错位多在中段）。
                    let swapPositions: [Int] = deep
                        ? Array(0..<max(0, digits.count - 1))
                        : (digits.count <= 8 ? Array(0..<max(0, digits.count - 1)) : [digits.count - 2])
                    for i in swapPositions where i + 1 < digits.count {
                        let cand = String(digits[0..<i]) + String(digits[i+1]) + String(digits[i])
                            + String(digits[(i+2)...])
                        t9Hit(cand, pen: 5000)
                        reseek(cand, pen: 5000)
                    }
                    // 漏键（手快漏按一位）：尾位插入全部数字重试，惩罚 300。
                    // 插入候选 ×8 成本高，长串只在 deep 模式做。
                    if deep || digits.count <= 10 {
                        for d in "23456789" {
                            let cand = buf + String(d)
                            t9Hit(cand, pen: 6000)
                            reseek(cand, pen: 6000)
                        }
                    }
                    if !rescue.isEmpty {
                        rescue.sort { $0.score > $1.score }
                        // 与原始路径合并统一排名（编辑惩罚已扣在 lattice score 里）
                        lats = rescue + lats
                    }
                }
            }
        }
        // 26 键尾部半截音节是正常输入状态，不算失败；只有完全切不出才逐级放宽纠错
        if !is9Key && lats.isEmpty {
            let l1 = syllableLattices(buf, is9Key: false, level: 1)
            if !l1.isEmpty { lats = l1 }
            else {
                let l2 = syllableLattices(buf, is9Key: false, level: 2)
                if !l2.isEmpty { lats = l2 }
            }
        }
        guard !lats.isEmpty else {
            if !locked.isEmpty {
                // 锁定音节 + 剩余数字还没成音节（含单键元音 a/e/o）：
                // 把剩余数字补全成音节与锁定音节组词 —— 锁 yu + 3 → yu'e → 余额（搜狗同款）
                var comps: [String] = []
                if !buf.isEmpty {
                    if is9Key {
                        // 补全音节消耗的数字必须 == 已输入位数（qingjian 对齐原则）：
                        // 锁 yu + "3" 只能补成 e（余额），不能预支成 dao（326 还没打出来）
                        if buf.count >= 2 { comps = t9Map[buf] ?? [] }
                        if buf == "2" { comps.append("a") }
                        if buf == "3" { comps.append("e") }
                        if buf == "6" { comps.append("o") }
                    } else {
                        comps = validSyllables.filter { $0.hasPrefix(buf) }
                    }
                }
                comps = Array(Set(comps)).sorted { sylScore($0) > sylScore($1) }
                // 按补全后的整句分排序，分高的先出（余额 > 鱼得这类拼凑）
                var scored: [(String, Double, String)] = []
                for syl in comps.prefix(6) {
                    let full = locked + [syl]
                    let (t, sc) = composeSentenceWithScore(full)
                    let wb: Double = words(forPinyinKey: full.joined(separator: " "))
                        .prefix(4).contains { isTrusted($0) } ? 200.0 : 0.0
                    scored.append((syl, sc + wb, t))
                }
                scored.sort { $0.1 > $1.1 }
                let disp = scored.first
                    .map { locked.joined(separator: "'") + "'" + $0.0 }
                    ?? locked.joined(separator: "'")
                var out: [String] = []
                var seen = Set<String>()
                for s in scored where seen.insert(s.2).inserted { out.append(s.2) }
                let lk = locked.joined(separator: " ")
                for w in words(forPinyinKey: lk).prefix(6) where seen.insert(w).inserted { out.append(w) }
                for syl in locked {
                    if let cs = charMap[syl] {
                        for c in cs.prefix(4) where seen.insert(c).inserted { out.append(c) }
                    }
                }
                return DecodeResult(display: disp,
                                    candidates: out.isEmpty ? [disp] : Array(out.prefix(20)),
                                    key: scored.first.map { (locked + [$0.0]).joined(separator: " ") } ?? lk,
                                    alternates: is9Key && !buf.isEmpty ? t9Alternates(buf) : [])
            }
            let d = is9Key ? t9Display(buf) : buf
            return DecodeResult(display: d,
                                candidates: prefixCandidates(buf, is9Key: is9Key, fallback: d),
                                key: "", alternates: is9Key ? t9Alternates(buf) : [])
        }

        // 关键：音节格的贪心分不作为最终排序，改由词格 viterbi 的整句分决定
        var ranked: [(Lattice, String, Double)] = []
        for lat in lats.prefix(24) {
            // 锁定音节拼在词图最前面统一打分（gui + mi 跨边界成词「闺蜜」）
            let full = locked + lat.seq
            let (text, sc) = composeSentenceWithScore(full)
            let key = full.joined(separator: " ")
            // 整串词表前 4 里任一可信词即给 whole 加成（明明常排在命名后面）
            var whole: Double = words(forPinyinKey: key).prefix(4).contains { isTrusted($0) } ? 200 : 0
            // 整串全词命中（词长 == 音节数，5字专名「凡人修仙传」整词直出）：
            // 必须明显压过「犯人+休息+按住」这类碎片拼接，提到 450
            if let first = words(forPinyinKey: key).first,
               first.count == full.count, isTrusted(first) {
                whole = 450
            }
            // 9 键必须优先「数字串完整切完」的路径。旧版让 mi'mi'mi'64 靠
            // 重复「秘密」刷分压过 ming'ming，于是出现「你也哦哦鄂哦此」。
            // 26 键的尾部半截音节是正常输入（ni'gan'jin'...'mian's），保持轻权重。
            let completeBonus: Double = is9Key
                ? (lat.tail.isEmpty ? 300 : -160)
                : (lat.tail.isEmpty ? 20 : 0)
            // 26键尾格是裸元音（a/o/e/n）时只能补出 啊/哦/额/嗯 语气字垃圾
            // （jian→ji+a、hao→ha+o 的拆尾，真机：麻烦提供订单哈哦），压 200
            let bareTailPenalty: Double = (!is9Key && ["a","o","e","n"].contains(lat.tail)) ? -200 : 0
            // 每音节固定成本（qingjian「音节少优先」原则）：碎片化切分
            // （hua→hu+a 多出一个音节、ni×4 叠音节刷分）整体出局，
            // 这是竞品整句连贯排序的根基。26 键比 9 键更重（长句路径更长）。
            let lengthCost: Double = Double(lat.seq.count) * (is9Key ? 120 : 150)
            let finalScore = sc - lengthCost + whole
                             + completeBonus + lat.score * 0.05 + bareTailPenalty
            ranked.append((Lattice(seq: full, tail: lat.tail, score: sc), text, finalScore))
        }
        // 9 键整词直查（搜狗长串直出原理）：长串 beam 会把正确切分挤掉
        // （fan'ren'xiu'xian'zhuan 被同码音节同分竞争裁掉），数字签名 O(1) 直查。
        if is9Key, locked.isEmpty, !t9WordTable.isEmpty {
            for hit in (t9WordTable[buf] ?? []).prefix(3) where hit.count >= 2 {
                let seq = hit[1].split(separator: " ").map(String.init)
                let (text2, sc2) = composeSentenceWithScore(seq)
                let final2 = sc2 - Double(seq.count) * 120 + 450 + 300
                ranked.append((Lattice(seq: seq, tail: "", score: sc2), text2, final2))
            }
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
        // 2) 整串是一个可信词时置顶。用 viterbi 的整句结果，而不是词库首序：
        // ming ming 的词库首序是「命名」，但口语首选是叠字词「明明」。
        let bestKey = best.seq.joined(separator: " ")
        if let first = sentences.first, isTrusted(first) { push(first) }
        else if let w = words(forPinyinKey: bestKey).prefix(4).first(where: { isTrusted($0) }) { push(w) }
        // 3) 整句候选
        for s in sentences.prefix(3) { push(s) }
        // 3.5) 锁定音节自身的词（点音节后候选立刻联动，不用等新键）
        if !locked.isEmpty {
            for w in words(forPinyinKey: locked.joined(separator: " ")).prefix(4) { push(w) }
        }
        // 4) 整串精确词 / 模糊音词
        for lat in ordered.prefix(3) {
            let key = lat.seq.joined(separator: " ")
            for w in words(forPinyinKey: key).prefix(8) { push(w) }
            for k in fuzzyKeys(lat.seq) {
                for w in words(forPinyinKey: k).prefix(4) { push(w) }
            }
        }
        // 5) 整串 1 次编辑纠错（dign -> 顶）
        if !is9Key { for w in correctionCandidates(for: buf) { push(w) } }
        // 6) 前缀词：打长句时允许一段一段上屏
        if best.seq.count >= 2 {
            for l in 2...min(5, best.seq.count) {
                let key = best.seq.prefix(l).joined(separator: " ")
                for w in words(forPinyinKey: key).prefix(3) { push(w) }
            }
            if best.seq.count - 1 >= 2 {
                for l in 2...min(4, best.seq.count - 1) {
                    let (s, _) = composeSentenceWithScore(Array(best.seq.prefix(l)))
                    push(s)
                }
            }
        }
        // 7) 超级简拼 + 英文（含 UILexicon 的英文名/常用英文词）
        if !is9Key {
            for w in abbrWords(buf).prefix(10) { push(w) }
            if englishSet.contains(buf) || extraEnglish.contains(buf) { push(buf) }
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
        return DecodeResult(display: display, candidates: Array(out.prefix(24)),
                            key: bestKey, alternates: is9Key ? t9Alternates(buf) : [])
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
    private func trimBeam(_ arr: [Node], per: Int = 8) -> [Node] {
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

    private func syllableLattices(_ buf: String, is9Key: Bool, level: Int, wide: Bool = false) -> [Lattice] {
        // wide（停顿深度纠错用）：桶宽/总数翻倍，防止正确切分被同码音节
        // 同分挤掉（真机：fan'ren'xiu'xian'zhuan 被裁剪出局）
        let chars = Array(buf)
        let n = chars.count
        guard n > 0 else { return [] }
        var beam: [Int: [Node]] = [0: [Node(seq: [], score: 0, lastChar: "")]]
        var finished: [Lattice] = []

        for i in 0..<n {
            guard let states = beam[i], !states.isEmpty else { continue }
            for st in states {
                // 9 键最少 2 位数字才成音节（离线索引已删掉 a/e/o 单字母音节），
                // 杜绝 ni'ye'o'e'o'e'o'ci 这种把数字串切碎的垃圾路径。
                let minL = is9Key ? 2 : 1
                let maxL = min(6, n - i)
                guard minL <= maxL else { continue }
                for l in minL...maxL {
                    let sub = String(chars[i..<(i + l)])
                    let opts: [(String, Int)]
                    if is9Key {
                        let exact = t9Map[sub] ?? []
                        var syls = exact
                        if syls.isEmpty && level > 0 {
                            // 数字串 1 次误触：相邻键按错 / 漏按 / 多按
                            var seen = Set<String>()
                            for v in t9Variants(sub).prefix(24) {
                                for s in t9Map[v] ?? [] where seen.insert(s).inserted {
                                    syls.append(s)
                                }
                            }
                        }
                        guard !syls.isEmpty else { continue }
                        let pen = exact.isEmpty ? 2 : 0
                        opts = Array(syls.prefix(6).map { ($0, pen) })
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
                                 + (is9Key ? Double(syl.count) * 6 : 0)  // 9键偏好完整长音节
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
            // 每层结束统一裁剪，长句不会越打越卡。
            // 宽度 10：同码音节对（62=ma/na × 9426=xian/xiao…）中间层会到
            // 十几个状态，太窄会把正确切分挤出（那现在 被吗现在挤掉的实测）。
            for j in (i + 1)...min(n, i + 6) {
                let cap = wide ? 20 : 10
                if let arr = beam[j], arr.count > cap {
                    beam[j] = trimBeam(arr, per: wide ? 16 : 8)
                }
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
            // 每个音节数桶留 6 个：同码音节（62=ma/na）经常同分，
            // 只留 4 个会把正确切分挤出、留下同分的兄弟切分（搜狗对比用例实测）
            let per = wide ? 12 : 6
            if let lst = byCount[c] { uniq.append(contentsOf: lst.prefix(per)) }
        }
        return Array(uniq.prefix(wide ? 48 : 24))
    }

    private func sylScore(_ syl: String) -> Double {
        guard let c = topChar(syl) else { return 0 }
        return min(55, 9 * log10(1 + Double(max(1, charFreq[c] ?? 1))))
    }

    private func bigramBonus(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty, let m = bigram[a] else { return 0 }
        return min(40, Double(m[b] ?? 0) * 2.5)
    }

    private func latticeBonus(_ seq: [String]) -> Double {
        let c = seq.count
        guard c >= 2 else { return 0 }
        var s = 0.0
        for k in 2...min(4, c) {
            let key = Array(seq[(c - k)..<c]).joined(separator: " ")
            if let w = words(forPinyinKey: key).first { s += isTrusted(w) ? 130 : 35 }
        }
        return s
    }

    private func isTrusted(_ w: String) -> Bool {
        // hot 精选词表专属（词频 172~341 刻度、人工校过）。93 万语料词走
        // freqValue 的 corpus 刻度进 base，但不享受 trusted 加成 ——
        // 否则「一按(rime 229250)」会压过「现在」，排序直接崩坏。
        if wordFreq[w] != nil { return true }
        if w.count >= 3 {
            var sum = 0
            for c in w { sum += charFreq[String(c)] ?? 0 }
            if sum >= 3 * 170 { return true }
        }
        return false
    }

    private func approxWordFreq(_ w: String) -> Int {
        if let f = freqValue(w) { return f }
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
            let ws = flatWords(v)
            for w in ws.prefix(2) { phraseHits.append((w, approxWordFreq(w) + 200)) }
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
        let lastWord: String
    }

    private func composeSentenceWithScore(_ seq: [String]) -> (String, Double) {
        let n = seq.count
        guard n > 0 else { return ("", 0) }
        var dp: [SentNode?] = [SentNode?](repeating: nil, count: n + 1)
        dp[0] = SentNode(score: 0, text: "", lastChar: "", lastWord: "")
        for i in 0..<n {
            guard let cur = dp[i] else { continue }
            for l in 1...min(6, n - i) {
                let key = Array(seq[i..<(i + l)]).joined(separator: " ")
                var options: [(String, Double)] = []
                let ps = words(forPinyinKey: key)
                if !ps.isEmpty {
                    for (idx, w) in ps.prefix(6).enumerated() {
                        // 三层刻度（与 verify_engine.py 严格一致）：
                        //  1) hot 精选词：字频和/2 + 词频 + 120 加成
                        //  2) 语料词（93万 freq.bin，压缩刻度≤341）：词频主导 + 字频点缀，
                        //     不加 120 —— rime 权重虚高的「一按」不能压过 hot 的「现在」
                        //  3) 生僻拼凑：字频和/4
                        var raw = 0
                        for c in w { raw += charFreq[String(c)] ?? 1 }
                        let wf = freqValue(w) ?? 0
                        // 四层刻度（与 verify_engine.py 严格一致）：
                        //  A hot JSON 精选词：字频和/2 + 词频 + 120 + 250/字长加成
                        //  B 启发式长词（3+字全常用字，如一按在/你你你）：只给弱加成，
                        //    否则 rime 语料的长词凭长词加成压过「现在」
                        //  C 语料词（93万 freq.bin）：词频主导 + 字频点缀
                        //  D 生僻拼凑：字频和/4
                        let b: Double
                        let bonus: Double
                        if wordFreq[w] != nil {
                            b = Double(raw) / 2.0 + Double(wf) + 120
                            bonus = Double(l - 1) * 250
                        } else if isTrusted(w) {
                            b = Double(raw) / 2.0 + Double(wf) + 40
                            bonus = Double(l - 1) * 70
                        } else if wf > 0 && l >= 3 {
                            // 语料 3+ 字词（洗手间/订单号/羽绒服）是整词输出主体，
                            // 18/音节会输给碎片组合，给 raw/2 + 180/音节
                            b = Double(wf) + Double(raw) / 2.0
                            bonus = Double(l - 1) * 180
                        } else if wf > 0 {
                            b = Double(wf) + Double(raw) / 10.0
                            bonus = Double(l - 1) * 18
                        } else {
                            b = Double(raw) / 4.0
                            bonus = Double(l - 1) * 18
                        }
                        // 明明 / 看看 / 渐渐 这类叠字词在口语里极常用，
                        // 让它们压过同音的普通双字词（ming ming：明明 > 命名）
                        let reduplication: Double = (w.count == 2 && w.first == w.last) ? 65 : 0
                        options.append((w, b + bonus + reduplication
                                        - 25 - Double(idx) * 10))
                    }
                }
                if l == 1, let cs = charMap[seq[i]] {
                    // 8 个字候选：长句整句拼字时字池太窄会拼出怪句
                    for (idx, c) in cs.prefix(8).enumerated() {
                        // 超高频单字封顶，防止「一」字频碾压「一杯」整词
                        var sc = Double(min(charFreq[c] ?? 1, 1200)) / 4.0 - 25 - Double(idx) * 6
                        // 句末语气词加成：口语收尾几乎都是 呀/吗/吧/啦，
                        // 「去呀」被「去要」压过就是因为字频差距。句末位置先验补齐。
                        // 裸元音音节（a/o/e）句末多是长音节拆尾垃圾（jian→ji+a 的"啊"、
                        // hao→ha+o 的"哦"，真机：订单哈哦/哪一站西啊），降为 60
                        if i + l == n, ["呀","嘛","吧","啦","哦","呢","啊","吗","哈","哟"].contains(c) {
                            sc += (seq[i] == "a" || seq[i] == "o" || seq[i] == "e") ? 60 : 460
                        }
                        options.append((c, sc))
                    }
                }
                if let ud = userByPinyin[key] {
                    for (w, f) in ud { options.append((w, 160 + Double(min(300, f * 20)))) }
                }
                // 通讯录中文名（UILexicon）：打人名拼音直接出全名
                if let names = supplementByPinyin[key] {
                    for w in names { options.append((w, 200)) }
                }
                for (w, ws) in options {
                    guard let f = w.first, let last = w.last else { continue }
                    var trans = cur.lastChar.isEmpty ? 0 : bigramBonus(cur.lastChar, String(f))
                    // 词级搭配（今天→天气）：viterbi 转移命中联想表给大加分，
                    // 这是「洗手间→在哪」「订单→号」衔接的真实信号（搜狗 LM 同源）
                    if !cur.lastWord.isEmpty, let arr = assocNext[cur.lastWord], arr.contains(w) {
                        trans += 150
                    }
                    // 「秘密+秘密」这类重复是碎片切分刷分的典型产物，重罚，
                    // 让 ming'ming → 明明 稳稳压过 mi'mi'mi'mi → 秘密秘密。
                    // 词频奖励（~200/词）进 base 后，惩罚量级同步放大。
                    let repeatPenalty: Double = (w == cur.lastWord) ? 560 : 0
                    let total = cur.score + ws + trans - repeatPenalty
                    let node = SentNode(score: total, text: cur.text + w,
                                        lastChar: String(last), lastWord: w)
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

    // MARK: - 联想（词级搭配 + 词库首字预测驱动）
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
        let c = Array(t)
        let maxL = min(4, c.count)
        // 1) 词级搭配（「今天→天气/晚上」这类真实共现），与拼音无关的最强信号
        for l in stride(from: maxL, through: 1, by: -1) {
            let k = String(c[(c.count - l)..<c.count])
            if let arr = assocNext[k] { for w in arr { push(w) } }
        }
        // 2) 超级联想：以上屏末字开头的词库词（「在→在哪/在这里」，搜狗同款）
        let last = String(t.suffix(1))
        if let py = charToPinyin[last], !py.isEmpty {
            for w in words(forPinyinKey: py) where w.count >= 2 && w.count <= 4 && w.hasPrefix(last) {
                push(w)
            }
        }
        // 3) 字级 bigram 高频后继
        if let nxt = bigram[last] {
            for (ch, _) in nxt.sorted(by: { $0.value > $1.value }).prefix(10) { push(ch) }
        }
        // 4) 个人历史（打过的同拼音词）
        if let key = pinyinKey(of: String(t.suffix(2))), let ud = userByPinyin[key] {
            for (w, _) in ud.sorted(by: { $0.value > $1.value }) { push(w) }
        }
        // 5) 标点 / 语气词垫底（用户还要打字，别让语气词占候选栏前半段）
        for p in ["，","。","？","！"] { push(p) }
        for p in ["～","、","吗","呢","吧","啊","呀","哦","嗯","哈","了","的"] { push(p) }
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
