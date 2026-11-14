#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 JSON 词库编译成 mmap 友好的二进制索引表。

为什么需要它
------------
iOS 键盘扩展常驻内存上限约 30MB。把 20 万 / 50 万词条的 JSON 解析成
Swift 字典会瞬间 OOM 被 jetsam 杀掉（历史上已经踩过一次）。
这里改成「排序 key + 固定长度索引 + UTF-8 数据区」的二进制表：
Swift 侧用 Data(contentsOf:options:.mappedIfSafe) 映射文件，二分查 key，
只把命中的那几条 value 解码成 String —— 词库 50 万条、文件几十 MB，
常驻内存依然接近 0，且不需要改一行 Swift 代码就能扩容。

文件格式（全部小端）
-------------------
  0..4    magic  "MZLX"
  4..8    version U32 = 1
  8..12   keyCount U32
  12..16  dataOffset U32
  16..24  reserved (8B)
  24..    index: keyCount × 12B
              keyOff U32 (相对 dataOffset)
              keyLen U16
              valOff U32 (相对 dataOffset)
              valLen U16
  dataOffset.. UTF-8 数据区（key 字节 + value 字节，value 内用 \\t 分隔多词）

索引按 key 的 UTF-8 字节字典序排列，Swift 二分比较时用同样的字节序。

用法
----
  python build_lexicon.py                      # 用现有 JSON 生成 4 个 .bin
  python build_lexicon.py --extra extra.txt   # 追加任意规模语料后再生成
  python build_lexicon.py --stats             # 只打印规模，不写文件

extra.txt 每行：  拼音串<TAB>词1[<TAB>词2 ...]
  例：  ni hao    你好
        zhong guo 中国    中华
也可以直接把更大的 pinyin_phrases.json / pinyin_hot_words.json 放进来，
脚本会自动读取，无需改 Swift。
"""
import argparse
import json
import math
import os
import struct
import sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Keyboard")
MAGIC = b"MZLX"
SEP = "\t"


def compress_freq(f):
    """语料原始频次压到 hot words(172~341)刻度带下方。
    用 30+2.7*sqrt(f) 而不是对数：rime 里闺蜜 9999 vs 归你 5480 近 2:1 的
    排序信号必须保留（对数会把 2:1 压成 1.06:1，闺蜜就压不过归你了）；
    hot words 保持原值不被覆盖。"""
    f = max(1, int(f))
    return min(341, max(2, round(30 + 2.7 * math.sqrt(f))))


def load_json(name):
    p = os.path.join(OUT, name)
    if not os.path.exists(p):
        return {}
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def compile_table(items):
    """items: dict[str, str] -> (bytes, keyCount, dataSize)"""
    pairs = sorted(
        ((k.encode("utf-8"), v.encode("utf-8")) for k, v in items.items() if k and v),
        key=lambda kv: kv[0],
    )
    # 相同 key 合并（扩库时可能重复）
    merged = []
    for k, v in pairs:
        if merged and merged[-1][0] == k:
            old = merged[-1][1]
            have = set(old.split(b"\t"))
            add = [x for x in v.split(b"\t") if x and x not in have]
            merged[-1] = (k, b"\t".join([old] + add)) if add else merged[-1]
        else:
            merged.append((k, v))
    pairs = merged

    count = len(pairs)
    index_size = count * 12
    data_offset = 24 + index_size

    data = bytearray()
    index = bytearray()
    for k, v in pairs:
        key_off = len(data)
        data += k
        val_off = len(data)
        data += v
        index += struct.pack("<IHIH", key_off, len(k), val_off, len(v))
        # "<IHIH"（无对齐）= U32 + U16 + U32 + U16 = 12B

    head = bytearray()
    head += MAGIC
    head += struct.pack("<I", 1)
    head += struct.pack("<I", count)
    head += struct.pack("<I", data_offset)
    head += struct.pack("<I", 0)
    head += struct.pack("<I", 0)
    assert len(head) == 24
    return bytes(head) + bytes(index) + bytes(data), count, len(data)


def read_extra(path):
    """每行：拼音串<TAB>词<TAB>频次（expand_lexicon.py 生成）。
    返回 {拼音串: [(词, 频次), ...]} —— 频次进 freq.bin，是排序质量的关键。"""
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t") if "\t" in line else line.split("|")
            if len(parts) < 2:
                continue
            key = parts[0].strip().lower()
            w = parts[1].strip()
            if not key or not w or not any("\u4e00" <= c <= "\u9fff" for c in w):
                continue
            try:
                freq = int(float(parts[2])) if len(parts) >= 3 else 0
            except ValueError:
                freq = 0
            lst = out.setdefault(key, [])
            if all(x[0] != w for x in lst) and len(lst) < 12:
                lst.append((w, freq))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extra", help="追加语料文件（拼音串<TAB>词1<TAB>词2...）")
    ap.add_argument("--extra-json", help="追加一个 key->[words] 的 JSON 文件")
    ap.add_argument("--stats", action="store_true", help="只统计不写文件")
    args = ap.parse_args()

    phrases = load_json("pinyin_phrases.json")
    flat = load_json("pinyin_flat.json")
    abbr = load_json("pinyin_abbr.json")
    hot = load_json("pinyin_hot_words.json")

    extra = {}
    extra_freqs = {}
    if args.extra:
        for k, pairs in read_extra(args.extra).items():
            extra[k] = [w for w, _ in pairs]
            for w, f in pairs:
                if f > 0:
                    extra_freqs[w] = max(extra_freqs.get(w, 0), f)
    if args.extra_json:
        with open(args.extra_json, encoding="utf-8") as f:
            d = json.load(f)
        for k, v in d.items():
            if isinstance(v, list):
                extra.setdefault(k.lower(), []).extend([x for x in v if isinstance(x, str)][:12])
            elif isinstance(v, str):
                extra.setdefault(k.lower(), []).append(v)

    total_extra_words = 0
    for k, words in extra.items():
        cur = list(phrases.get(k, []))
        added = 0
        for w in words:
            if w not in cur and len(cur) < 16:
                cur.append(w)
                added += 1
        if added:
            phrases[k] = cur
            total_extra_words += added

    # freq.bin：hot words 精选刻度（172~341）保持原值，93 万语料词按对数压缩后并入。
    # Swift isTrusted/approxWordFreq 走 freqValue() 自动生效：闺蜜/西安/余额这类
    # 「真实词但字频低」的词拿到 trusted 加成，不再被「归你」这类高频字拼凑压过。
    freq_out = dict(hot)
    for w, f in extra_freqs.items():
        if w not in freq_out:
            freq_out[w] = compress_freq(f)
    print("freq.bin 词条: hot=%d 语料=%d 合计=%d" % (len(hot), len(freq_out) - len(hot), len(freq_out)))

    tables = {
        "lexicon.bin": {k: SEP.join(v) for k, v in phrases.items() if v},
        "flat.bin": {k: v for k, v in flat.items() if isinstance(v, str)},
        "abbr.bin": {k: SEP.join(v) for k, v in abbr.items() if v},
        "freq.bin": {k: str(v) for k, v in freq_out.items()},
    }

    print("=== mmap 词库编译 ===")
    print("追加语料 key: %d  新增词: %d" % (len(extra), total_extra_words))
    grand = 0
    for name, items in tables.items():
        blob, count, dsize = compile_table(items)
        grand += len(blob)
        print("  %-14s key=%7d  data=%8.2f MB  file=%8.2f MB" %
              (name, count, dsize / 1024 / 1024, len(blob) / 1024 / 1024))
        if not args.stats:
            with open(os.path.join(OUT, name), "wb") as f:
                f.write(blob)
    print("  合计 %.2f MB（mmap 后不计入键盘扩展常驻内存）" % (grand / 1024 / 1024))
    if args.stats:
        print("  --stats 模式：未写文件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
