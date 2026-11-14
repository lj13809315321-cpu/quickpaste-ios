# -*- coding: utf-8 -*-
"""增强版词库生成（内存安全版 / 联想与整句解码专用）。

相对上一版的关键改动：
- 联想表 pinyin_assoc.json 语义改为「上屏词 -> 后续词」。
  旧版存的是「以某字开头的短语」，所以打完「你好」会冒出「好事之徒/好事多悭」。
  数据来源改为旧引擎 dict.json 里自带的 930 条词级搭配（你好→吗、今天→天气、我→想），
  再叠加手工高频搭配、短语派生后缀，并用真实词频过滤冷僻成语。
- pinyin_hot_words.json 由 [词] 改成 {词: 真实词频}，供整句 viterbi 打分，不新增文件。
- 新增 pinyin_t9.json：数字串 -> 音节列表（离线预计算，运行时不再做 3^N 字母展开）。
- 新增 pinyin_english.json：常用英文词，26 键中英混输判断用。

内存预算：包内 JSON 合计控制在 ~1.5MB，Swift 解析后远低于键盘扩展 ~30MB 上限。
"""
import json, os
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
OUT = os.path.join(HERE, "Keyboard")

# 旧引擎自带的「真实语料词频 + 词级搭配 + 常用英文」词库（仅取数据）：
OLD_DICT = r"E:\紧急通知\输入法引擎\README.md等5个文件\dict.json"

MAX_PHRASE_KEYS = 20000
PHRASE_PER_KEY = 10
BIGRAM_PER_CTX = 10
BIGRAM_TOP_CTX = 2000
CHARS_PER_SYL = 40
ASSOC_PER_CTX = 16
T9_PER_KEY = 14

TONE = {
    'ā':'a','á':'a','ǎ':'a','à':'a','ē':'e','é':'e','ě':'e','è':'e',
    'ī':'i','í':'i','ǐ':'i','ì':'i','ō':'o','ó':'o','ǒ':'o','ò':'o',
    'ū':'u','ú':'u','ǔ':'u','ù':'u','ǖ':'v','ǘ':'v','ǚ':'v','ǜ':'v','ü':'v',
    'ń':'n','ň':'n','ǹ':'n','ḿ':'m',
}
def toneless(s):
    return ''.join(TONE.get(c, c) for c in s).lower()

# 9 键字母 -> 数字
LETTER_DIGIT = {}
for _d, _ls in [('2','abc'),('3','def'),('4','ghi'),('5','jkl'),
                ('6','mno'),('7','pqrs'),('8','tuv'),('9','wxyz')]:
    for _c in _ls:
        LETTER_DIGIT[_c] = _d

chars_map = {}
phrase_map = {}
char_bigram = {}
phrase_order = []

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

# ---- 词组 + 字符 bigram ----
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
        if not phrase or not syllables or len(phrase) > 6:
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
        for i in range(len(phrase) - 1):
            char_bigram.setdefault(phrase[i], Counter())[phrase[i+1]] += 1

# ---- 小型分类/常用词库 ----
DOMAIN = {
    "你好":"ni hao", "谢谢":"xie xie", "对不起":"dui bu qi", "没关系":"mei guan xi",
    "不好意思":"bu hao yi si", "麻烦您":"ma fan nin", "辛苦了":"xin ku le",
    "直播间":"zhi bo jian", "主播":"zhu bo", "上链接":"shang lian jie", "秒杀":"miao sha",
    "优惠券":"you hui quan", "下单":"xia dan", "发货":"fa huo", "物流":"wu liu",
    "好评":"hao ping", "差评":"cha ping", "退款":"tui kuan", "客服":"ke fu",
    "粉丝":"fen si", "关注":"guan zhu", "点赞":"dian zan", "评论":"ping lun",
    "收藏":"shou cang", "分享":"fen xiang", "私信":"si xin", "弹幕":"dan mu",
    "代码":"dai ma", "程序":"cheng xu", "服务器":"fu wu qi", "数据库":"shu ju ku",
    "接口":"jie kou", "前端":"qian duan", "后端":"hou duan", "算法":"suan fa",
    "需求":"xu qiu", "方案":"fang an", "会议":"hui yi", "周报":"zhou bao",
    "文档":"wen dang", "表格":"biao ge", "演示":"yan shi", "进度":"jin du",
    "中华人民共和国":"zhong hua ren min gong he guo",
    "中国特色社会主义":"zhong guo te se she hui zhu yi",
    "人工智能":"ren gong zhi neng", "机器学习":"ji qi xue xi",
    "深度学习":"shen du xue xi", "大数据":"da shu ju", "区块链":"qu kuai lian",
    "元宇宙":"yuan yu zhou", "碳中和":"tan zhong he", "乡村振兴":"xiang cun zhen xing",
}
for ph, py in DOMAIN.items():
    if py not in phrase_map:
        phrase_map[py] = []
        phrase_order.append(py)
    if ph not in phrase_map[py]:
        phrase_map[py].insert(0, ph)

# ---- 加载旧引擎真实语料数据 ----
real_freq = {}
old_multis = []
word_bigrams = []       # [[前词, 后词, 频次], ...]
english_words = []
std_syllables = []
try:
    with open(OLD_DICT, encoding="utf-8") as f:
        _d = json.load(f)
    for _w, _py, _f in _d.get("entries", []):
        real_freq[_w] = max(real_freq.get(_w, 0), int(_f))
        if len(_w) > 1:
            old_multis.append((_w, _py, int(_f)))
    word_bigrams = _d.get("bigrams", [])
    english_words = _d.get("english", [])
    std_syllables = _d.get("syllables", [])
    print("已加载旧引擎：词频 %d 条 / 词级搭配 %d 条 / 英文 %d / 标准音节 %d" % (
        len(real_freq), len(word_bigrams), len(english_words), len(std_syllables)))
except Exception as e:
    print("警告：旧引擎词库读取失败：%s" % e)

# 把旧引擎多字高频日常词并入短语库
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
        lst.insert(0, w)
    if len(lst) > 16:
        del lst[16:]

# ---- 单字频率信号 ----
raw_count = Counter()
for ph_list in phrase_map.values():
    for w in ph_list:
        for ch in w:
            if '\u4e00' <= ch <= '\u9fff':
                raw_count[ch] += 1
freq_chars = Counter()
for ch, cnt in raw_count.items():
    freq_chars[ch] = real_freq.get(ch, min(80, cnt // 4))

# 可信高频日常词：{词: 真实词频}，整句 viterbi 与联想过滤都用它
hot_words = {w: f for w, py, f in old_multis if f >= 150 and 2 <= len(w) <= 6}
hot_set = set(hot_words)

# ---- 短语裁剪 ----
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
kept.update(DOMAIN.values())
kept.update(k for k in old_multi_keys if key_weight(k) >= 200)
trimmed_phrase = {k: v for k, v in phrase_map.items() if k in kept}
trimmed_phrase = {k: sorted(v, key=lambda w: -real_freq.get(w, 0)) for k, v in trimmed_phrase.items()}

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

# ---- 联想表：上屏词 -> 后续词（搜狗式语境联想） ----
# 结构：key -> {后词: 权重}，权重越大越靠前。手工表权重最高。
assoc_next = defaultdict(dict)

# 1) 手工高频搭配：覆盖问候、句首、时间、语气、办公等最常接续的场景
MANUAL = {
 "你好": ["，","！","吗","呀","啊","世界","在吗","哦","～","。","？","您好","呀"],
 "您好": ["，","！","请","麻烦","我","请问","。"],
 "谢谢": ["你","！","啦","，","大家","老板","您","。","～"],
 "不客气": ["，","～","哈","应该的"],
 "对不起": ["，","我","。","实在","不是"],
 "我": ["想","要","们","在","也","就","不","的","今天","明天","去","来","觉得","知道","可以","没有","已经","现在","刚","把","给","跟","和","是"],
 "你": ["好","们","在","要","说","看","知道","觉得","可以","是不是","的","怎么","去","来","有没有","今天","明天","先","别","能"],
 "他": ["们","在","说","是","的","要","也","已经","不"],
 "她": ["们","在","说","是","的","要","也","已经","不"],
 "我们": ["的","在","要","可以","一起","现在","先","都","就","明天","今天","去","来","把","还是"],
 "你们": ["的","在","要","可以","都","先","怎么","是不是"],
 "今天": ["天气","晚上","上午","下午","是","的","要","去","有","我","就","真","好","不","已经","几点"],
 "明天": ["上午","下午","晚上","见","去","要","有","的","再","几点","吧"],
 "现在": ["在","就","可以","是","有","要","去","已经","几点","开始","还"],
 "什么": ["时候","意思","地方","问题","都","也","叫","样","都行","情况","原因"],
 "怎么": ["了","办","样","回事","说","能","不","才","这么","写","做","去"],
 "为什么": ["不","要","会","呢","没有","这么","我","你"],
 "可以": ["吗","吗？","的","了","不","直接","先","再","一起","帮","给"],
 "请": ["问","你","帮","把","稍","注意","不要","在"],
 "好的": ["，","！","那","我","谢谢","收到","。","～"],
 "收到": ["，","！","谢谢","。","～"],
 "没问题": ["，","！","的","我","。"],
 "中国": ["人","的","共产党","移动","电信","联通","银行","邮政","大陆","话"],
 "世界": ["上","的","杯","第一","各地","很大","真小"],
 "时间": ["的","到","了","不够","安排","多久","紧"],
 "工作": ["的","了","忙","顺利","中","上","报告","安排","时间","效率"],
 "问题": ["是","的","在","很","不大","解决","了","这","没有"],
 "时候": ["，","的","就","还","我","要","能","已经","候"],
 "地方": ["的","在","有","去","很","这","找","人"],
 "东西": ["的","了","吗","在","很","买","收拾","放"],
 "感觉": ["很","不","挺","好","有点","自己","像"],
 "知道": ["了","吗","的","不","你","我","怎么","为什么"],
 "觉得": ["很","不","还","挺","有点","怎么样","对"],
 "因为": ["我","所以","他","这","为","今天","没有","是"],
 "所以": ["我","就","说","要","不","才","这","大家"],
 "但是": ["我","他","这","是","不","如果","也","还"],
 "如果": ["你","我","有","不","是","没有","要","能","就"],
 "马上": ["就","要","到","来","出发","开始","给","可以"],
 "已经": ["在","了","有","不","是","完成","开始","发"],
 "一起": ["去","来","看","吃饭","走","吧","讨论","努力"],
 "这个": ["是","在","我","不","可以","问题","东西","人","地方","很","真的","要"],
 "那个": ["是","人","地方","时候","不","我","我"],
 "真的": ["吗","很","不","是","好","假的","太","有"],
 "非常": ["好","感谢","重要","不错","喜欢","抱歉","适合"],
 "特别": ["是","好","感谢","想","喜欢","要注意"],
 "哈哈": ["哈哈","，","！","～","太","好","是的"],
 "加油": ["！","～","，","吧","打气","努力"],
 "面试": ["的","时候","通过","结果","问题","准备","通知","顺利","加油"],
 "输入法": ["的","打不了","候选","联想","词库","设置","切换","很好用"],
}
for k, vs in MANUAL.items():
    for i, v in enumerate(vs):
        w = 100000 - i * 100
        if assoc_next[k].get(v, 0) < w:
            assoc_next[k][v] = w

# 2) 旧引擎词级搭配（真实语料统计：你好→吗、今天→天气、我→想）
for row in word_bigrams:
    try:
        a, b, f = row[0], row[1], int(row[2])
    except Exception:
        continue
    if not a or not b:
        continue
    w = 50000 + f * 100
    if assoc_next[a].get(b, 0) < w:
        assoc_next[a][b] = w

# 3) 短语派生后缀：高频词 W 若在更长的短语里做前缀，则后半段是合理后续词。
#    只接受可信高频词/常用单字，冷僻成语（好事之徒/好事多悭）会被过滤掉。
common_chars = set(c for c, _ in freq_chars.most_common(1200))
for words in trimmed_phrase.values():
    for w in words:
        if not (3 <= len(w) <= 6):
            continue
        for L in range(1, min(3, len(w) - 1) + 1):
            pre, suf = w[:L], w[L:]
            if not suf:
                continue
            # 前缀必须是常用词/常用字，后缀必须可信
            if pre not in hot_set and pre not in common_chars:
                continue
            if suf not in hot_set and not (len(suf) == 1 and suf in common_chars):
                continue
            wgt = min(9000, real_freq.get(w, 20))
            if assoc_next[pre].get(suf, 0) < wgt:
                assoc_next[pre][suf] = wgt

# 输出：每 key 只留前 ASSOC_PER_CTX 个，按权重降序
assoc_out = {}
for k, d in assoc_next.items():
    if len(k) > 6:
        continue
    arr = sorted(d.items(), key=lambda kv: -kv[1])[:ASSOC_PER_CTX]
    if arr:
        assoc_out[k] = [a for a, _ in arr]

# ---- 字符 bigram 裁剪 ----
top_ctx = [c for c, _ in freq_chars.most_common() if len(c) == 1][:BIGRAM_TOP_CTX]
bigram_out = {}
for a in top_ctx:
    cnt = char_bigram.get(a)
    if not cnt:
        continue
    bigram_out[a] = {b: c for b, c in cnt.most_common(BIGRAM_PER_CTX)}

# ---- T9 数字串 -> 音节列表（离线预计算） ----
all_syl = set(new_chars.keys()) | set(std_syllables)
t9_raw = defaultdict(list)
for syl in all_syl:
    if not syl or not syl.isalpha():
        continue
    # 9 键不允许单个数字自成音节。
    # 旧版放行了 a/e/o（对应 2/3/6 键），结果长数字串被切成
    # ni'ye'o'e'o'e'o'ci 这种垃圾，还硬凑出「你也哦哦鄂哦此」。
    if len(syl) < 2:
        continue
    dk = ''.join(LETTER_DIGIT.get(c, '') for c in syl)
    if len(dk) != len(syl):
        continue
    top = (new_chars.get(syl) or [''])[0]
    t9_raw[dk].append((freq_chars.get(top, 0), syl))
t9_out = {k: [s for _, s in sorted(v, key=lambda x: -x[0])[:T9_PER_KEY]]
          for k, v in t9_raw.items()}

# ---- 英文常用词 ----
eng_out = sorted({w.lower() for w in english_words
                  if isinstance(w, str) and 2 <= len(w) <= 12 and w.isalpha()})

# ---- 超级简拼 / 整串纠错索引：离线预计算，键盘运行时零排序零遍历 ----
# 之前这两个索引在 load() 里遍历 2 万个 phrase keys 并逐键 sorted，
# 是键盘扩展启动期 O(n log n) 峰值的主要来源；改为打包时算好。
abbr_raw = defaultdict(list)
flat_out = {}
for key, phrases in trimmed_phrase.items():
    syls = key.split()
    if 2 <= len(syls) <= 3:
        initials = "".join(s[0] for s in syls if s)
        if initials:
            abbr_raw[initials].extend((hot_words.get(p, 0), p) for p in phrases[:3])
    # 整串纠错只收可信高频词，避免冷僻成语被当成纠错结果
    w = phrases[0]
    f = hot_words.get(w, 0)
    if f > 0 and len(key.replace(" ", "")) <= 12:
        flat_out[key.replace(" ", "")] = w

abbr_out = {}
for k, pairs in abbr_raw.items():
    seen, arr = set(), []
    for _, w in sorted(pairs, key=lambda x: -x[0]):
        if w in seen:
            continue
        seen.add(w)
        arr.append(w)
        if len(arr) >= 12:
            break
    if arr:
        abbr_out[k] = arr

os.makedirs(OUT, exist_ok=True)
def dump(name, obj):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))

dump("pinyin_chars.json", new_chars)
dump("pinyin_phrases.json", trimmed_phrase)
dump("pinyin_assoc.json", assoc_out)
dump("pinyin_bigram.json", bigram_out)
dump("pinyin_char_freq.json", dict(freq_chars))
dump("pinyin_hot_words.json", hot_words)
dump("pinyin_t9.json", t9_out)
dump("pinyin_english.json", eng_out)
dump("pinyin_abbr.json", abbr_out)
dump("pinyin_flat.json", flat_out)

files = ["pinyin_chars.json","pinyin_phrases.json","pinyin_assoc.json",
         "pinyin_bigram.json","pinyin_char_freq.json","pinyin_hot_words.json",
         "pinyin_t9.json","pinyin_english.json","pinyin_abbr.json",
         "pinyin_flat.json","cat_net.json"]
total = sum(os.path.getsize(os.path.join(OUT, f)) for f in files if os.path.exists(os.path.join(OUT, f)))
print("=== 生成完成 ===")
print("chars syllables:", len(new_chars), " phrase keys:", len(trimmed_phrase))
print("assoc keys(词->后续词):", len(assoc_out), " bigram:", len(bigram_out))
print("hot words:", len(hot_words), " t9 keys:", len(t9_out), " english:", len(eng_out))
print("简拼索引:", len(abbr_out), " 整串纠错索引:", len(flat_out))
print("包内 JSON 合计: %.2f MB" % (total/1024/1024))
for k in ["ni hao","gan jin","mian shi","zhong guo","shi jie"]:
    print("  校验 '%s' ->" % k, trimmed_phrase.get(k, "缺失"))
for k in ["你好","我","今天","什么","中国"]:
    print("  联想 '%s' ->" % k, assoc_out.get(k, "缺失"))
print("  T9 '426'(hao) ->", t9_out.get("426", "缺失"))
print("  T9 '64'(ni) ->", t9_out.get("64", "缺失"))
