# -*- coding: utf-8 -*-
"""增强版词库生成：在 build_dict.py 基础上补齐 真实短语词频 + 字符 bigram（联想/长句）。"""
import json, os
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
OUT = os.path.join(HERE, "Keyboard")

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
phrase_freq = Counter()      # phrase -> 出现次数（真实词频）
char_bigram = {}            # ch -> {nextch: count}  （来自所有词组，用于联想/上下文）

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

# ---- 词组 + 联想 + 词频 + bigram ----
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
        lst = phrase_map.setdefault(key, [])
        if len(lst) < 12:
            lst.append(phrase)
        phrase_freq[phrase] += 1
        # 联想：首字/前两字开头
        for pre in (phrase[0], phrase[:2]):
            if len(pre) < 1:
                continue
            al = assoc_map.setdefault(pre, [])
            if len(al) < 60 and phrase not in al:
                al.append(phrase)
        # 字符 bigram
        for i in range(len(phrase) - 1):
            a, b = phrase[i], phrase[i+1]
            char_bigram.setdefault(a, Counter())[b] += 1

# ---- 字表按 词频+高频日常字 重排 ----
freq_chars = Counter()
for ph, c in phrase_freq.items():
    for ch in ph:
        if '\u4e00' <= ch <= '\u9fff':
            freq_chars[ch] += c

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
    return ov + rest

new_chars = {syl: sort_chars(syl, lst) for syl, lst in chars_map.items()}

# bigram 转普通 dict
bigram_out = {k: dict(v) for k, v in char_bigram.items()}

os.makedirs(OUT, exist_ok=True)
json.dump(new_chars, open(os.path.join(OUT, "pinyin_chars.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))
json.dump(phrase_map, open(os.path.join(OUT, "pinyin_phrases.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))
json.dump(assoc_map, open(os.path.join(OUT, "pinyin_assoc.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))
json.dump(dict(phrase_freq), open(os.path.join(OUT, "pinyin_phrase_freq.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))
json.dump(bigram_out, open(os.path.join(OUT, "pinyin_bigram.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))
json.dump(dict(freq_chars), open(os.path.join(OUT, "pinyin_char_freq.json"),"w",encoding="utf-8"), ensure_ascii=False, separators=(",",":"))

print("chars syllables:", len(new_chars))
print("phrase keys:", len(phrase_map))
print("assoc keys:", len(assoc_map))
print("phrase_freq entries:", len(phrase_freq))
print("bigram entries:", len(bigram_out))
print("sample 你好 freq:", phrase_freq.get("你好"), " 中国 freq:", phrase_freq.get("中国"))
print("bigram 你->:", dict(list(bigram_out.get("你",{}).items())[:5]))
