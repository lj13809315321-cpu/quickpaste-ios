#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把云端编译出的（未签名）App + 键盘扩展 打包成「未签名 IPA」。
- 不调用 codesign（保留 Mach-O 里的签名槽位，未加密 cryptid=0）
- 删除 _CodeSignature / embedded.mobileprovision
- 手机端签名工具可直接导入重签
"""
import os
import sys
import glob
import shutil
import zipfile


def find_app(root):
    apps = [a for a in glob.glob(os.path.join(root, "**", "*.app"), recursive=True)
            if not a.endswith(".appex")]
    return apps[0] if apps else None


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "build"
    app = find_app(root)
    if not app:
        print("ERROR: 在 %s 下找不到 .app" % root)
        sys.exit(1)

    out_dir = "out"
    os.makedirs(out_dir, exist_ok=True)
    payload = os.path.join(out_dir, "Payload")
    if os.path.exists(payload):
        shutil.rmtree(payload)
    os.makedirs(payload)

    dest = os.path.join(payload, os.path.basename(app))
    shutil.copytree(app, dest)

    # 移除签名痕迹（保留未签名状态）
    sig = os.path.join(dest, "_CodeSignature")
    if os.path.exists(sig):
        shutil.rmtree(sig)
    prov = os.path.join(dest, "embedded.mobileprovision")
    if os.path.exists(prov):
        os.remove(prov)

    ipa = os.path.join(out_dir, "PinyinKeyboard-unsigned.ipa")
    if os.path.exists(ipa):
        os.remove(ipa)
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as z:
        for base, _, files in os.walk(payload):
            for fn in files:
                full = os.path.join(base, fn)
                arc = os.path.relpath(full, out_dir)
                z.write(full, arc)

    print("WROTE", ipa)


if __name__ == "__main__":
    main()
