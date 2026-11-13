# 九宫格拼音键盘（iOS 自定义键盘扩展）

一个**本地运行、不联网**的 iOS 自定义键盘，支持你要的 5 种模式 + 搜狗式能力：

- **中文 9 键**（T9 拼音，默认）／ **中文 26 键**（一键切换）
- **英文 26 键** ／ **数字** ／ **符号** ／ **剪贴板**（需开启「完全访问」）
- **语境联想**：根据刚输入的末 1~2 字预测后续词组
- **个人学习**：把你打过的词记进本地词库、按词频加权，同样拼音下常用词前置（持久化在设备）
- **细胞词库**：分领域词库独立打包、可加载合并；已带示例「网络热词」(`Keyboard/cat_net.json`) 并预留合并接口

> 明确排除（按你的要求）：手写、五笔、笔画、语音。

---

## 打包方式：作为 quickpaste-ios 的 `inputmethod` 分支（复用现有证书）

本工程是 **`lj13809315321-cpu/quickpaste-ios` 仓库的一个独立分支 `inputmethod`**（孤儿分支，与 `main` 互不影响），
直接复用你墨指那套 **GitHub Actions 云端 macOS 编译 → 未签名 IPA → 手机端用自己的证书重签** 的流程，
**无需去 Apple 后台新建任何 App ID / 证书 / 描述文件**。

- 仓库：`https://github.com/lj13809315321-cpu/quickpaste-ios.git`
- 分支：`inputmethod`（推送此分支即自动触发云端构建）
- Apple Team：`X6STQ8LZUD`（quickpaste 同套）
- 主 App Bundle ID：`app.mulberry6323.mozhi.pinyinkeyboard`
- 键盘扩展 Bundle ID：`app.mulberry6323.mozhi.pinyinkeyboard.keyboard`
- 证书/描述文件：沿用 quickpaste 的 **Ad Hoc**（通配 `app.mulberry6323.*` 已覆盖上面两个新 ID，无需新建）

---

## 一、推送 `inputmethod` 分支触发云端构建

1. 把本目录文件推到 `quickpaste-ios` 的 `inputmethod` 分支（已建立，推即可）。
2. 推送后云端 `macos-15-intel` 自动执行 `.github/workflows/build-inputmethod.yml`：
   checkout → `brew install xcodegen` → `xcodegen generate` → `xcodebuild`(不签名) → `fix_info_plists.py` → `make_unsigned_ipa.py` → 挂产物 `pinyin-ipa`。
3. 产物：`out/PinyinKeyboard-unsigned.ipa`。

---

## 二、取回未签名 IPA（复用 qp_build_monitor.py 思路）

复制你现有的 `qp_build_monitor.py`，改 3 处即可指向本分支：
- `REPO = "lj13809315321-cpu/quickpaste-ios"`（同一仓库）
- 分支/产物指到 `inputmethod` 分支产出的 `PinyinKeyboard-unsigned.ipa`
- `EXPECT_VER` / `EXPECT_BUILD` 按本工程版本填（见 `scripts/fix_info_plists.py` 顶部）

---

## 三、手机端签名安装（只能你自己做）

1. 把未签名 IPA 传到手机，导入签名工具（爱思/牛蛙/轻签名等）。
2. 注入方式选【原生】：包里 0 个 dylib，**不要挂任何插件**。
3. 证书选你的 `iPhone Distribution ... (X6STQ8LZUD)`，描述文件选那份 Ad Hoc（已覆盖新 ID）。
4. **连同 `PinyinKeyboardKeyboard.appex` 一起签**：只签主 App 不签扩展 → 键盘一弹就闪退。
5. 「不用签名」开关必须【关】（要真签）。
6. 装完：`设置 › 通用 › 键盘 › 键盘 › 添加新键盘 › 九宫格拼音 › 打开「允许完全访问」`。

---

## 四、本地直接跑（有 Mac 也行，跳过云端）

1. `brew install xcodegen` → `xcodegen generate` 生成 `PinyinKeyboard.xcodeproj`。
2. 打开工程，选真机/模拟器，`Product › Run`（先跑主 App，再跑 Keyboard target 调试）。
3. 确保 4 个 JSON（`pinyin_chars/phrases/assoc.json` + `cat_net.json`）在 **Keyboard target** 的 Copy Bundle Resources 里。

---

## 文件结构（本分支内容）

```
ios_pinyin_keyboard/
├─ project.yml                       # XcodeGen 双 target 定义（bundle id 已对齐 quickpaste 域名）
├─ App/                             # 主 App（说明页 + 入口，iOS 键盘强制要求的宿主）
│  ├─ PinyinKeyboardApp.swift
│  ├─ ContentView.swift
│  └─ Info.plist
├─ Keyboard/                        # 键盘扩展（真正干活）
│  ├─ KeyboardViewController.swift  # UI + 5 种模式 + 联想/剪贴板
│  ├─ PinyinEngine.swift            # 引擎：切分/9键展开/联想/学习/细胞词库
│  ├─ Info.plist                    # 已声明 RequestsOpenAccess
│  ├─ pinyin_chars.json             # 单字音节→汉字（414 音节）
│  ├─ pinyin_phrases.json           # 词组拼音→短语（4.1 万条）
│  ├─ pinyin_assoc.json             # 联想前缀表（3.9 万条）
│  └─ cat_net.json                  # 示例细胞词库：网络热词
├─ scripts/
│  ├─ fix_info_plists.py            # 编译后 plist 兜底回写
│  └─ make_unsigned_ipa.py          # 转未签名 IPA
├─ .github/workflows/build-inputmethod.yml   # 云端构建脚本（监听 inputmethod 分支）
└─ README.md
```

---

## 与搜狗的差距（诚实说明）

已做到：本地拼音候选、9 键 T9、语境联想、个人词频学习、可扩展细分词库。
**暂未做到**（多为资源/架构限制，非 impossibility）：

- **全网热词自动更新**：需自建后端/定期拉词库，再调用 `PinyinEngine.shared.mergeCategory(...)` 合并。
- **整句/长句语言模型预测**：现联想基于「词库前缀 + 个人词频」近似，无 n-gram/神经网络 LM。
- **词库广度**：内置开源词库约 4 万词组；搜狗是亿级（可后续接更大源扩充 `pinyin_phrases.json`）。
- **云同步个人词库**：目前只存本机键盘 `UserDefaults`，换设备不跟随。

## 加更多「细胞词库」

1. 准备 JSON：`{ "ni hao": ["你好"], "zhong guo": ["中国"] }`（拼音 key 空格分隔、无声调）。
2. 在 `PinyinEngine.load()` 加一行 `mergeCategory(读取的该 JSON)`，或运行时 `PinyinEngine.shared.mergeCategory(dict)`。
3. 按领域（游戏/法律/医学/地名）分别打包，按需开关。

---

> 说明：我无法在此环境编译验证，代码按 iOS 14+（含 18）API 书写。Xcode/云端若报小错（多为签名/Resource 勾选/plist 字段），按上面步骤排查；需要我针对具体报错改代码，把日志发我即可。
