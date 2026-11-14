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
    "https://raw.githubusercontent.com/fxsjy/jieba/master/jieba/dict.txt",
]

MIN_FREQ = 3
MAX_WORD_LEN = 6


def fetch():
    if os.path.exists(CACHE) and os.path.getsize(CACHE) > 1_000_000:
        print("使用已缓存词库 %.1f MB" % (os.path.getsize(CACHE) / 1024 / 1024))
        return
    last = None
    for url in SOURCES:
        try:
            print("下载开源词库:", url)
            urllib.request.urlretrieve(url, CACHE)
            print("下载完成 %.1f MB" % (os.path.getsize(CACHE) / 1024 / 1024))
            return
        except Exception as e:
            last = e
            print("  源不可用:", type(e).__name__, str(e)[:80])
    raise RuntimeError("全部词库源都不可用: %s" % last)


def is_chinese(w):
    return all("\u4e00" <= c <= "\u9fff" for c in w)


def main():
    fetch()
    seen = set()
    rows = 0
    skipped = 0
    with open(CACHE, encoding="utf-8", errors="ignore") as f, \
         open(OUT, "w", encoding="utf-8") as o:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            w = parts[0]
            try:
                freq = int(parts[1])
            except ValueError:
                continue
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
    print("生成 %s：%d 条真实词条（过滤 %d 条）" % (OUT, rows, skipped))
    print("下一步: python build_lexicon.py --extra extra_phrases.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
