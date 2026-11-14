# -*- coding: utf-8 -*-
"""用 Python 忠实复刻 Swift 引擎的解码链路，本地验证效果与耗时。
云端打包前先跑这个，避免把错算法编译进 IPA。
"""
import json, os, math, time
from collections import defaultdict

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Keyboard")
def load(name):
    with open(os.path.join(OUT, name), encoding="utf-8") as f:
        return json.load(f)

charMap = load("pinyin_chars.json")
phraseMap = load("pinyin_phrases.json")
assocNext = load("pinyin_assoc.json")
charFreq = load("pinyin_char_freq.json")
wordFreq = load("pinyin_hot_words.json")
bigram = load("pinyin_bigram.json")
t9Map = load("pinyin_t9.json")
english = set(load("pinyin_english.json"))

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
    return min(26, bigram.get(a, {}).get(b, 0) * 2.5)

def approxWordFreq(w):
    if w in wordFreq: return wordFreq[w]
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
    # level 1：只开模糊音；level 2：再开 1 次编辑纠错
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
        if key in phraseMap:
            w = phraseMap[key][0]
            s += 130 if w in wordFreq else 35
    return s

def trimBeamBucket(arr, per=2):
    """按「已切出的音节数」分桶保留：保证 zhong(1音节) 不会被 yin+ni(2音节) 挤掉。
    贪心 top-K 会系统性地偏爱碎切分，这是之前 9 键「中国」被切成「印尼故哦」的根因。"""
    buckets = defaultdict(list)
    for node in arr:
        buckets[len(node[0])].append(node)
    out = []
    for c in sorted(buckets):
        out += sorted(buckets[c], key=lambda x: -x[1])[:per]
    return out

def syllableLattices(buf, is9, level=0):
    n, W = len(buf), 6
    beam = {0: [((), 0.0, "")]}
    finished = []
    for i in range(n):
        states = beam.get(i)
        if not states: continue
        for seq, sc, last in states:
            for l in range(1, min(6, n - i) + 1):
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
                    # 每个音节有固定成本，抑制「切得越碎分越高」；词组命中给强加分
                    ns = (sc + sylScore(syl) - 14 + bigramBonus(last, top)
                          - pen * 12 + latticeBonus(list(nseq)) * 2)
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
        uniq += byCount[c][:3]
    return uniq[:18]

def trusted(w):
    """是否可信日常词：有真实词频，或长词且用字都很常用（如「打电话」）。"""
    if w in wordFreq: return True
    return len(w) >= 3 and sum(charFreq.get(c, 0) for c in w) >= 3 * 170

def composeSentence(seq):
    n = len(seq)
    dp = [None] * (n + 1)
    dp[0] = (0.0, "", "")
    for i in range(n):
        if dp[i] is None: continue
        cur, text, last = dp[i]
        for l in range(1, min(6, n-i)+1):
            key = " ".join(seq[i:i+l])
            opts = []
            for idx, w in enumerate(phraseMap.get(key, [])[:4]):
                # 可信高频词享受长词加成；冷僻词不给，避免「曲面」压过「去+面」
                hot = trusted(w)
                base = sum(charFreq.get(c, 1) for c in w) / 2.0
                bonus = (l-1) * (70 if hot else 18)
                opts.append((w, (base if hot else base * 0.5) + bonus
                             + (120 if hot else 0) - 25 - idx*10))
            if l == 1:
                for idx, c in enumerate(charMap.get(seq[i], [])[:4]):
                    # 单字降权：碎片切分不该靠数量堆分
                    opts.append((c, charFreq.get(c,1)/4.0 - 25 - idx*6))
            for w, ws in opts:
                trans = bigramBonus(last, w[0]) if last else 0
                total = cur + ws + trans
                node = (total, text + w, w[-1])
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

def decode(buf, is9):
    buf = buf.lower()
    # 精确切分优先；只有精确无解时才逐级放宽到模糊音、1 次编辑纠错
    lats = syllableLattices(buf, is9, 0)
    # 尾部半截音节（...mian's）是正常输入状态，不算失败；只有完全切不出才升级纠错
    if not is9 and not lats:
        l1 = syllableLattices(buf, is9, 1)
        if l1:
            lats = l1
        else:
            l2 = syllableLattices(buf, is9, 2)
            if l2: lats = l2
    if not lats:
        d = "".join(digitLetters.get(c,c)[0] for c in buf) if is9 else buf
        return d, prefixCandidates(buf, is9, d)
    # 关键：音节格的贪心分不作为最终排序，改由词格 viterbi 的整句分数决定
    ranked = []
    for lat in lats[:18]:
        text, sc = composeSentence(list(lat[0]))
        key = " ".join(lat[0])
        ps = phraseMap.get(key)
        whole = 200 if ps and ps[0] in wordFreq else 0
        final = sc - len(lat[0]) * 12 + whole + (20 if not lat[1] else 0) + lat[2] * 0.05
        ranked.append((lat, text, final))
    ranked.sort(key=lambda x: -x[2])
    lats = [r[0] for r in ranked]
    sentences = [r[1] for r in ranked]
    best = lats[0]
    parts = list(best[0])
    # mi'an -> mian：显示层把被误拆的长音节合回来，贴近搜狗的 mian's
    if best[1] and len(parts) >= 2 and parts[-2] + parts[-1] in valid:
        parts = parts[:-2] + [parts[-2] + parts[-1]]
    if best[1]: parts.append(t9TailLetters(best[1]) if is9 else best[1])
    display = "'".join(parts)
    out, seen = [], set()
    def push(s):
        if s and s not in seen:
            seen.add(s); out.append(s)
    # 尾部半截音节补全 + 音节重切：搜狗在 ni'gan'jin'wo'qu'mian's 时
    # 会直接给出「你赶紧我去面试」，而不是让用户再补一个键。
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
                seqs.append(list(best[0][:-2]) + [merged])   # 合并版优先，更可能是正确长句
        seqs.append(list(best[0]))
        for sq in seqs:
            for syl in cands:
                text, _ = composeSentence(sq + [syl])
                if text: push(text)
    # 整串恰好是一个可信高频词时无条件置顶（你好 / 中国 / 世界 / 今天）
    bkey = " ".join(best[0])
    if phraseMap.get(bkey) and trusted(phraseMap[bkey][0]):
        push(phraseMap[bkey][0])
    for s in sentences[:3]:
        push(s)
    for lat in lats[:3]:
        key = " ".join(lat[0])
        for w in phraseMap.get(key, [])[:8]: push(w)
        for k in fuzzyKeys(list(lat[0])):
            for w in phraseMap.get(k, [])[:4]: push(w)
    if len(best[0]) >= 2:
        for l in range(2, min(5, len(best[0]))+1):
            for w in phraseMap.get(" ".join(best[0][:l]), [])[:3]: push(w)
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
    # 词级搭配紧跟标点，别让一整排语气词把「吗 / 天气 / 想」挤到后面
    for l in range(min(4, len(t)), 0, -1):
        for w in assocNext.get(t[-l:], []): push(w)
    for p in ["～","、","吗","呢","吧","啊","呀","哦","嗯","哈","了","的"]: push(p)
    last = t[-1]
    for ch, _ in sorted(bigram.get(last, {}).items(), key=lambda x: -x[1])[:10]: push(ch)
    return out[:20]

print("=" * 70)
CASES = [
    ("26", "niganjinwoqumians", "长句(搜狗图3)"),
    ("26", "nihao", "常用词"),
    ("26", "woxiangdadianhua", "长句2"),
    ("26", "zhongguo", "常用词"),
    ("26", "nihaoa", "多打一个字母"),
    ("26", "niha", "少打一个字母"),
    ("26", "niganjin", "连续词"),
    ("9",  "64426", "9键你好"),
    ("9",  "94664486", "9键中国"),
    ("9",  "744543", "9键世界"),
    ("9",  "5468426", "9键今天"),
    ("9",  "644265469678642678", "9键长串(图2)"),
]
for mode, buf, name in CASES:
    t0 = time.perf_counter()
    d, c = decode(buf, mode == "9")
    dt = (time.perf_counter() - t0) * 1000
    print(f"[{name}] {mode}键 {buf}")
    print(f"   拼音串: {d}")
    print(f"   候选  : {c[:8]}")
    print(f"   耗时  : {dt:.1f} ms")
print("=" * 70)
for ctx in ["你好", "今天", "我", "中国", "面试", "你赶紧我去面试"]:
    print(f"联想「{ctx}」-> {assoc(ctx)[:14]}")

# 逐键性能：模拟用户连续敲 18 个键
buf = ""
t0 = time.perf_counter()
for ch in "niganjinwoqumians":
    buf += ch
    decode(buf, False)
print("=" * 70)
print("26键逐键 18 次解码总耗时: %.1f ms (平均 %.1f ms/键)" % (
    (time.perf_counter()-t0)*1000, (time.perf_counter()-t0)*1000/18))
buf = ""
t0 = time.perf_counter()
for ch in "644265469678642678":
    buf += ch
    decode(buf, True)
print("9键逐键 18 次解码总耗时: %.1f ms (平均 %.1f ms/键)" % (
    (time.perf_counter()-t0)*1000, (time.perf_counter()-t0)*1000/18))
