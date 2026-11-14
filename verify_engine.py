# -*- coding: utf-8 -*-
"""用 Python 忠实复刻 Swift 引擎的解码链路，本地验证效果与耗时。
云端打包前先跑这个，避免把错算法编译进 IPA。

本版同步：
1. words_for() 读 mmap 词库 lexicon.bin（93 万条）—— 与 Swift words(forPinyinKey:) 同序
2. decode(locked=) 音节锁定管线 —— 左列/分词键点选后跨音节组词
3. t9_syllable_options() 前缀音节列 —— 竞品「第一个未定位置」标准
4. 逐键节奏测试 —— 模拟真实打字过程（竞品连贯性对照）
"""
import json, os, math, struct, time
from collections import defaultdict

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Keyboard")
def load(name):
    with open(os.path.join(OUT, name), encoding="utf-8") as f:
        return json.load(f)

# ---------- mmap 词库（与 Swift MappedTable 同格式二分） ----------
class Lex:
    """MZLX 格式：24B 头 + count*12B 索引（按 key UTF-8 字节序）+ 数据区。"""
    def __init__(self, path):
        with open(path, "rb") as f:
            self.d = f.read()
        assert self.d[:4] == b"MZLX", "lexicon.bin magic"
        self.count = struct.unpack_from("<I", self.d, 8)[0]
        self.base = struct.unpack_from("<I", self.d, 12)[0]
        self.cache = {}

    def get(self, key):
        if key in self.cache:
            return self.cache[key]
        kb = key.encode("utf-8")
        lo, hi = 0, self.count
        hit = None
        while lo < hi:
            mid = (lo + hi) // 2
            koff, klen, voff, vlen = struct.unpack_from("<IHIH", self.d, 24 + mid * 12)
            mk = self.d[self.base + koff:self.base + koff + klen]
            if mk < kb:
                lo = mid + 1
            elif mk > kb:
                hi = mid
            else:
                hit = self.d[self.base + voff:self.base + voff + vlen] \
                    .decode("utf-8").split("\t")
                break
        self.cache[key] = hit
        return hit

lex = Lex(os.path.join(OUT, "lexicon.bin"))
freqLex = Lex(os.path.join(OUT, "freq.bin"))

def wf(w):
    """与 Swift freqValue 同：wordFreq(JSON hot) → freq.bin(93万语料压缩刻度)"""
    if w in wordFreq: return wordFreq[w]
    v = freqLex.get(w)
    if v: return int(v[0])
    return None

charMap = load("pinyin_chars.json")
phraseMap = load("pinyin_phrases.json")
assocNext = load("pinyin_assoc.json")
charFreq = load("pinyin_char_freq.json")
wordFreq = load("pinyin_hot_words.json")
bigram = load("pinyin_bigram.json")
t9Map = load("pinyin_t9.json")
english = set(load("pinyin_english.json"))

def words_for(key):
    """与 Swift words(forPinyinKey:) 同序：mmap 词库优先，JSON 词表补充。"""
    w = lex.get(key)
    if w:
        pm = phraseMap.get(key)
        if not pm:
            return w
        all_ = list(pm)
        for x in w:
            if x not in all_:
                all_.append(x)
        return all_
    return phraseMap.get(key) or []

valid = set(charMap) | {s for k in phraseMap for s in k.split()} | {s for v in t9Map.values() for s in v}
sylPrefixes = set()
for s in valid:
    for i in range(1, len(s) + 1):
        sylPrefixes.add(s[:i])
t9Prefixes = set()
for k in t9Map:
    for i in range(1, len(k) + 1):
        t9Prefixes.add(k[:i])

digitLetters = {"2":"abc","3":"def","4":"ghi","5":"jkl","6":"mno","7":"pqrs","8":"tuv","9":"wxyz"}
neighbors = {
 "q":"wa","w":"qea","e":"wrs","r":"etd","t":"ryf","y":"tug","u":"yih","i":"uoj","o":"ipk","p":"ol",
 "a":"qwsz","s":"qweadz","d":"wersfcx","f":"ertdgcv","g":"rtyfhbv","h":"tyujgbn","j":"yuikhnm",
 "k":"uioljm","l":"iopk","z":"asx","x":"zsdc","c":"xdfv","v":"cfgb","b":"vghn","n":"bhjm","m":"njk"}
fuzzyInit = [("z","zh"),("c","ch"),("s","sh"),("n","l"),("f","h"),("r","l")]
fuzzyFin = [("an","ang"),("en","eng"),("in","ing"),("ian","iang"),("uan","uang")]

variantCache = {}
def topChar(syl):
    a = charMap.get(syl)
    return a[0] if a else ""

def sylScore(syl):
    c = topChar(syl)
    return min(55, 9 * math.log10(1 + max(1, charFreq.get(c, 1)))) if c else 0

def bigramBonus(a, b):
    if not a or not b: return 0
    return min(40, bigram.get(a, {}).get(b, 0) * 2.5)

def approxWordFreq(w):
    f = wf(w)
    if f: return f
    return min(150, sum(charFreq.get(c, 1) for c in w) / max(1, len(w)))

def syllableCandidates(s, level=2):
    ck = (s, level)
    if ck in variantCache: return variantCache[ck]
    seen, out = set(), []
    def add(v, p):
        if v in valid and v not in seen:
            seen.add(v); out.append((v, p))
    if len(s) == 1:
        if s in ("a","e","o"): add(s, 0)
        variantCache[ck] = out
        return out
    add(s, 0)
    for a,b in fuzzyInit:
        if s.startswith(a): add(b + s[len(a):], 1)
        if s.startswith(b): add(a + s[len(b):], 1)
    for a,b in fuzzyFin:
        if s.endswith(a): add(s[:-len(a)] + b, 1)
        if s.endswith(b): add(s[:-len(b)] + a, 1)
    if level >= 2 and 3 <= len(s) <= 6:
        arr = list(s)
        for i in range(len(arr)):
            for ch in neighbors.get(arr[i], ""):
                t = arr[:]; t[i] = ch; add("".join(t), 2)
            add("".join(arr[:i] + arr[i+1:]), 3)
        if len(s) <= 5:
            for i in range(len(arr)+1):
                for ch in "aeioun":
                    t = arr[:]; t.insert(i, ch); add("".join(t), 3)
    out.sort(key=lambda x: x[1])
    res = out[:10]
    variantCache[ck] = res
    return res

def latticeBonus(seq):
    c = len(seq)
    if c < 2: return 0
    s = 0.0
    for k in range(2, min(4, c) + 1):
        key = " ".join(seq[c-k:])
        w = words_for(key)
        if w:
            s += 130 if trusted(w[0]) else 35
    return s

def trimBeamBucket(arr, per=6):
    buckets = defaultdict(list)
    for node in arr:
        buckets[len(node[0])].append(node)
    out = []
    for c in sorted(buckets):
        out += sorted(buckets[c], key=lambda x: -x[1])[:per]
    return out

def syllableLattices(buf, is9, level=0):
    n, W = len(buf), 8
    beam = {0: [((), 0.0, "")]}
    finished = []
    for i in range(n):
        states = beam.get(i)
        if not states: continue
        for seq, sc, last in states:
            for l in range(2 if is9 else 1, min(6, n - i) + 1):
                sub = buf[i:i+l]
                if is9:
                    opts = [(s, 0) for s in t9Map.get(sub, [])[:6]]
                elif level == 0:
                    opts = [(sub, 0)] if sub in valid and (len(sub) > 1 or sub in ("a","e","o")) else []
                else:
                    opts = syllableCandidates(sub, level)
                for syl, pen in opts:
                    nseq = seq + (syl,)
                    top = topChar(syl)
                    ns = (sc + sylScore(syl) - 14 + bigramBonus(last, top)
                          - pen * 12 + latticeBonus(list(nseq)) * 2
                          + (len(syl) * 6 if is9 else 0))
                    if len(syl) == 1: ns -= 25
                    j = i + l
                    if j == n:
                        finished.append((nseq, "", ns + 60))
                    else:
                        beam.setdefault(j, []).append((nseq, ns, top))
        for j in range(i+1, min(n, i+6)+1):
            if j in beam and len(beam[j]) > W:
                beam[j] = trimBeamBucket(beam[j])
        tail = buf[i:n]
        viable = tail in t9Prefixes if is9 else tail in sylPrefixes
        if viable and len(tail) <= 6:
            for seq, sc, last in [x for x in states if x[0]][:3]:
                finished.append((seq, tail, sc - 12))
        del beam[i]
        if len(finished) > 500:
            finished = sorted(finished, key=lambda x: -x[2])[:80]
    finished.sort(key=lambda x: -x[2])
    seen, byCount = set(), defaultdict(list)
    for f in finished:
        k = " ".join(f[0]) + "|" + f[1]
        if k in seen: continue
        seen.add(k); byCount[len(f[0])].append(f)
    uniq = []
    for c in sorted(byCount):
        # 每桶 6 个：同码音节（62=ma/na）同分时不能挤掉正确切分（与 Swift 一致）
        uniq += byCount[c][:6]
    return uniq[:24]

def trusted(w):
    """hot 精选词表专属（与 Swift isTrusted 一致）——93 万语料词不算 trusted。"""
    if w in wordFreq: return True
    return len(w) >= 3 and sum(charFreq.get(c, 0) for c in w) >= 3 * 170

def composeSentence(seq):
    n = len(seq)
    dp = [None] * (n + 1)
    dp[0] = (0.0, "", "", "")
    for i in range(n):
        if dp[i] is None: continue
        cur, text, last, lastw = dp[i]
        for l in range(1, min(6, n-i)+1):
            key = " ".join(seq[i:i+l])
            opts = []
            for idx, w in enumerate(words_for(key)[:6]):
                raw = sum(charFreq.get(c, 1) for c in w)
                f = wf(w) or 0
                # 四层刻度（与 Swift composeSentenceWithScore 严格一致）：
                #  A hot JSON 精选词：字频和/2 + 词频 + 120 + 250/字长加成
                #  B 启发式长词（3+字全常用字，如一按在/你你你）：只给弱加成，
                #    否则 rime 语料的长词凭 500 分长词加成压过「现在」
                #  C 语料词（93万 freq.bin）：词频主导 + 字频点缀
                #  D 生僻拼凑：字频和/4
                if w in wordFreq:
                    b = raw / 2.0 + f + 120
                    bonus = (l - 1) * 250
                elif trusted(w):
                    b = raw / 2.0 + f + 40
                    bonus = (l - 1) * 70
                elif f > 0:
                    b = f + raw / 10.0
                    bonus = (l - 1) * 18
                else:
                    b = raw / 4.0
                    bonus = (l - 1) * 18
                redu = 65 if (len(w) == 2 and w[0] == w[1]) else 0
                opts.append((w, b + bonus + redu - 25 - idx * 10))
            if l == 1:
                for idx, c in enumerate(charMap.get(seq[i], [])[:8]):
                    opts.append((c, charFreq.get(c,1)/4.0 - 25 - idx*6))
            for w, ws in opts:
                trans = bigramBonus(last, w[0]) if last else 0
                total = cur + ws + trans - (560 if w == lastw else 0)
                node = (total, text + w, w[-1], w)
                if dp[i+l] is None or total > dp[i+l][0]:
                    dp[i+l] = node
    return (dp[n][1], dp[n][0]) if dp[n] else ("", 0.0)

def fuzzyKeys(seq):
    if not seq or len(seq) > 3: return []
    sets = []
    for s in seq:
        v = [s]
        for a,b in fuzzyInit:
            if s.startswith(a) and b+s[len(a):] in valid: v.append(b+s[len(a):])
            if s.startswith(b) and a+s[len(b):] in valid: v.append(a+s[len(b):])
        for a,b in fuzzyFin:
            if s.endswith(a) and s[:-len(a)]+b in valid: v.append(s[:-len(a)]+b)
            if s.endswith(b) and s[:-len(b)]+a in valid: v.append(s[:-len(b)]+a)
        sets.append(v)
    combos = 1
    for s in sets:
        combos *= len(s)
        if combos > 24: return []
    keys = sets[0]
    for i in range(1, len(sets)):
        keys = [k + " " + o for k in keys for o in sets[i]]
    exact = " ".join(seq)
    return [k for k in keys if k != exact]

def t9TailLetters(digits):
    out = ""
    for i in range(len(digits)):
        pre, votes = digits[:i+1], defaultdict(int)
        for k, syls in t9Map.items():
            if not k.startswith(pre): continue
            for syl in syls:
                if len(syl) > i:
                    votes[syl[i]] += charFreq.get((charMap.get(syl) or [""])[0], 1)
        out += max(votes, key=votes.get) if votes else digitLetters.get(digits[i], digits[i])[0]
    return out

def t9SyllableOptions(buf):
    """左列音节候选：前缀（第一个未定位置），竞品标准。返回 [(音节, 位数)]"""
    n = len(buf)
    if n < 2: return []
    seen, scored = set(), []
    for l in range(min(6, n), 1, -1):
        for s in t9Map.get(buf[:l], []):
            if s in seen: continue
            seen.add(s)
            c = topChar(s)
            scored.append((s, (charFreq.get(c, 1) if c else 1) + l * 24, l))
    scored.sort(key=lambda x: -x[1])
    return [(s, l) for s, _, l in scored[:8]]

def prefixCandidates(buf, is9, fallback):
    out, seen = [], set()
    if is9:
        syls = [s for k,v in t9Map.items() if k.startswith(buf) for s in v]
    else:
        syls = [s for s in valid if s.startswith(buf)]
    for s in sorted(set(syls), key=lambda x: -sylScore(x))[:16]:
        c = (charMap.get(s) or [""])[0]
        if c and c not in seen:
            seen.add(c); out.append(c)
    if not is9: out.append(buf)
    if not out: out.append(fallback)
    return out[:16]

def decode(buf, is9, locked=()):
    buf = buf.lower()
    if not buf and not locked:
        return "", []
    lats = syllableLattices(buf, is9, 0)
    if is9 and not any(not lat[1] for lat in lats):
        l1 = syllableLattices(buf, True, 1)
        if any(not lat[1] for lat in l1): lats = l1
    if not is9 and not lats:
        l1 = syllableLattices(buf, False, 1)
        if l1:
            lats = l1
        else:
            l2 = syllableLattices(buf, False, 2)
            if l2: lats = l2
    if not lats:
        # 锁定兜底：剩余数字（含单键元音 a/e/o）补全成音节与锁定音节组词
        if locked:
            comps = []
            if buf:
                if is9:
                    # 补全音节消耗位数 == 已输入位数（与 Swift 一致）
                    if len(buf) >= 2: comps = list(t9Map.get(buf, []))
                    if buf == "2": comps.append("a")
                    if buf == "3": comps.append("e")
                    if buf == "6": comps.append("o")
                else:
                    comps = [s for s in valid if s.startswith(buf)]
            comps = sorted(set(comps), key=lambda s: -sylScore(s))
            scored = []
            for syl in comps[:6]:
                full = tuple(locked) + (syl,)
                t, sc = composeSentence(list(full))
                w = words_for(" ".join(full))
                scored.append((syl, sc + (200 if any(trusted(x) for x in (w or [])[:4]) else 0), t))
            scored.sort(key=lambda x: -x[1])
            disp = (locked and "'".join(locked) + "'" + scored[0][0]) if scored else "'".join(locked)
            out, seen = [], set()
            for _, _, t in scored:
                if t and t not in seen: seen.add(t); out.append(t)
            for w in words_for(" ".join(locked))[:6]:
                if w not in seen: seen.add(w); out.append(w)
            for syl in locked:
                for c in (charMap.get(syl) or [])[:4]:
                    if c not in seen: seen.add(c); out.append(c)
            return disp, (out[:20] if out else [disp])
        d = t9TailLetters(buf) if is9 else buf
        return d, prefixCandidates(buf, is9, d)
    ranked = []
    for lat in lats[:24]:
        full = tuple(locked) + lat[0]
        text, sc = composeSentence(list(full))
        key = " ".join(full)
        w = words_for(key)
        whole = 200 if any(trusted(x) for x in (w or [])[:4]) else 0
        complete = (300 if not lat[1] else -160) if is9 else (20 if not lat[1] else 0)
        # 每音节固定成本：碎片化切分（hua->hu+a 多出一个音节）整体出局，
        # 这就是 qingjian「音节少优先」原则，也是竞品整句连贯的排序根基
        length_cost = len(lat[0]) * (120 if is9 else 150)
        final = sc - length_cost + whole + complete + lat[2] * 0.05
        ranked.append(((full, lat[1], sc), text, final))
    ranked.sort(key=lambda x: -x[2])
    lats = [r[0] for r in ranked]
    sentences = [r[1] for r in ranked]
    best = lats[0]
    parts = list(best[0])
    if best[1] and len(parts) >= 2 and parts[-2] + parts[-1] in valid:
        parts = parts[:-2] + [parts[-2] + parts[-1]]
    if best[1]: parts.append(t9TailLetters(best[1]) if is9 else best[1])
    display = "'".join(parts)
    out, seen = [], set()
    def push(s):
        if s and s not in seen:
            seen.add(s); out.append(s)
    if best[1] and len(best[0]) >= 3:
        tail = best[1]
        cands = []
        if is9:
            cands = [s for k, v in t9Map.items() if k.startswith(tail) for s in v]
        else:
            cands = [s for s in valid if s.startswith(tail)]
        cands = sorted(set(cands), key=lambda s: -sylScore(s))[:3]
        seqs = []
        if len(best[0]) >= 2:
            merged = best[0][-2] + best[0][-1]
            if merged in valid:
                seqs.append(list(best[0][:-2]) + [merged])
        seqs.append(list(best[0]))
        for sq in seqs:
            for syl in cands:
                text, _ = composeSentence(sq + [syl])
                if text: push(text)
    bkey = " ".join(best[0])
    if sentences and trusted(sentences[0]):
        push(sentences[0])
    else:
        for x in (words_for(bkey) or [])[:4]:
            if trusted(x): push(x); break
    for s in sentences[:3]:
        push(s)
    if locked:
        for w in words_for(" ".join(locked))[:4]: push(w)
    for lat in lats[:3]:
        key = " ".join(lat[0])
        for w in words_for(key)[:8]: push(w)
        for k in fuzzyKeys(list(lat[0])):
            for w in words_for(k)[:4]: push(w)
    if len(best[0]) >= 2:
        for l in range(2, min(5, len(best[0]))+1):
            for w in words_for(" ".join(best[0][:l]))[:3]: push(w)
        if len(best[0]) - 1 >= 2:
            for l in range(2, min(4, len(best[0])-1)+1):
                push(composeSentence(list(best[0][:l]))[0])
    if not is9 and buf in english: push(buf)
    for lat in lats[:2]:
        picks = [lat[0][0], lat[0][-1]] if len(lat[0]) > 1 else list(lat[0])
        for syl in picks:
            for s2, _ in syllableCandidates(syl):
                for c in charMap.get(s2, [])[:10]: push(c)
    if not out: push(display)
    if not is9 and len(buf) <= 24: push(buf)
    return display, out[:24]

def assoc(t):
    out, seen = [], set()
    def push(s):
        if s and s != t and s not in seen:
            seen.add(s); out.append(s)
    for p in ["，","！","。","？"]: push(p)
    for l in range(min(4, len(t)), 0, -1):
        for w in assocNext.get(t[-l:], []): push(w)
    for p in ["～","、","吗","呢","吧","啊","呀","哦","嗯","哈","了","的"]: push(p)
    last = t[-1]
    for ch, _ in sorted(bigram.get(last, {}).items(), key=lambda x: -x[1])[:10]: push(ch)
    return out[:20]

# ==================================================================
PASS, FAIL = 0, 0
def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1
    else: FAIL += 1
    print("  %s %s%s" % ("[PASS]" if cond else "[FAIL]", name,
                         ("  -> " + detail) if detail and not cond else ""))

print("=" * 70)
print("一、93 万 mmap 词库关键词条（lexicon.bin 直查）")
for key, want in [("gui mi", "闺蜜"), ("xi an", "西安"), ("yu e", "余额"),
                  ("xian zai", "现在"), ("shu fu", "舒服"), ("duo le", "多了"),
                  ("ni hao", "你好"), ("zhong guo", "中国"),
                  ("tian qi", "天气"), ("mian shi", "面试")]:
    ws = words_for(key) or []
    check("%s → %s" % (key, want), want in ws, "词表: %s" % ws[:6])
# freq.bin：93 万词频压缩后必须带上这些词（trusted 排序的关键）
for w in ["闺蜜", "西安", "余额", "现在", "舒服"]:
    check("freq.bin 含 %s" % w, wf(w) is not None, "无词频")

print("=" * 70)
print("二、左列前缀音节（竞品「第一个未定位置」标准；a=2 键！）")
for digits, want in [("484", "gui"), ("94", "xi"), ("98", "yu"),
                     ("64", "mi"), ("9426", "xian"), ("26", "an")]:
    opts = [s for s, _ in t9SyllableOptions(digits)]
    check("左列 %s 含 %s" % (digits, want), want in opts, "实际: %s" % opts[:6])

print("=" * 70)
print("三、音节锁定连贯组词（竞品核心交互；an=26、e=3）")
d, c = decode("48464", True)
check("48464 → 闺蜜(直接)", c and c[0] == "闺蜜", "首位: %s" % (c[:4] if c else []))
d, c = decode("64", True, locked=("gui",))
check("锁gui+64 → 闺蜜", c and c[0] == "闺蜜", "首位: %s / 串: %s" % (c[:4] if c else [], d))
d, c = decode("26", True, locked=("xi",))
check("锁xi+26 → 西安", c and c[0] == "西安", "首位: %s / 串: %s" % (c[:4] if c else [], d))
d, c = decode("3", True, locked=("yu",))
check("锁yu+3 → 余额", c and c[0] == "余额", "首位: %s / 串: %s" % (c[:4] if c else [], d))
d, c = decode("", True, locked=("gui",))
check("锁gui空缓冲 → 归/规类字词", bool(c), "候选: %s" % (c[:5] if c else []))

print("=" * 70)
print("四、逐键节奏测试（模拟真实打字：每键刷新，最终出词）")
RHYTHM = [
    ("94269247483838653", "现在舒服多了"),
    ("64426", "你好"), ("94664486", "中国"), ("744543", "世界"),
    ("5468426", "今天"), ("48464", "闺蜜"), ("64646464", "明明"),
]
for digits, want in RHYTHM:
    buf = ""
    first = ""
    t0 = time.perf_counter()
    for ch in digits:
        buf += ch
        d, c = decode(buf, True)
        if c: first = c[0]
    dt = (time.perf_counter() - t0) * 1000
    check("9键 %s → %s" % (digits, want), first == want,
          "实际首位: %s (串 %s)" % (first, d))
    print("      逐键 %d 键总耗时 %.1f ms" % (len(digits), dt))

print("=" * 70)
print("五、搜狗对比用例（2026-11-14 用户截图实测：竞品输出 vs 我们）")
# 用户实测：搜狗 na'xian'zai → 那现在；qing'li'bu'diao → 清理不掉
for buf, want in [("629426924", "那现在"), ("746454283426", "清理不掉")]:
    d, c = decode(buf, True)
    check("9键 %s → %s（搜狗同款）" % (buf, want), c and c[0] == want,
          "首位: %s / 串: %s" % (c[:4] if c else [], d))

print("=" * 70)
print("六、26 键回归")
for buf, want in [("niganjinwoqumians", "你赶紧我去面试"),
                  ("woxiangdadianhua", "我想打电话"),
                  ("nihao", "你好")]:
    d, c = decode(buf, False)
    check("26键 %s → %s" % (buf, want), c and c[0] == want,
          "首位: %s / 串: %s" % (c[:4] if c else [], d))

print("=" * 70)
print("七、显示回归（拼音串非数字串 / 锁定段在串首）")
d, c = decode("64426", True)
check("64426 显示 ni'hao", d == "ni'hao", d)
d, c = decode("64", True, locked=("gui",))
check("锁gui+64 显示 gui'mi", d == "gui'mi", d)
d, c = decode("26", True, locked=("xi",))
check("锁xi+26 显示 xi'an", d == "xi'an", d)
d, c = decode("3", True, locked=("yu",))
check("锁yu+3 显示 yu'e", d == "yu'e", d)

print("=" * 70)
for ctx in ["你好", "今天", "我"]:
    print("联想「%s」-> %s" % (ctx, assoc(ctx)[:12]))

print("=" * 70)
print("结果: %d PASS / %d FAIL" % (PASS, FAIL))
