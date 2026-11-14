#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""等待 inputmethod 分支最新构建完成，下载未签名 IPA 到 E:\紧急通知\输入法IPA\，
并校验：① Mach-O 有 LC_CODE_SIGNATURE 槽位(cryptid=0) ② NSExtensionPrincipalClass 在 NSExtension 内。
处理 GitHub artifact 下载跨域重定向需剥 Authorization 头的问题。
"""
import json, os, struct, sys, time, zipfile, plistlib, urllib.request, urllib.error

def _load_pat():
    pat = os.environ.get("GH_PAT")
    if pat:
        return pat
    # 回退：本地令牌文件（此文件不进仓库）
    p = r"E:\剪贴\项目说明\构建令牌.txt"
    try:
        with open(p, encoding="utf-8") as f:
            for line in f:
                t = line.strip()
                if t.startswith(("gho_", "ghp_", "github_pat_")):
                    return t
    except Exception:
        pass
    raise SystemExit("未找到 PAT：请设置环境变量 GH_PAT，或在本机 E:\\剪贴\\项目说明\\构建令牌.txt 放置令牌")

PAT = _load_pat()
REPO = "lj13809315321-cpu/quickpaste-ios"
WF = "build-inputmethod.yml"
OUT = r"E:\紧急通知\输入法IPA\PinyinKeyboard-unsigned.ipa"
RUN_ID = None  # None -> 自动取该 workflow 最新一次运行
POLL = 20
TIMEOUT = 900  # 秒

class _NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = urllib.request.HTTPRedirectHandler.redirect_request(self, req, fp, code, msg, headers, newurl)
        if new is None:
            return None
        old_host = urllib.parse.urlparse(req.get_full_url()).netloc
        new_host = urllib.parse.urlparse(newurl).netloc
        if old_host != new_host:
            # 跨域重定向：剥掉鉴权头，否则 401
            new.remove_header("Authorization")
        return new

def api(url):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {PAT}", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

def main():
    # 0) 解析要等的 run
    global RUN_ID
    if not RUN_ID:
        wf = api(f"https://api.github.com/repos/{REPO}/actions/workflows/{WF}/runs?per_page=1")
        RUN_ID = wf["workflow_runs"][0]["id"]
        print("[info] 自动选定最新 run:", RUN_ID)
    # 1) 等构建完成
    start = time.time()
    status, conclusion = "in_progress", None
    while time.time() - start < TIMEOUT:
        run = api(f"https://api.github.com/repos/{REPO}/actions/runs/{RUN_ID}")
        status, conclusion = run["status"], run.get("conclusion")
        print(f"[poll] run {RUN_ID}: {status} / {conclusion}")
        if status == "completed":
            break
        time.sleep(POLL)
    if status != "completed":
        print("[FAIL] 构建超时未完成"); sys.exit(1)
    if conclusion != "success":
        print(f"[FAIL] 构建结论 = {conclusion}"); sys.exit(1)
    print("[OK] 构建成功，开始下载 artifact")

    # 2) 找 artifact
    arts = api(f"https://api.github.com/repos/{REPO}/actions/runs/{RUN_ID}/artifacts")
    dl_url = None
    for a in arts.get("artifacts", []):
        if a.get("name") == "pinyin-ipa":
            dl_url = a["archive_download_url"]
            break
    if not dl_url:
        print("[FAIL] 找不到 pinyin-ipa artifact"); sys.exit(1)

    # 3) 下载（剥跨域重定向鉴权头）
    opener = urllib.request.build_opener(_NoAuthRedirect)
    req = urllib.request.Request(dl_url, headers={"Authorization": f"Bearer {PAT}", "Accept": "application/vnd.github+json"})
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".dl"
    with opener.open(req, timeout=120) as r, open(tmp, "wb") as f:
        while True:
            buf = r.read(1 << 20)
            if not buf: break
            f.write(buf)
    print(f"[OK] 下载完成 {os.path.getsize(tmp)} bytes -> {tmp}")

    # 4) 解压并定位 IPA
    import zipfile as zf
    with zf.ZipFile(tmp) as z:
        names = z.namelist()
        ipa = next((n for n in names if n.endswith(".ipa")), None)
        if not ipa:
            print("[FAIL] artifact 内无 .ipa"); sys.exit(1)
        z.extract(ipa, os.path.dirname(OUT))
    src = os.path.join(os.path.dirname(OUT), ipa)
    if src != OUT:
        if os.path.exists(OUT): os.remove(OUT)
        os.replace(src, OUT)
    os.remove(tmp)
    print(f"[OK] IPA 落盘: {OUT}")

    # 5) 校验
    z = zipfile.ZipFile(OUT)
    nms = z.namelist()
    app_p = [n for n in nms if n.endswith(".app/Info.plist")][0]
    ext_p = [n for n in nms if ".appex/" in n and n.endswith("/Info.plist")][0]
    app = plistlib.loads(z.read(app_p))
    ext = plistlib.loads(z.read(ext_p))
    ns = ext.get("NSExtension") or {}
    print("主 App ID   =", app.get("CFBundleIdentifier"), "Type=", app.get("CFBundlePackageType"))
    print("扩展 ID     =", ext.get("CFBundleIdentifier"), "Type=", ext.get("CFBundlePackageType"))
    print("扩展点      =", ns.get("NSExtensionPointIdentifier"))
    print("Principal   =", ns.get("NSExtensionPrincipalClass"))
    print("完全访问    =", (ns.get("NSExtensionAttributes") or {}).get("RequestsOpenAccess"))
    def slot(p):
        d = z.read(p)
        if len(d) < 32 or d[:4] != b"\xcf\xfa\xed\xfe": return "NOT-MACHO"
        ncmds = struct.unpack_from("<I", d, 16)[0]; off = 32; sig = False
        for _ in range(ncmds):
            if off + 8 > len(d): break
            cmd, size = struct.unpack_from("<2I", d, off)
            if cmd == 0x1D: sig = True
            if size < 8: break
            off += size
        return "slot=YES" if sig else "slot=NO"
    exes = [n for n in nms if n.endswith("/PinyinKeyboard") or n.endswith("/PinyinKeyboardKeyboard")]
    for e in exes: print(e.split("/")[-1], "->", slot(e))
    ok = (ns.get("NSExtensionPrincipalClass") == "PinyinKeyboardKeyboard.KeyboardViewController"
          and ns.get("NSExtensionPointIdentifier") == "com.apple.keyboard-service"
          and all("slot=YES" in slot(e) for e in exes))
    print("结论:", "PASS —— 可直接导入手机端签名工具" if ok else "FAIL —— 仍有缺口")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
