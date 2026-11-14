#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""等 inputmethod 分支最近一次构建跑完，成功则拉回未签名 IPA 并校验。"""
import json
import os
import plistlib
import sys
import time
import urllib.error
import urllib.request
import zipfile

REPO = "lj13809315321-cpu/quickpaste-ios"
BRANCH = "inputmethod"
TOKEN_FILE = r"E:\剪贴\项目说明\构建令牌.txt"
DEST = r"E:\紧急通知\输入法IPA\PinyinKeyboard-unsigned.ipa"
API = "https://api.github.com/repos/%s" % REPO


def get_token():
    return open(TOKEN_FILE, encoding="utf-8").read().strip().splitlines()[0].strip()


def get(url, headers):
    req = urllib.request.Request(url, headers=headers)
    return urllib.request.urlopen(req, timeout=180)


def get_json(url):
    tok = get_token()
    with get(url, {"Authorization": "Bearer " + tok, "Accept": "application/vnd.github+json"}) as r:
        return json.load(r)


def latest_run():
    d = get_json("%s/actions/runs?branch=%s&per_page=1" % (API, BRANCH))
    return d["workflow_runs"][0] if d.get("workflow_runs") else None


def main():
    print("等待 %s 分支最近构建完成…" % BRANCH)
    run = latest_run()
    if not run:
        print("没有找到任何 run")
        sys.exit(1)
    rid = run["id"]
    print("监听 run_id=%s (created=%s)" % (rid, run["created_at"]))
    for _ in range(60):  # 最多 ~30 分钟
        run = get_json("%s/actions/runs/%s" % (API, rid))
        st = run["status"]
        print("  status=%s" % st)
        if st == "completed":
            break
        time.sleep(30)
    else:
        print("超时未结束")
        sys.exit(1)

    if run["conclusion"] != "success":
        print("构建失败 conclusion=%s，拉日志。" % run["conclusion"])
        sys.exit(2)

    # 拉 artifact
    d = get_json("%s/actions/runs/%s/artifacts" % (API, rid))
    arts = d.get("artifacts", [])
    if not arts:
        print("没有 artifact")
        sys.exit(3)
    art = arts[0]
    print("下载 artifact: %s (%d KB)" % (art["name"], art["size_in_bytes"] // 1024))
    # GitHub API 返回 302 到 Azure SAS 地址；重定向时务必剥掉 Authorization，
    # 否则 Azure 用 Bearer 令牌鉴权会 401。
    url = "%s/actions/artifacts/%s/zip" % (API, art["id"])
    tok = get_token()

    class _NoAuthRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return urllib.request.Request(newurl)  # 不带任何头（含 Authorization）

    opener = urllib.request.build_opener(_NoAuthRedirect)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok})
    resp = opener.open(req, timeout=180)
    zip_bytes = resp.read()
    tmp = r"C:\Temp\kb_new.zip"
    open(tmp, "wb").write(zip_bytes)
    print("zip 大小 %d 字节" % len(zip_bytes))

    out = r"C:\Temp\kb_new"
    if os.path.exists(out):
        import shutil
        shutil.rmtree(out)
    os.makedirs(out)
    z = zipfile.ZipFile(tmp)
    names = z.namelist()
    z.extractall(out)
    ipa = None
    for n in names:
        if n.lower().endswith(".ipa"):
            ipa = os.path.join(out, n)
            break
    if not ipa:
        print("zip 内无 .ipa，内容：", names[:10])
        sys.exit(4)

    # 校验
    z2 = zipfile.ZipFile(ipa)
    a = plistlib.loads(z2.read("Payload/PinyinKeyboard.app/Info.plist"))
    e = plistlib.loads(z2.read("Payload/PinyinKeyboard.app/PlugIns/PinyinKeyboardKeyboard.appex/Info.plist"))
    print("主App id =", a.get("CFBundleIdentifier"), "| minOS =", a.get("MinimumOSVersion"))
    print("扩展  id =", e.get("CFBundleIdentifier"), "| minOS =", e.get("MinimumOSVersion"))
    print("扩展点   =", (e.get("NSExtension") or {}).get("NSExtensionPointIdentifier"))
    print("完全访问 =", (e.get("NSExtension") or {}).get("NSExtensionAttributes", {}).get("RequestsOpenAccess"))

    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    import shutil
    shutil.copy(ipa, DEST)
    print("已复制到", DEST)
    print("DONE")


if __name__ == "__main__":
    main()
