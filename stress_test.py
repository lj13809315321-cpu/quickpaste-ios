# -*- coding: utf-8 -*-
"""
压力测试：以真实用户视角，按场景批量测 9 键/26 键整句能力。
场景：衣食住行 / 客服话术 / 短视频文案 / 日常聊天 / 长句(6-12字) /
     平翘舌(zh-z ch-c sh-s) / 前后鼻音(an-ang in-ing) / n-l / h-f /
     9键按错一键纠错。
判定：首位命中 = PASS；前3候选含 = NEAR；否则 FAIL。
"""
import io, time, sys
exec(io.open(__file__.replace("stress_test.py", "verify_engine.py"), encoding="utf-8")
     .read().split("# ==================================================================")[0])

LD = {  # 字母 -> 数字键
    "a": "2", "b": "2", "c": "2", "d": "3", "e": "3", "f": "3",
    "g": "4", "h": "4", "i": "4", "j": "5", "k": "5", "l": "5",
    "m": "6", "n": "6", "o": "6", "p": "7", "q": "7", "r": "7", "s": "7",
    "t": "8", "u": "8", "v": "8", "w": "9", "x": "9", "y": "9", "z": "9",
}

def to9(py):
    """'ni hao' -> '64426'"""
    return "".join(LD[c] for c in py if c.isalpha())

# ==================================================================
# 用例：(场景, 拼音, 期望)   —— 全部取自真实高频口语
CASES = [
    # ---- 衣 ----
    ("衣食住行", "yi fu", "衣服"), ("衣食住行", "mai jian yu rong fu", "买件羽绒服"),
    ("衣食住行", "zhe jian duo shao qian", "这件多少钱"), ("衣食住行", "you da yi ma", "有大衣吗"),
    # ---- 食 ----
    ("衣食住行", "zhong wu chi shen me", "中午吃什么"), ("衣食住行", "jiao ge wai mai", "叫个外卖"),
    ("衣食住行", "wo xiang chi huo guo", "我想吃火锅"), ("衣食住行", "yi bei ke le", "一杯可乐"),
    ("衣食住行", "zhe jia dian hao chi", "这家店好吃"),
    # ---- 住 ----
    ("衣食住行", "fang zu gai jiao le", "房租该交了"), ("衣食住行", "yu ding ming wan de jiu dian", "预订明晚的酒店"),
    ("衣食住行", "xi shou jian zai na", "洗手间在哪"), ("衣食住行", "kai kong tiao", "开空调"),
    # ---- 行 ----
    ("衣食住行", "bang wo jiao ge che", "帮我叫个车"), ("衣食住行", "di tie na yi zhan xia", "地铁哪一站下"),
    ("衣食住行", "ji chang zen me zou", "机场怎么走"), ("衣食住行", "gao tie duo jiu dao", "高铁多久到"),
    # ---- 客服 ----
    ("客服话术", "nin hao qing wen", "您好请问"), ("客服话术", "ma fan ti gong ding dan hao", "麻烦提供订单号"),
    ("客服话术", "shao deng ma shang wei nin", "稍等马上为您"), ("客服话术", "gei nin tui kuan le", "给您退款了"),
    ("客服话术", "hai you shen me ke yi bang nin", "还有什么可以帮您"),
    # ---- 短视频 ----
    ("短视频", "dian zan guan zhu", "点赞关注"), ("短视频", "shang lian jie", "上链接"),
    ("短视频", "lao tie men kan guo lai", "老铁们看过来"), ("短视频", "you hui quan ling le", "优惠券领了"),
    ("短视频", "zhe ge dong xi tai hao yong le", "这个东西太好用了"),
    # ---- 日常聊天 ----
    ("日常聊天", "wan shang yi qi chi fan ma", "晚上一起吃饭吗"),
    ("日常聊天", "wo zai di tie shang xin hao bu hao", "我在地铁上信号不好"),
    ("日常聊天", "ming tian ji de jiao wo qi chuang", "明天记得叫我起床"),
    ("日常聊天", "ni chi le ma", "你吃了吗"), ("日常聊天", "gan ma qu ya", "干嘛去呀"),
    ("日常聊天", "zuo tian shui de zao", "昨天睡得早"), ("日常聊天", "gei wo da dian hua", "给我打电话"),
    ("日常聊天", "yi hui er jian", "一会儿见"), ("日常聊天", "zhu yi an quan", "注意安全"),
    # ---- 口语"啥"字词族 / 正反问（真机截图回归 IMG_1808/1809）----
    ("日常聊天", "chi sha ya", "吃啥呀"),
    ("日常聊天", "jin tian wan shang chi sha ya", "今天晚上吃啥呀"),
    ("日常聊天", "wan shang chi sha", "晚上吃啥"),
    ("日常聊天", "chi bu chi", "吃不吃"),
    # ---- 火锅（真机截图回归 IMG_1802）----
    ("衣食住行", "gui mi chi huo guo", "闺蜜吃火锅"),
    # ---- 专有名词（真机截图回归 IMG_1810/1811/1813/1814：搜狗直出专名）----
    ("日常聊天", "dou po cang qiong", "斗破苍穹"),
    ("日常聊天", "fan ren xiu xian zhuan", "凡人修仙传"),
    # ---- 相邻位换位纠错（真机 948 打成 984，搜狗能救我们也必须能救）----
    ("纠错换位", "326736984942694826", "凡人修仙传"),
    # ---- 长句 8-12 字 ----
    ("长句", "wo ming tian yao qu shang hai chu chai", "我明天要去上海出差"),
    ("长句", "xia wu san dian zhong kai hui", "下午三点钟开会"),
    ("长句", "zhe ge zhou mo you kong ma", "这个周末有空吗"),
    ("长句", "bang wo dai yi bei ka fei xie xie", "帮我带一杯咖啡谢谢"),
    # ---- 平翘舌（zh/z ch/c sh/s）----
    ("平翘舌", "zhi dao", "知道"), ("平翘舌", "chi fan", "吃饭"), ("平翘舌", "shui jiao", "睡觉"),
    ("平翘舌", "zhi chi", "支持"), ("平翘舌", "zhong yao", "重要"), ("平翘舌", "shan shui", "山水"),
    ("平翘舌", "cao zuo", "操作"), ("平翘舌", "sui bian", "随便"),
    # ---- 前后鼻音（an/ang in/ing en/eng）----
    ("前后鼻音", "xin qing", "心情"), ("前后鼻音", "xing xing", "星星"),
    ("前后鼻音", "ren zhen", "认真"), ("前后鼻音", "shen ti", "身体"),
    ("前后鼻音", "qin jin", "亲近"), ("前后鼻音", "fang xin", "放心"),
    # ---- n / l ----
    ("nl混淆", "niu nai", "牛奶"), ("nl混淆", "liu lian", "榴莲"),
    ("nl混淆", "nao dai", "脑袋"), ("nl混淆", "nan fang", "南方"),
    # ---- h / f（26键模糊）----
    ("hf混淆", "fu qin", "父亲"), ("hf混淆", "hao chi", "好吃"),
    # ---- 9键相邻键纠错（切不出完整音节时必须救回）----
    ("纠错9键", "64425", "你好"),      # 64426 尾键 6 按成 5（物理相邻）
]

# ==================================================================
groups = {}
n_pass = n_near = n_fail = 0
fails = []
t_all = time.perf_counter()

for scene, py, want in CASES:
    is9 = py[0].isdigit()
    buf = py if is9 else to9(py)
    t0 = time.perf_counter()
    # deep=True：模拟真机「打完停顿 0.3s」后的深度纠错结果（键盘层停顿触发）
    d, c = decode(buf, True, deep=True) if is9 else decode(py.replace(" ", ""), False)
    dt = (time.perf_counter() - t0) * 1000
    cand = c[:3] if c else []
    if cand and cand[0] == want:
        r = "PASS"; n_pass += 1
    elif want in cand:
        r = "NEAR"; n_near += 1
    else:
        r = "FAIL"; n_fail += 1
        fails.append((scene, py, want, cand[:5], d))
    g = groups.setdefault(scene, [0, 0, 0])
    g[0 if r == "PASS" else (1 if r == "NEAR" else 2)] += 1

print("=" * 72)
print("场景报告（PASS 首位命中 / NEAR 前3含 / FAIL 未出）")
for scene, (p, nr, f) in groups.items():
    tot = p + nr + f
    print("  %-6s  %2d/%2d PASS  %d NEAR  %d FAIL   命中率 %.0f%%" % (
        scene, p, tot, nr, f, 100.0 * (p + 0.5 * nr) / tot))
print("=" * 72)
print("总计: PASS %d / NEAR %d / FAIL %d  (综合命中 %.0f%%)  用时 %.1f s" % (
    n_pass, n_near, n_fail, 100.0 * (n_pass + 0.5 * n_near) / len(CASES),
    time.perf_counter() - t_all))
print("=" * 72)
if fails:
    print("FAIL 明细（修这些）：")
    for scene, py, want, cand, d in fails:
        print("  [%s] %s → 期望 %s | 实际 %s (串 %s)" % (scene, py, want, "·".join(cand), d))
