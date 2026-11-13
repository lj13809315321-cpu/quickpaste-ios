#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""九宫格拼音输入法：拉取云端构建产物 IPA 到本地。

用法：python E:/紧急通知/ios_pinyin_keyboard/kb_pull.py
- 读 E:/剪贴/项目说明/构建令牌.txt 拿 PAT
- 找 quickpaste-ios 仓库 inputmethod 分支最近一次成功构建
- 下载 pinyin-ipa 产物 → 解包出 PinyinKeyboard-unsigned.ipa
- 校验主 App + 键盘扩展 .appex 都在
- 落到 E:/紧急通知/输入法IPA/
"""
import json
import plistlib
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

TOKEN_FILE = Path(r"E:\剪贴\项目说明\构建令牌.txt")
REPO = "lj13809315321-cpu/quickpaste-ios"
BRANCH = "inputmethod"
ART_NAME = "pinyin-ipa"
OUT_DIR = Path(r"E:\紧急通知\输入法IPA")
APP_PLIST = "Payload/PinyinKeyboard.app/Info.plist"
EXT_PLIST = "Payload/PinyinKeyboard.app/PlugIns/PinyinKeyboardKeyboard.appex/Info.plist"
EXT_BIN = "Payload/PinyinKeyboard.app/PlugIns/PinyinKeyboardKeyboard.appex/PinyinKeyboardKeyboard"
APP_BIN = "Payload/PinyinKeyboard.app/PinyinKeyboard"


def log(m):
    print(m, flush=True)


def api(path):
    headers = {"Accept": "application/vnd.github+json",
               "User-Agent": "kb-pull",
               "Authorization": "Bearer " + TOKEN}
    req = urllib.request.Request("https://api.github.com" + path, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def get_token():
    t = TOKEN_FILE.read_text(encoding="utf-8").strip().splitlines()[0].strip()
    return t


class _AuthStripRedirect(urllib.request.HTTPRedirectHandler):
    """跨域重定向（GitHub API 302 到 Azure blob）时剥掉 Authorization，
    否则 Azure 会因头部带 GitHub 令牌而返回 401。"""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        newreq = super().redirect_request(req, fp, code, msg, headers, newurl)
        if newreq is None:
            return None
        src = urllib.parse.urlparse(req.full_url).netloc
        dst = urllib.parse.urlparse(newurl).netloc
        if dst != src and "Authorization" in newreq.headers:
            del newreq.headers["Authorization"]
        return newreq


_OPENER = urllib.request.build_opener(_AuthStripRedirect())


def find_latest_success_run():
    data = api(f"/repos/{REPO}/actions/runs?branch={BRANCH}&per_page=10")
    for run in data.get("workflow_runs", []):
        if run.get("status") == "completed" and run.get("conclusion") == "success":
            return run
    return None


def find_artifact(run_id):
    data = api(f"/repos/{REPO}/actions/runs/{run_id}/artifacts")
    for a in data.get("artifacts", []):
        if a.get("name") == ART_NAME:
            return a
    return None


def raw_job_logs(job_id):
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    url = "https://api.github.com" + f"/repos/{REPO}/actions/jobs/{job_id}/logs"
    headers = {"Accept": "application/vnd.github+json",
               "User-Agent": "kb-pull",
               "Authorization": "Bearer " + TOKEN}
    opener = urllib.request.build_opener(NoRedirect)
    with opener.open(urllib.request.Request(url, headers=headers), timeout=60) as r:
        raw = r.read().decode("utf-8", "replace")
    # 跟一次重定向到 Azure blob
    raise_ = None
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
            pass
    except urllib.error.HTTPError as e:
        loc = e.headers.get("Location")
        if e.code in (301, 302, 303, 307, 308) and loc:
            with urllib.request.urlopen(
                    urllib.request.Request(loc, headers={"User-Agent": "kb-pull"}),
                    timeout=120) as r:
                return r.read().decode("utf-8", "replace")
    return raw


def dump_failure(run):
    try:
        jobs = api(f"/repos/{REPO}/actions/runs/{run['id']}/jobs")
        for job in jobs.get("jobs", []):
            if job.get("conclusion") != "failure":
                continue
            log(f"---- 失败 job: {job['name']} (id={job['id']}) ----")
            text = raw_job_logs(job["id"])
            hit = [l for l in text.splitlines()
                   if "error:" in l.lower() or "fatal" in l.lower() or "::error::" in l]
            for l in hit[-40:]:
                log(l[:300])
    except Exception as e:
        log(f"[WARN] 拉日志失败: {e}")


def main():
    global TOKEN
    TOKEN = get_token()
    log("== 查 inputmethod 分支最近一次成功构建 ==")
    run = find_latest_success_run()
    if not run:
        # 查是否有在跑或失败
        data = api(f"/repos/{REPO}/actions/runs?branch={BRANCH}&per_page=3")
        runs = data.get("workflow_runs", [])
        if runs:
            top = runs[0]
            log(f"没有成功构建。最新一条: id={top['id']} status={top['status']} conclusion={top['conclusion']}")
            if top.get("conclusion") == "failure":
                dump_failure(top)
        else:
            log("没有找到任何构建记录。")
        return 2

    log(f"最新成功构建: run_id={run['id']} created={run['created_at']}")
    art = find_artifact(run["id"])
    if not art:
        log("[FAIL] 该构建没有 pinyin-ipa 产物")
        return 2
    log(f"产物: {art['name']} size={art['size_in_bytes']//1024}KB")

    # 下载 artifact zip（API 返回重定向到 Azure，需跟随；跨域自动剥 Authorization）
    url = f"https://api.github.com/repos/{REPO}/actions/artifacts/{art['id']}/zip"
    headers = {"Authorization": "Bearer " + TOKEN, "User-Agent": "kb-pull"}
    req = urllib.request.Request(url, headers=headers)
    with _OPENER.open(req, timeout=180) as r:
        zip_bytes = r.read()
    log(f"下载产物 zip: {len(zip_bytes)} B")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    tmp_zip = OUT_DIR / "_pinyin_artifact.zip"
    tmp_zip.write_bytes(zip_bytes)

    with zipfile.ZipFile(tmp_zip) as z:
        names = z.namelist()
        ipa_name = next((n for n in names if n.lower().endswith(".ipa")), None)
        if not ipa_name:
            log("[FAIL] 产物内未找到 .ipa")
            return 2
        ipa_bytes = z.read(ipa_name)
    ipa_path = OUT_DIR / "PinyinKeyboard-unsigned.ipa"
    ipa_path.write_bytes(ipa_bytes)
    log(f"IPA 写出: {ipa_path} ({len(ipa_bytes)} B)")

    # 结构校验
    checks = []
    with zipfile.ZipFile(ipa_path) as z:
        names = z.namelist()
        for p in (APP_PLIST, EXT_PLIST, EXT_BIN, APP_BIN):
            checks.append((f"含 {p}", p in names))
        a = plistlib.loads(z.read(APP_PLIST))
        e = plistlib.loads(z.read(EXT_PLIST))
        checks.append(("主 App 版本", bool(a.get("CFBundleShortVersionString"))))
        checks.append(("扩展点键盘",
                       ((e.get("NSExtension") or {}).get("NSExtensionPointIdentifier")
                        == "com.apple.keyboard-service")))
        attrs = (e.get("NSExtension") or {}).get("NSExtensionAttributes") or {}
        checks.append(("完全访问 RequestsOpenAccess", attrs.get("RequestsOpenAccess") is True))
        minv = a.get("MinimumOSVersion") or ""
        try:
            floor_ok = float(minv.split(".")[0] + "." + minv.split(".")[1]) >= 16.0
        except Exception:
            floor_ok = bool(minv)
        checks.append((f"最低 iOS {minv} (>=16)", floor_ok))
        checks.append(("无签名描述文件",
                       not any("embedded.mobileprovision" in n for n in names)))
    log("---- 结构校验 ----")
    for name, ok in checks:
        log(f"[{'OK' if ok else 'FAIL'}] {name}")
    tmp_zip.unlink(missing_ok=True)
    if all(ok for _, ok in checks):
        log("[OK] IPA 已拉取到本地并校验通过")
        return 0
    log("[FAIL] 结构校验未通过")
    return 2


if __name__ == "__main__":
    sys.exit(main())
