#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把开源中文词库转成拼音词库语料，喂给 build_lexicon.py 编译成 mmap 二进制表。

这一步只做「语料 -> 拼音串」，不碰 Swift 代码。想扩到 50 万 / 100 万条，
只要往 SOURCES 里加一个词库文件或 URL，重跑本脚本 + build_lexicon.py 即可：

    python expand_lexicon.py
    python build_lexicon.py --extra extra_phrases.txt

生成的 extra_phrases.txt 是构建中间产物，不会打进 IPA。
"""
import os
import sys
import urllib.request

from pypinyin import Style, lazy_pinyin

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "extra_phrases.txt")
CACHE = os.path.join(HERE, ".dict_cache.txt")

SOURCES = [
    # jieba 主词库（约 35 万条，含词频）
    ("jieba", "https://raw.githubusercontent.com/fxsjy/jieba/master/jieba/dict.txt"),
]

# 清华大学开源 THUOCL 领域词表（词\t频次），覆盖 IT / 财经 / 医药 / 法律 /
# 教育 / 地名 / 历史名人 / 食物 / 成语 —— 竞品大词库的通用补料来源。
THUOCL_BASE = "https://raw.githubusercontent.com/thunlp/THUOCL/master/data/"
THUOCL_FILES = [
    "THUOCL_IT.txt", "THUOCL_caijing.txt", "THUOCL_medical.txt",
    "THUOCL_law.txt", "THUOCL_edu.txt", "THUOCL_diming.txt",
    "THUOCL_lishimingren.txt", "THUOCL_food.txt", "THUOCL_chengyu.txt",
    "THUOCL_car.txt",
]

# 雾凇拼音（rime-ice）开源简体词库：格式 词<TAB>拼音<TAB>权重，
# 覆盖日常口语词、网络热词、地名、人名，是简体输入法社区的主力词库。
RIME_BASE = "https://raw.githubusercontent.com/iDvel/rime-ice/main/cn_dicts/"
RIME_FILES = [
    "41448.dict.yaml", "base.dict.yaml", "ext.dict.yaml",
    "others.dict.yaml", "moegirl.dict.yaml",
]

MIN_FREQ = 3
MAX_WORD_LEN = 6


def _download(url, dst):
    """带断点续传的下载：大词库文件（10~40MB）网络抖动时常断，按 Range 续传。"""
    have = os.path.getsize(dst) if os.path.exists(dst) else 0
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "lexicon-fetch",
                                                       "Range": "bytes=%d-" % have})
            with urllib.request.urlopen(req, timeout=60) as r, \
                 open(dst, "ab" if have else "wb") as f:
                while True:
                    chunk = r.read(1 << 16)
                    if not chunk:
                        break
                    f.write(chunk)
            return
        except Exception as e:
            have = os.path.getsize(dst) if os.path.exists(dst) else 0
            if attempt == 4:
                raise
            print("  重试(%d) %s: %s" % (attempt + 1, type(e).__name__, str(e)[:60]))


def fetch():
    """多源下载到缓存目录 .lexicon_cache/，每个源一个文件，缺哪个补哪个。"""
    import json
    cache_dir = os.path.join(HERE, ".lexicon_cache")
    os.makedirs(cache_dir, exist_ok=True)
    done_path = os.path.join(cache_dir, "_done.json")
    done = {}
    if os.path.exists(done_path):
        try:
            with open(done_path, encoding="utf-8") as f:
                done = json.load(f)
        except Exception:
            done = {}

    tasks = [("jieba", SOURCES[0][1])] + [("thuocl_" + n, THUOCL_BASE + n) for n in THUOCL_FILES]
    # wordfreq 高频中文词（pip 包，内置频率数据，不需要联网）
    try:
        from wordfreq import top_n_list
        wf_path = os.path.join(cache_dir, "wordfreq_zh.txt")
        if not os.path.exists(wf_path):
            print("生成 wordfreq 中文高频词表 …")
            with open(wf_path, "w", encoding="utf-8") as f:
                for w in top_n_list("zh", 200_000):
                    if 2 <= len(w) <= MAX_WORD_LEN:
                        f.write(w + "\n")
            print("  wordfreq 完成")
        tasks.append(("wordfreq", None))
    except Exception as e:
        print("  wordfreq 不可用(可 pip install wordfreq 补足):", type(e).__name__)

    tasks += [("rime_" + n, RIME_BASE + n) for n in RIME_FILES]

    for name, url in tasks:
        dst = os.path.join(cache_dir, name + ".txt")
        if name in done and os.path.exists(dst) and os.path.getsize(dst) > 100:
            continue
        if url is None:
            done[name] = True
            continue
        try:
            print("下载:", name, url)
            _download(url, dst)
            done[name] = True
            print("  完成 %.2f MB" % (os.path.getsize(dst) / 1024 / 1024))
        except Exception as e:
            print("  源不可用:", name, type(e).__name__, str(e)[:80])
    with open(done_path, "w", encoding="utf-8") as f:
        json.dump(done, f)


def iter_cache_lines():
    cache_dir = os.path.join(HERE, ".lexicon_cache")
    if not os.path.isdir(cache_dir):
        return
    for fn in sorted(os.listdir(cache_dir)):
        if not fn.endswith(".txt") or not os.path.getsize(os.path.join(cache_dir, fn)) > 100:
            continue
        yield os.path.join(cache_dir, fn)


def is_chinese(w):
    return all("\u4e00" <= c <= "\u9fff" for c in w)


def main():
    fetch()
    seen = set()
    rows = 0
    skipped = 0
    with open(OUT, "w", encoding="utf-8") as o:
        for path in iter_cache_lines():
            name = os.path.basename(path)
            with open(path, encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) < 2:
                        continue
                    w = parts[0]
                    # 词频解析（多格式兼容）：
                    #   jieba/THUOCL: 词<TAB>频次            → parts[1] 是数字
                    #   rime yaml:   词<TAB>拼音(带空格)<TAB>权重 → parts[1] 是拼音，
                    #               split 被空格拆开后，权重在最后一个元素
                    try:
                        freq = int(float(parts[1]))
                    except ValueError:
                        try:
                            freq = int(float(parts[-1]))
                        except ValueError:
                            freq = MIN_FREQ
                    if freq < MIN_FREQ or not (2 <= len(w) <= MAX_WORD_LEN):
                        skipped += 1
                        continue
                    if not is_chinese(w) or w in seen:
                        skipped += 1
                        continue
                    seen.add(w)
                    py = lazy_pinyin(w, style=Style.NORMAL)
                    key = " ".join(py).lower()
                    if not key.replace(" ", "").isalpha():
                        skipped += 1
                        continue
                    o.write(key + "\t" + w + "\t" + str(freq) + "\n")
                    rows += 1
            print("  [%s] 累计 %d 条" % (name, rows))
    print("生成 %s：%d 条真实词条（过滤 %d 条）" % (OUT, rows, skipped))
    print("下一步: python build_lexicon.py --extra extra_phrases.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
