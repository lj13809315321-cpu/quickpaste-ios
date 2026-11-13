#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 ad-hoc/已签名 IPA 转成手机端签名工具可直接导入的【未签名 IPA】。

构造对齐墨指 Mozhi 的已知可装方案：
  1. 顶层只有 Payload/<App>.app/，无 iTunesMetadata.plist、无 SC_Info
  2. 主 App 与 .appex 扩展层【删除 _CodeSignature/ 签名资源目录】
     （Frameworks 内部的 CodeResources 属于第三方框架自带资源，按样本保留）
  3. 【删除 embedded.mobileprovision / .entitlements】
  4. 可执行文件【保留 LC_CODE_SIGNATURE 加载命令】= 给签名工具留签名槽位，
     保持 arm64 + cryptid=0（未加密，可直接安装）
  5. Info.plist 保持 XML 明文；PkgInfo 保留；扩展保持 PlugIns/*.appex

用法:
  python make_unsigned_ipa.py [源已签名IPA] [目标未签名IPA]
  源 = CI 编译 + ad-hoc 签名后的中间包（不交付），目标 = 手机端签名工具直接导入的未签名包。
"""
import os
import plistlib
import struct
import sys
import zipfile

SRC = (sys.argv[1] if len(sys.argv) > 1 else
       r"dist/PinyinKeyboard-signed.ipa")
DST = (sys.argv[2] if len(sys.argv) > 2 else
       r"out/PinyinKeyboard-unsigned.ipa")


def macho_facts(d):
    """返回 (是否 arm64, 是否有签名槽位, cryptid)。"""
    if len(d) < 32 or d[:4] != b"\xcf\xfa\xed\xfe":
        return False, False, None
    ncmds = struct.unpack_from("<I", d, 16)[0]
    off, sig, cryptid = 32, False, None
    for _ in range(ncmds):
        if off + 8 > len(d):
            break
        cmd, size = struct.unpack_from("<2I", d, off)
        if cmd == 0x1D:
            sig = True
        if cmd in (0x21, 0x2C) and off + 20 <= len(d):
            cryptid = struct.unpack_from("<3I", d, off + 8)[2]
        if size < 8:
            break
        off += size
    return True, sig, cryptid


def main():
    if not os.path.exists(SRC):
        print("[FATAL] 源 IPA 不存在:", SRC)
        return 2
    zin = zipfile.ZipFile(SRC, "r")
    all_names = zin.namelist()

    # 找出所有 bundle 的可执行文件（Info.plist -> CFBundleExecutable）
    machos = set()
    for n in all_names:
        if not n.endswith("/Info.plist"):
            continue
        try:
            pl = plistlib.loads(zin.read(n))
        except Exception:
            continue
        exe = pl.get("CFBundleExecutable")
        if not exe:
            continue
        base = n.rsplit("/", 1)[0]
        cand = base + "/" + exe
        if cand in all_names:
            machos.add(cand)

    if os.path.exists(DST):
        os.remove(DST)
    os.makedirs(os.path.dirname(DST) or ".", exist_ok=True)
    zout = zipfile.ZipFile(DST, "w", zipfile.ZIP_DEFLATED)
    skipped = []
    for info in zin.infolist():
        n = info.filename
        # 样本里没有 Payload/ 目录条目本身
        if n in ("Payload/", "Payload"):
            skipped.append(n)
            continue
        # 主 App / 扩展层的签名资源；Frameworks 内部保留
        if "_CodeSignature" in n and "/Frameworks/" not in n:
            skipped.append(n)
            continue
        if n.endswith("embedded.mobileprovision") or n.endswith(".entitlements"):
            skipped.append(n)
            continue
        zout.writestr(info, zin.read(n))
    zin.close()
    zout.close()

    print("=" * 74)
    print("生成未签名 IPA:", DST)
    print("  源 %d 字节 -> 目标 %d 字节" % (os.path.getsize(SRC), os.path.getsize(DST)))
    print("  剔除 %d 个条目:" % len(skipped))
    for n in skipped[:12]:
        print("    -", n)
    if len(skipped) > 12:
        print("    ... 其余 %d 个" % (len(skipped) - 12))

    # ---------------- 对照墨指样本的逐项校验 ----------------
    z = zipfile.ZipFile(DST)
    names = z.namelist()

    def ok(cond):
        return "[OK]  " if cond else "[FAIL]"

    print("\n  对照墨指已知可装方案逐项核对:")
    tops = sorted(set(n.split("/")[0] for n in names))
    print("    %s 1 顶层只有 Payload            -> %s" % (ok(tops == ["Payload"]), tops))
    print("    %s   无 Payload/ 目录条目        -> %s" %
          (ok("Payload/" not in names), "Payload/" in names))
    bundle_cs = [n for n in names if "_CodeSignature" in n and "/Frameworks/" not in n]
    print("    %s 2 主/扩展层无签名资源目录    -> %d 个" % (ok(not bundle_cs), len(bundle_cs)))
    prov = [n for n in names if "mobileprovision" in n or n.endswith(".entitlements")]
    print("    %s 3 无描述文件 / entitlements   -> %d 个" % (ok(not prov), len(prov)))
    print("    %s   无 iTunesMetadata/SC_Info  -> %s" %
          (ok(not any("iTunesMetadata" in n or "/SC_Info/" in n for n in names)), "无"))
    appex = sorted(set(n.split(".appex/")[0] + ".appex" for n in names if ".appex/" in n))
    print("    %s 4 键盘扩展 .appex 保留       -> %s" % (ok(bool(appex)), appex))
    print("    %s   PkgInfo 保留               -> %d 个" %
          (ok(any(n.endswith("/PkgInfo") for n in names)),
           sum(1 for n in names if n.endswith("/PkgInfo"))))
    xml_ok = True
    for n in [x for x in names if x.endswith("/Info.plist")]:
        if z.read(n)[:5] != b"<?xml":
            xml_ok = False
    print("    %s 5 Info.plist 全部 XML 明文    -> %s" % (ok(xml_ok), xml_ok))
    slot_ok = True
    for p in sorted(machos):
        if p not in names:
            slot_ok = False
            print("    [FAIL] 缺可执行文件", p)
            continue
        arm, sig, cryptid = macho_facts(z.read(p))
        good = arm and sig and cryptid == 0
        slot_ok = slot_ok and good
        print("    %s 6 %-28s 签名槽位=%s cryptid=%s" %
              (ok(good), p.split("/")[-1], sig, cryptid))
    z.close()
    passed = (not bundle_cs and not prov and tops == ["Payload"] and xml_ok and slot_ok)
    print("=" * 74)
    print("结论:", "PASS —— 构造与墨指样本一致，可直接导入手机端签名工具"
          if passed else "FAIL —— 有项目未对齐")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
