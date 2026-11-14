# -*- coding: utf-8 -*-
"""增强版词库生成（内存安全版）。

旧版把 phrase_raw 全量 4 万多条短语 + 近 4 万条联想全部打进包，
解析成 Swift 嵌套字典后内存远超 iOS 键盘扩展 ~30MB 上限，
导致扩展进程被系统杀死（现象：切到拼音「弹一下就没了」）。

本版策略（对齐旧引擎「极致轻量化」原则）：
- 单字表：每个音节只保留词频最高的前 40 个汉字（覆盖日常即可）。
- 短语表：优先保留短词（2/3 字最常用），键总数压到 MAX_PHRASE_KEYS。
- 联想表：只保留高频前缀上下文，每上下文封顶。
- bigram：每上下文后继封顶。
- 不再生成 pinyin_phrase_freq.json（引擎并未使用，纯浪费）。
- 额外合并一个小型「分类/常用」词库，覆盖短视频/电商/IT/生活等高频词。
"""
import json, os
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
OUT = os.path.join(HERE, "Keyboard")

# 旧引擎自带的「真实语料词频」词库（借鉴对象，仅取数据，不取界面/排版）：
#   entries: [[词, 拼音, 词频], ...]，含 12,850 条多字短语与全部常用单字。
# 用它取代「字出现在多少短语里」这一失真信号，让『你好』压过『内行』、『谢谢』压过『泄泻』。
OLD_DICT = r"E:\紧急通知\输入法引擎\README.md等5个文件\dict.json"

# 内存预算上限（解析后 Swift 字典远小于此即安全）：包内 JSON 合计 < 2MB
MAX_PHRASE_KEYS = 20000      # 短语键总数上限
PHRASE_PER_KEY = 10          # 同一拼音下候选短语数上限
MAX_ASSOC = 4000             # 联想上下文总数上限
ASSOC_PER_CTX = 10           # 每联想上下文短语数上限
BIGRAM_PER_CTX = 30          # 每字后继数上限
BIGRAM_TOP_CTX = 2000        # bigram 仅保留最高频字上下文（省内存）
CHARS_PER_SYL = 40           # 每音节单字数上限

TONE = {
    'ā':'a','á':'a','ǎ':'a','à':'a','ē':'e','é':'e','ě':'e','è':'e',
    'ī':'i','í':'i','ǐ':'i','ì':'i','ō':'o','ó':'o','ǒ':'o','ò':'o',
    'ū':'u','ú':'u','ǔ':'u','ù':'u','ǖ':'v','ǘ':'v','ǚ':'v','ǜ':'v','ü':'v',
    'ń':'n','ň':'n','ǹ':'n','ḿ':'m',
}
def toneless(s):
    return ''.join(TONE.get(c, c) for c in s).lower()

chars_map = {}
phrase_map = {}
assoc_map = {}
char_bigram = {}
phrase_order = []   # 记录短语键出现顺序，便于按「短词优先」裁剪

# ---- 单字拼音表 ----
with open(os.path.join(ASSETS, "pinyin_raw.txt"), encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        if "#" in line:
            code_part, char_part = line.split("#", 1)
        else:
            code_part, char_part = line, ""
        if ":" not in code_part:
            continue
        _, pinyin_part = code_part.split(":", 1)
        pinyin = pinyin_part.split(",")[0].strip()
        ch = char_part.strip()
        if not ch:
            continue
        syl = toneless(pinyin)
        if not syl or not syl.isalpha():
            continue
        chars_map.setdefault(syl, [])
        if ch not in chars_map[syl]:
            chars_map[syl].append(ch)

# ---- 词组 + 联想 + bigram ----
with open(os.path.join(ASSETS, "phrase_raw.txt"), encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        phrase, pinyin = line.split(":", 1)
        phrase = phrase.strip()
        pinyin = pinyin.split("#")[0].strip()
        syllables = pinyin.split()
        if not phrase or not syllables:
            continue
        if len(phrase) > 6:
            continue
        if not all('\u4e00' <= c <= '\u9fff' for c in phrase):
            continue
        key = " ".join(toneless(s) for s in syllables)
        if not key or not key.replace(" ", "").isalpha():
            continue
        if key not in phrase_map:
            phrase_map[key] = []
            phrase_order.append(key)
        lst = phrase_map[key]
        if len(lst) < PHRASE_PER_KEY and phrase not in lst:
            lst.append(phrase)
        # 联想：首字/前两字开头
        for pre in (phrase[0], phrase[:2]):
            if len(pre) < 1:
                continue
            al = assoc_map.setdefault(pre, [])
            if len(al) < ASSOC_PER_CTX and phrase not in al:
                al.append(phrase)
        # 字符 bigram
        for i in range(len(phrase) - 1):
            a, b = phrase[i], phrase[i+1]
            char_bigram.setdefault(a, Counter())[b] += 1

# ---- 小型分类/常用词库（借鉴旧引擎 domain_dict 思路）----
DOMAIN = {
    # 生活/社交
    "你好":"ni hao", "谢谢":"xie xie", "对不起":"dui bu qi", "没关系":"mei guan xi",
    "不好意思":"bu hao yi si", "麻烦您":"ma fan nin", "辛苦了":"xin ku le",
    # 短视频/电商
    "直播间":"zhi bo jian", "主播":"zhu bo", "上链接":"shang lian jie", "秒杀":"miao sha",
    "优惠券":"you hui quan", "下单":"xia dan", "发货":"fa huo", "物流":"wu liu",
    "好评":"hao ping", "差评":"cha ping", "退款":"tui kuan", "客服":"ke fu",
    "粉丝":"fen si", "关注":"guan zhu", "点赞":"dian zan", "评论":"ping lun",
    "收藏":"shou cang", "分享":"fen xiang", "私信":"si xin", "弹幕":"dan mu",
    # IT/办公
    "代码":"dai ma", "程序":"cheng xu", "服务器":"fu wu qi", "数据库":"shu ju ku",
    "接口":"jie kou", "前端":"qian duan", "后端":"hou duan", "算法":"suan fa",
    "需求":"xu qiu", "方案":"fang an", "会议":"hui yi", "周报":"zhou bao",
    "文档":"wen dang", "表格":"biao ge", "演示":"yan shi", "进度":"jin du",
    # 通用长词（简拼/整词命中）
    "中华人民共和国":"zhong hua ren min gong he guo",
    "中国特色社会主义":"zhong guo te se she hui zhu yi",
    "人工智能":"ren gong zhi neng", "机器学习":"ji qi xue xi",
    "深度学习":"shen du xue xi", "大数据":"da shu ju", "区块链":"qu kuai lian",
    "元宇宙":"yuan yu zhou", "碳中和":"tan zhong he", "乡村振兴":"xiang cun zhen xing",
}
for ph, py in DOMAIN.items():
    key = py
    if key not in phrase_map:
        phrase_map[key] = []
        phrase_order.append(key)
    if ph not in phrase_map[key]:
        phrase_map[key].insert(0, ph)

# ---- 加载旧引擎「真实语料词频」 ----
real_freq = {}
old_multis = []          # [(词, "shi jie", 词频)]
try:
    with open(OLD_DICT, encoding="utf-8") as f:
        _d = json.load(f)
    for _w, _py, _f in _d.get("entries", []):
        real_freq[_w] = max(real_freq.get(_w, 0), int(_f))
        if len(_w) > 1:
            old_multis.append((_w, _py, int(_f)))
    print("已加载旧引擎真实词频：%d 条（单字 %d / 多字 %d）" % (
        len(real_freq),
        sum(1 for w in real_freq if len(w) == 1),
        len(old_multis)))
except Exception as e:
    print("警告：旧引擎词库读取失败，回退到出现次数：%s" % e)

# 把旧引擎的多字高频日常词并入短语库。
# phrase_raw.txt 是成语/词组库，缺「世界/今天/时候/自己」这类最常用的词；
# 旧引擎 dict.json 恰好有 1.2 万条带真实词频的日常词，正好补齐。
old_multi_keys = set()
for w, py, f in old_multis:
    key = toneless(py.replace("'", "")).strip()
    if not key or not key.replace(" ", "").isalpha() or len(key.split()) > 6:
        continue
    if key not in phrase_map:
        phrase_map[key] = []
        phrase_order.append(key)
    old_multi_keys.add(key)
    lst = phrase_map[key]
    if w not in lst:
        lst.insert(0, w)      # 高频日常词置顶，压过成语库里的冷僻同音词
    if len(lst) > 16:
        del lst[16:]

# ---- 单字频率信号（供运行时 score() 使用）----
raw_count = Counter()
for ph_list in phrase_map.values():
    for w in ph_list:
        for ch in w:
            if '\u4e00' <= ch <= '\u9fff':
                raw_count[ch] += 1
# 注意：不要遍历裁剪前的 chars_map —— pinyin_raw.txt 含 4 万多个 CJK 扩展区生僻字，
# 会把词频表撑到 44440 条（Swift 字典 ~4MB）。只统计实际会用到的短语用字即可；
# sort_chars 里 freq_chars.get(c, 0) 对未收录字自然兜底排后，不影响正确性。
freq_chars = Counter()
for ch, cnt in raw_count.items():
    freq_chars[ch] = real_freq.get(ch, min(80, cnt // 4))

# 独立的小文件：只存「可信高频日常词」集合，供运行时整句合成判定，
# 避免把冷僻同音词拼进长句（我+癌肿+过 → 我+爱+中国）。
# 单独存放可让 char_freq 保持精简（不塞 5 万条词进 Swift 字典）。
hot_words = sorted({w for w, py, f in old_multis if f >= 150 and 2 <= len(w) <= 6})

# ---- 短语裁剪：真实高频日常词优先，其次短词，键总数压到上限 ----
phrase_order_uniq = []
seen = set()
for k in phrase_order:
    if k not in seen:
        seen.add(k); phrase_order_uniq.append(k)
order_index = {k: i for i, k in enumerate(phrase_order_uniq)}

def key_weight(k):
    return max((real_freq.get(w, 0) for w in phrase_map.get(k, [])), default=0)

phrase_order_uniq.sort(key=lambda k: (-min(key_weight(k), 300) // 10, len(k.split()), order_index[k]))
kept = set(phrase_order_uniq[:MAX_PHRASE_KEYS])
# 保护：分类词库 + 旧引擎真实高频日常词（f >= 200，约 6000 条）不被裁剪
kept.update(DOMAIN.values())
kept.update(k for k in old_multi_keys if key_weight(k) >= 200)
trimmed_phrase = {k: v for k, v in phrase_map.items() if k in kept}

# 短语级真实词频离线预排序（运行时 score() 排序的双保险）
trimmed_phrase = {
    k: sorted(v, key=lambda w: -real_freq.get(w, 0))
    for k, v in trimmed_phrase.items()
}

override = {
 "ni":["你","尼","泥","逆"], "ta":["他","她","它","塌","塔"],
 "de":["的","得","德"], "shi":["是","时","事","石","食","世","市","示","式","势"],
 "le":["了","乐"], "ma":["吗","嘛","马","麻","码","骂"], "me":["么"],
 "ne":["呢"], "ba":["吧","八","把","巴"], "a":["啊","阿"], "la":["啦","拉"],
 "ya":["呀","牙"], "ou":["偶","欧","呕"], "zen":["怎"], "shen":["什","神","身","深"],
 "shui":["谁"], "na":["哪","那","纳"], "jiu":["就","九","久","酒"],
 "ye":["也","夜","业","页"], "dou":["都","斗","豆"], "hen":["很","狠","恨"],
 "geng":["更"], "zui":["最"], "qing":["请","青","清","轻"], "xie":["谢","些","写","鞋"],
 "dui":["对","队","堆"], "cuo":["错","措"], "zhe":["这","着","者"], "nao":["脑","闹"],
 "lai":["来","赖"], "qu":["去","区","趣"], "kan":["看","砍"], "shuo":["说","硕"],
 "xiang":["想","像","向","响"], "zhi":["只","知","之","指","纸","志"],
 "dao":["到","道","倒"], "zai":["在","再","载"], "you":["有","又","右","友","由","油","游"],
 "mei":["没","美","每"], "ren":["人","任","认","仁"], "gei":["给"], "rang":["让"],
 "jiao":["叫","教","脚"], "zuo":["做","作","坐"], "ting":["听","庭"],
 "jian":["见","件","建","间"], "chi":["吃","迟","池"], "he":["和","喝","何","河"],
 "hai":["还","孩","海"], "te":["特"], "bie":["别"], "wo":["我","卧","窝","握"],
 "yi":["一","以","意","衣","义","已","因","应"], "bu":["不","步","布","部","补"],
 "ge":["个","各","哥","歌"], "men":["们","门","闷"], "yao":["要","邀","腰","摇"],
}
def sort_chars(syl, lst):
    seen=set(); uniq=[]
    for c in lst:
        if c not in seen: seen.add(c); uniq.append(c)
    ov = [c for c in override.get(syl, []) if c in seen]
    rest = [c for c in uniq if c not in set(ov)]
    rest.sort(key=lambda c: -freq_chars.get(c, 0))
    return (ov + rest)[:CHARS_PER_SYL]

new_chars = {syl: sort_chars(syl, lst) for syl, lst in chars_map.items()}

# ---- 联想裁剪：只保留高频前缀上下文 ----
assoc_freq = sorted(assoc_map.keys(), key=lambda p: -freq_chars.get(p[0] if p else "", 0))
kept_assoc = set(assoc_freq[:MAX_ASSOC])
trimmed_assoc = {k: v[:ASSOC_PER_CTX] for k, v in assoc_map.items() if k in kept_assoc}

# ---- bigram 裁剪（仅按「单字」的高频上下文，避免被多字词频挤出） ----
top_ctx = [c for c, _ in freq_chars.most_common() if len(c) == 1][:BIGRAM_TOP_CTX]
bigram_out = {}
for a in top_ctx:
    cnt = char_bigram.get(a)
    if not cnt: continue
    items = cnt.most_common(BIGRAM_PER_CTX)
    bigram_out[a] = {b: c for b, c in items}

os.makedirs(OUT, exist_ok=True)
json.dump(new_chars, open(os.path.join(OUT, "pinyin_chars.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))
json.dump(trimmed_phrase, open(os.path.join(OUT, "pinyin_phrases.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))
json.dump(trimmed_assoc, open(os.path.join(OUT, "pinyin_assoc.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))
json.dump(bigram_out, open(os.path.join(OUT, "pinyin_bigram.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))
json.dump(dict(freq_chars), open(os.path.join(OUT, "pinyin_char_freq.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))
json.dump(hot_words, open(os.path.join(OUT, "pinyin_hot_words.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))

# 报告包内体量
import os as _os
def sz(fn):
    p = os.path.join(OUT, fn)
    return _os.path.getsize(p) if _os.path.exists(p) else 0
total = sum(sz(f) for f in ["pinyin_chars.json","pinyin_phrases.json","pinyin_assoc.json","pinyin_bigram.json","pinyin_char_freq.json","pinyin_hot_words.json","cat_net.json"])
print("=== 生成完成 ===")
print("chars syllables:", len(new_chars))
print("phrase keys:", len(trimmed_phrase), " (上限", MAX_PHRASE_KEYS, ")")
print("assoc keys:", len(trimmed_assoc), " (上限", MAX_ASSOC, ")")
print("bigram entries:", len(bigram_out))
print("包内 JSON 合计: %.2f MB" % (total/1024/1024))
print("单字总条数:", sum(len(v) for v in new_chars.values()))
print("短语总条数:", sum(len(v) for v in trimmed_phrase.values()))
for k in ["ni hao","wo men","zhong guo","xie xie","hao","ni","zhong hua ren min gong he guo"]:
    print("  校验 '%s' ->" % k, trimmed_phrase.get(k, "缺失"))
