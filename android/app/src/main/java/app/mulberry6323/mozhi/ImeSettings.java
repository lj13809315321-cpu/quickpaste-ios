package app.mulberry6323.mozhi;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * v1.6 完整多页设置界面（真·输入法内，按 HTML 原型 PAGES 注册表 1:1 实现）。
 * 页面：设置首页 / 键盘设置 / 快捷符号 / 连续复制 / 局域网同步 /
 *       6 篇使用教程 / 剪贴板历史 / 最近删除 / 引导 / 关于。
 * 全部开关写入 Prefs 并即时作用到键盘，不是摆设。
 */
public final class ImeSettings {

    public interface Host {
        void onSettingsChanged();
        void onSyncNow();
        void onSendInputText();
        void onSendClipboardText();
        void onSendClipboardImage();
        boolean onAdoptUrl();
        void onResetUrl();
        void onClearAll();
        void onSwitchKeyboard();
        void onInsertText(String text);
        void onToast(String text);
        String statusTitle();
        int statusCount();
        String backend();
    }

    private static final int BG = Color.parseColor("#F3F4F9");
    private static final int CARD = Color.WHITE;
    private static final int BLUE = Color.parseColor("#0A7CFF");
    private static final int SUB = Color.parseColor("#8A8A8F");
    private static final int SEP = Color.parseColor("#E6E6EB");
    private static final int KEY_BG = Color.parseColor("#D4D6DE");

    private final Context ctx;
    private final Host host;
    private final Prefs prefs;
    private final FrameLayout panel;
    private final TextView navTitle;
    private final Button navBack;
    private final LinearLayout body;
    private final ScrollView scroll;
    private final ArrayList<String> stack = new ArrayList<String>();

    private EditText urlField;
    private EditText pairField;
    private EditText symbolField;

    // ImeSettings 由 MozhiIME 构造，ctx 就是 IME Service 本身
    public ImeSettings(Context ctx, Host host) {
        this.ctx = ctx;
        this.host = host;
        this.prefs = new Prefs(ctx);
        this.panel = new FrameLayout(ctx);
        panel.setBackgroundColor(BG);
        panel.setClickable(true);
        panel.setVisibility(View.GONE);

        LinearLayout outer = new LinearLayout(ctx);
        outer.setOrientation(LinearLayout.VERTICAL);
        panel.addView(outer, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // 导航条
        LinearLayout nav = new LinearLayout(ctx);
        nav.setOrientation(LinearLayout.HORIZONTAL);
        nav.setGravity(Gravity.CENTER_VERTICAL);
        nav.setBackgroundColor(Color.parseColor("#EFEFF4"));
        nav.setPadding(dp(10), 0, dp(12), 0);
        outer.addView(nav, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(38)));

        navBack = plainButton("关闭");
        nav.addView(navBack, new LinearLayout.LayoutParams(dp(80), dp(38)));
        navBack.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { back(); }
        });

        navTitle = new TextView(ctx);
        navTitle.setTextSize(15);
        navTitle.setTextColor(Color.BLACK);
        navTitle.setGravity(Gravity.CENTER);
        navTitle.getPaint().setFakeBoldText(true);
        nav.addView(navTitle, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 1f));

        Button done = plainButton("完成");
        nav.addView(done, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, dp(38)));
        done.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { close(); }
        });

        scroll = new ScrollView(ctx);
        outer.addView(scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        body = new LinearLayout(ctx);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setPadding(dp(12), dp(10), dp(12), dp(24));
        scroll.addView(body, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
    }

    public View view() { return panel; }

    public void open() { open("root"); }

    public void open(String page) {
        stack.clear();
        stack.add(page);
        panel.setVisibility(View.VISIBLE);
        panel.bringToFront();
        render();
    }

    private void push(String page) {
        stack.add(page);
        render();
    }

    private void back() {
        if (stack.size() > 1) { stack.remove(stack.size() - 1); render(); }
        else close();
    }

    public void close() { panel.setVisibility(View.GONE); stack.clear(); }

    public boolean isVisible() { return panel.getVisibility() == View.VISIBLE; }

    private String current() { return stack.isEmpty() ? "root" : stack.get(stack.size() - 1); }

    // ---------------- 渲染 ----------------

    private void render() {
        body.removeAllViews();
        String p = current();
        navTitle.setText(titleOf(p));
        navBack.setText(stack.size() > 1 ? "‹ 返回" : "关闭");

        if ("root".equals(p)) renderRoot();
        else if ("kbd".equals(p)) renderKbd();
        else if ("symbols".equals(p)) renderSymbols();
        else if ("continuous".equals(p)) renderContinuous();
        else if ("sync".equals(p)) renderSync();
        else if ("tutorials".equals(p)) renderTutorialList();
        else if (p.startsWith("tut:")) renderTutorial(p.substring(4));
        else if ("history".equals(p)) renderHistory();
        else if ("deleted".equals(p)) renderDeleted();
        else if ("onboarding".equals(p)) renderOnboarding();
        else if ("about".equals(p)) renderAbout();
        else if ("confirmClear".equals(p)) renderConfirmClear();
        scroll.scrollTo(0, 0);
    }

    private String titleOf(String p) {
        if ("root".equals(p)) return "设置";
        if ("kbd".equals(p)) return "键盘设置";
        if ("symbols".equals(p)) return "快捷符号";
        if ("continuous".equals(p)) return "连续复制";
        if ("sync".equals(p)) return "局域网同步（CopyQ）";
        if ("tutorials".equals(p)) return "使用教程";
        if (p.startsWith("tut:")) return Tutorials.title(p.substring(4));
        if ("history".equals(p)) return "剪贴板历史";
        if ("deleted".equals(p)) return "最近删除";
        if ("onboarding".equals(p)) return "启用引导";
        if ("about".equals(p)) return "关于";
        if ("confirmClear".equals(p)) return "清除历史记录";
        return "设置";
    }

    private void renderRoot() {
        body.addView(bigTitle("设置"));
        body.addView(foot("墨指 v1.8.22 · 真·系统输入法 · 按 HTML 最新版效果原生实现，无网页、无演示动画"));

        body.addView(groupTitle("使用"));
        LinearLayout use = card();
        use.addView(navRow("局域网同步（CopyQ）", host.statusTitle(), "sync"));
        use.addView(navRow("键盘设置", "", "kbd"));
        use.addView(navRow("快捷符号", "", "symbols"));
        use.addView(navRow("连续复制", "", "continuous"));
        use.addView(navRow("使用教程", "", "tutorials"));
        body.addView(use);

        body.addView(groupTitle("数据"));
        LinearLayout data = card();
        final String[] dayLabels = {"7 天", "30 天", "90 天", "永久"};
        final int[] dayValues = {7, 30, 90, 0};
        int cur = 1;
        for (int i = 0; i < dayValues.length; i++) if (dayValues[i] == prefs.historyDays()) cur = i;
        data.addView(segmentRow("历史保留时间", dayLabels, cur, new RadioGroup.OnCheckedChangeListener() {
            @Override public void onCheckedChanged(RadioGroup group, int checkedId) {
                int i = checkedId;
                prefs.setHistoryDays(dayValues[i]);
                int n = prefs.pruneHistory();
                host.onSettingsChanged();
                host.onToast("已设为 " + dayLabels[i] + (n > 0 ? "，清理 " + n + " 条" : ""));
            }
        }));
        data.addView(navRow("最近删除", prefs.recentDeleted().size() + " 条", "deleted"));
        data.addView(actionRow("清除历史记录", Color.parseColor("#FF3B30"), "confirmClear"));
        data.addView(switchRow("仅看未分类（隐藏置顶）", "开启后列表只显示未置顶的剪贴板记录",
                prefs.onlyUnsorted(), new CompoundButton.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(CompoundButton b, boolean v) {
                        prefs.setOnlyUnsorted(v);
                        host.onSettingsChanged();
                    }
                }));
        body.addView(data);
        body.addView(foot("置顶的记录不会被自动清理。历史记录保存在本机，不上传云端。"));

        body.addView(groupTitle("快捷操作"));
        LinearLayout quick = card();
        quick.addView(actionRow("⟳ 立即同步（" + host.statusCount() + " 条）", BLUE, new Runnable() {
            @Override public void run() { host.onSyncNow(); host.onToast("正在同步…"); }
        }));
        quick.addView(actionRow("↑ 发送输入框文字到电脑", BLUE, new Runnable() {
            @Override public void run() { host.onSendInputText(); }
        }));
        quick.addView(actionRow("📋 发送剪贴板文字到电脑", BLUE, new Runnable() {
            @Override public void run() { host.onSendClipboardText(); }
        }));
        quick.addView(actionRow("🖼 发送剪贴板图片到电脑", BLUE, new Runnable() {
            @Override public void run() { host.onSendClipboardImage(); }
        }));
        body.addView(quick);

        body.addView(groupTitle("预览"));
        LinearLayout preview = card();
        preview.addView(actionRow("打开输入法键盘", BLUE, new Runnable() {
            @Override public void run() { close(); }
        }));
        preview.addView(navRow("查看剪贴板历史", "", "history"));
        preview.addView(navRow("重新播放引导页", "", "onboarding"));
        preview.addView(navRow("关于本版本", "", "about"));
        body.addView(preview);
    }

    private void renderKbd() {
        LinearLayout top = card();
        top.addView(navRow("使用教程", "", "tutorials"));
        top.addView(actionRow("打开系统设置（请手动进入）", BLUE, new Runnable() {
            @Override public void run() {
                host.onToast("设置 → 系统 → 语言和输入法 → 启用 墨指 同步键盘");
            }
        }));
        body.addView(top);
        body.addView(foot("安卓请在「系统设置 → 语言和输入法」里启用本输入法，并在输入框切换。"));

        body.addView(groupTitle("子设置"));
        LinearLayout sub = card();
        sub.addView(navRow("快捷符号", "", "symbols"));
        sub.addView(navRow("连续复制", "", "continuous"));
        sub.addView(navRow("局域网同步（CopyQ）", "", "sync"));
        body.addView(sub);

        body.addView(groupTitle("键盘开关"));
        LinearLayout sw = card();
        sw.addView(switchRow("悬浮窗关闭按钮", "浮层右上角显示关闭按钮", prefs.floatClose(),
                new CompoundButton.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(CompoundButton b, boolean v) {
                        prefs.setFloatClose(v); host.onSettingsChanged();
                    }
                }));
        sw.addView(switchRow("点击直接切换", "长按 ✕ 时直接切换剪贴板／常用语，不弹菜单", prefs.directSwitch(),
                new CompoundButton.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(CompoundButton b, boolean v) {
                        prefs.setDirectSwitch(v);
                    }
                }));
        sw.addView(switchRow("显示「新内容已保存」提示", "", prefs.savedTip(),
                new CompoundButton.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(CompoundButton b, boolean v) { prefs.setSavedTip(v); }
                }));
        sw.addView(switchRow("显示清空按钮", "", prefs.clearBtn(),
                new CompoundButton.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(CompoundButton b, boolean v) {
                        prefs.setClearBtn(v); host.onSettingsChanged();
                    }
                }));
        sw.addView(switchRow("空格键滑动移动光标", "按住空格左右滑动移动光标", prefs.spaceCursor(),
                new CompoundButton.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(CompoundButton b, boolean v) { prefs.setSpaceCursor(v); }
                }));
        sw.addView(switchRow("发送后自动收起键盘", "默认关闭，可连续发送", prefs.autoCollapse(),
                new CompoundButton.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(CompoundButton b, boolean v) { prefs.setAutoCollapse(v); }
                }));
        sw.addView(switchRow("连续复制（呼出时抓取剪贴板）", "每次呼出键盘把系统剪贴板新文字收入历史", prefs.continuous(),
                new CompoundButton.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(CompoundButton b, boolean v) { prefs.setContinuous(v); }
                }));
        body.addView(sw);

        body.addView(groupTitle("布局"));
        LinearLayout layout = card();
        layout.addView(stepperRow("键盘高度", prefs.heightDp() + " dp", new Runnable() {
            @Override public void run() {
                prefs.setHeightDp(prefs.heightDp() - 10);
                host.onSettingsChanged(); render();
            }
        }, new Runnable() {
            @Override public void run() {
                prefs.setHeightDp(prefs.heightDp() + 10);
                host.onSettingsChanged(); render();
            }
        }));
        final String[] colLabels = {"1 列", "2 列"};
        layout.addView(segmentRow("列表列数", colLabels, prefs.columns() - 1,
                new RadioGroup.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(RadioGroup g, int i) {
                        prefs.setColumns(i + 1); host.onSettingsChanged();
                    }
                }));
        final String[] alignVals = {"left", "center", "right"};
        int ai = 0;
        for (int i = 0; i < alignVals.length; i++) if (alignVals[i].equals(prefs.align())) ai = i;
        layout.addView(segmentRow("工具条按钮对齐", new String[]{"居左", "居中", "居右"}, ai,
                new RadioGroup.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(RadioGroup g, int i) {
                        prefs.setAlign(alignVals[i]); host.onSettingsChanged();
                    }
                }));
        body.addView(layout);

        body.addView(groupTitle("如何启用键盘"));
        LinearLayout steps = card();
        String[] ss = {"打开「设置」应用", "进入「系统 / 其他设置」→「语言和输入法」",
                "启用「墨指 同步键盘」", "在输入框点键盘切换图标选择它"};
        for (int i = 0; i < ss.length; i++) steps.addView(numberedRow(i + 1, ss[i]));
        body.addView(steps);

        body.addView(groupTitle("使用说明"));
        LinearLayout qa = card();
        qa.addView(qaRow("键盘里看不到同步记录？", "确认电脑服务已启动、同一 WiFi、地址正确，点工具条 ⟳ 立即同步。"));
        qa.addView(qaRow("密码框里没有 墨指？", "部分 App 的密码框会强制系统键盘，属系统限制。"));
        body.addView(qa);
    }

    private void renderSymbols() {
        body.addView(foot("工具条中间显示常用符号，点一下插入光标处。排在前面的优先显示，放不下的收进「⋯」面板。"));

        body.addView(groupTitle("工具条按钮对齐"));
        LinearLayout alignCard = card();
        final String[] vals = {"left", "center", "right"};
        int ai = 0;
        for (int i = 0; i < vals.length; i++) if (vals[i].equals(prefs.align())) ai = i;
        alignCard.addView(segmentRow("对齐方式", new String[]{"居左", "居中", "居右"}, ai,
                new RadioGroup.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(RadioGroup g, int i) {
                        prefs.setAlign(vals[i]); host.onSettingsChanged();
                    }
                }));
        alignCard.addView(info("键盘、地球、连续复制这三个按钮可整体居左、居中或居右。"));
        body.addView(alignCard);

        body.addView(groupTitle("当前符号（" + prefs.symbols().size() + "）"));
        LinearLayout list = card();
        final List<String> syms = new ArrayList<String>(prefs.symbols());
        for (int i = 0; i < syms.size(); i++) {
            list.addView(symbolRow(syms, i));
        }
        list.addView(addSymbolRow());
        body.addView(list);

        body.addView(groupTitle("工具条显示数量"));
        LinearLayout countCard = card();
        countCard.addView(segmentRow("显示数量", new String[]{"2 个", "3 个", "4 个", "5 个"},
                Math.max(0, Math.min(3, prefs.symbolCount() - 2)),
                new RadioGroup.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(RadioGroup g, int i) {
                        prefs.setSymbolCount(i + 2); host.onSettingsChanged();
                    }
                }));
        countCard.addView(info("空间不足时自动收起，最少保留两个。"));
        body.addView(countCard);

        body.addView(groupTitle("收起键盘键"));
        LinearLayout c1 = card();
        c1.addView(info("工具条左一：轻点收起键盘；长按 2 秒打开设置与菜单，菜单里可切换系统键盘。"));
        body.addView(c1);
        body.addView(groupTitle("剪贴板／常用语切换"));
        LinearLayout c2 = card();
        c2.addView(info("最右 ✕ 键：轻点删除光标前一个字；上滑清空文字；下滑恢复。长按 2 秒打开菜单。"));
        body.addView(c2);

        LinearLayout reset = card();
        reset.addView(actionRow("恢复默认符号", BLUE, new Runnable() {
            @Override public void run() {
                prefs.setSymbols(new ArrayList<String>(Arrays.asList("。", "，", "？", "！", "：")));
                prefs.setSymbolCount(4);
                prefs.setAlign("left");
                host.onSettingsChanged();
                host.onToast("已恢复默认符号");
                render();
            }
        }));
        body.addView(reset);
    }

    private void renderContinuous() {
        body.addView(foot("连续复制会在你复制新内容时自动保存到你选择的存储位置。"));
        body.addView(groupTitle("存储位置"));
        LinearLayout c = card();
        c.addView(segmentRow("存储位置", new String[]{"剪贴板历史", "常用语"},
                "常用语".equals(prefs.storage()) ? 1 : 0,
                new RadioGroup.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(RadioGroup g, int i) {
                        prefs.setStorage(i == 0 ? "剪贴板历史" : "常用语");
                    }
                }));
        c.addView(switchRow("启用连续复制（呼出时抓取）", "每次呼出键盘把系统剪贴板新文字收入历史",
                prefs.continuous(), new CompoundButton.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(CompoundButton b, boolean v) { prefs.setContinuous(v); }
                }));
        body.addView(c);

        body.addView(groupTitle("如何开启"));
        LinearLayout l = card();
        l.addView(numberedRow(1, "在任意 App 中切换到 墨指 同步键盘"));
        l.addView(numberedRow(2, "点工具条方块按钮 ⧉，变蓝即开启自动同步"));
        l.addView(numberedRow(3, "切回其他 App 继续复制，回到键盘即可看到记录"));
        body.addView(l);

        body.addView(groupTitle("补充说明"));
        LinearLayout q = card();
        q.addView(qaRow("相同内容会重复保存吗？", "不会，相同文字会去重处理。"));
        q.addView(qaRow("为什么有的内容没保存？", "安卓后台限制与复制速度可能影响保存，批量收集后请检查结果。"));
        q.addView(qaRow("多久会清理一次？", "按「历史保留时间」执行，置顶的记录不会被自动清理。"));
        body.addView(q);
        LinearLayout tryIt = card();
        tryIt.addView(actionRow("在键盘里试一下 →", BLUE, new Runnable() {
            @Override public void run() { close(); }
        }));
        body.addView(tryIt);
    }

    private void renderSync() {
        body.addView(groupTitle("连接状态"));
        LinearLayout st = card();
        st.addView(info("状态：" + host.statusTitle() + "　·　记录 " + host.statusCount() + " 条"));
        st.addView(info("后端：" + (host.backend().isEmpty() ? "—" : host.backend())));
        st.addView(info("当前地址：" + prefs.syncUrl()));
        body.addView(st);

        body.addView(groupTitle("电脑地址"));
        LinearLayout urlCard = card();
        urlField = new EditText(ctx);
        urlField.setText(prefs.syncUrl());
        urlField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        urlField.setTextSize(13);
        urlCard.addView(urlField, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        urlCard.addView(actionRow("保存地址并立即同步", BLUE, new Runnable() {
            @Override public void run() {
                prefs.setSyncUrl(urlField.getText().toString());
                host.onToast("已保存：" + prefs.syncUrl());
                host.onSyncNow(); render();
            }
        }));
        urlCard.addView(actionRow("📥 用剪贴板里的电脑地址", BLUE, new Runnable() {
            @Override public void run() {
                boolean ok = host.onAdoptUrl();
                host.onToast(ok ? "地址已更新：" + prefs.syncUrl() : "剪贴板里没有有效地址");
                if (ok) host.onSyncNow();
                render();
            }
        }));
        urlCard.addView(actionRow("↺ 重置为默认地址 192.168.1.2", BLUE, new Runnable() {
            @Override public void run() { host.onResetUrl(); host.onSyncNow(); render(); }
        }));
        body.addView(urlCard);

        body.addView(groupTitle("配对码（电脑端设了才填）"));
        LinearLayout pairCard = card();
        pairField = new EditText(ctx);
        pairField.setText(prefs.syncPair());
        pairField.setHint("可留空");
        pairField.setTextSize(13);
        pairCard.addView(pairField, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        pairCard.addView(actionRow("保存配对码", BLUE, new Runnable() {
            @Override public void run() {
                prefs.setSyncPair(pairField.getText().toString());
                host.onToast("配对码已保存"); host.onSyncNow();
            }
        }));
        body.addView(pairCard);

        body.addView(groupTitle("同步开关"));
        LinearLayout syncCard = card();
        syncCard.addView(switchRow("自动同步（每 3 秒）", "", prefs.syncAuto(),
                new CompoundButton.OnCheckedChangeListener() {
                    @Override public void onCheckedChanged(CompoundButton b, boolean v) {
                        prefs.setSyncAuto(v); host.onSettingsChanged();
                    }
                }));
        syncCard.addView(actionRow("⟳ 立即同步", BLUE, new Runnable() {
            @Override public void run() { host.onSyncNow(); host.onToast("正在同步…"); }
        }));
        body.addView(syncCard);

        body.addView(groupTitle("发送到电脑"));
        LinearLayout sendCard = card();
        sendCard.addView(actionRow("↑ 发送输入框文字", BLUE, new Runnable() {
            @Override public void run() { host.onSendInputText(); }
        }));
        sendCard.addView(actionRow("📋 发送剪贴板文字", BLUE, new Runnable() {
            @Override public void run() { host.onSendClipboardText(); }
        }));
        sendCard.addView(actionRow("🖼 发送剪贴板图片", BLUE, new Runnable() {
            @Override public void run() { host.onSendClipboardImage(); }
        }));
        sendCard.addView(actionRow("🗑 清空电脑上的全部同步记录", Color.parseColor("#FF3B30"),
                new Runnable() { @Override public void run() { host.onClearAll(); } }));
        body.addView(sendCard);
        body.addView(foot("电脑端需启动 墨指 同步服务（v1.8.22），手机与电脑连同一 WiFi。图片以 HTTP 二进制直传，不经公网。"));
    }

    private void renderTutorialList() {
        body.addView(foot("按最新原型的 6 篇使用教程，内容对应真输入法的实际操作。"));
        LinearLayout card = card();
        for (final String key : Tutorials.order()) {
            card.addView(navRow(Tutorials.title(key), "", "tut:" + key));
        }
        body.addView(card);
    }

    private void renderTutorial(String key) {
        LinearLayout sum = card();
        sum.addView(info(Tutorials.summary(key)));
        body.addView(sum);
        String[][] secs = Tutorials.sections(key);
        for (int i = 0; i < secs.length; i++) {
            body.addView(groupTitle((i + 1) + ". " + secs[i][0]));
            LinearLayout c = card();
            c.addView(info(secs[i][1]));
            body.addView(c);
        }
        LinearLayout tryIt = card();
        tryIt.addView(actionRow("在键盘里试一下 →", BLUE, new Runnable() {
            @Override public void run() { close(); }
        }));
        body.addView(tryIt);
    }

    private void renderHistory() {
        List<String> list = prefs.items("clip");
        body.addView(foot("本机剪贴板历史（最多 100 条）。点一条插入到当前输入框。"));
        LinearLayout c = card();
        if (list.isEmpty()) {
            c.addView(info("还没有记录。在别的 App 复制文字后，回到 墨指 键盘即可收录。"));
        } else {
            for (final String text : list) {
                c.addView(actionRow(text.length() > 40 ? text.substring(0, 40) : text,
                        Color.BLACK, new Runnable() {
                            @Override public void run() { host.onInsertText(text); close(); }
                        }));
            }
        }
        body.addView(c);
        LinearLayout ops = card();
        ops.addView(navRow("最近删除", prefs.recentDeleted().size() + " 条", "deleted"));
        ops.addView(actionRow("清除本机全部历史", Color.parseColor("#FF3B30"), "confirmClear"));
        body.addView(ops);
    }

    private void renderDeleted() {
        List<String> list = prefs.recentDeleted();
        LinearLayout c = card();
        if (list.isEmpty()) c.addView(info("最近删除是空的。"));
        else {
            for (final String text : list) {
                c.addView(actionRow("↺ " + (text.length() > 36 ? text.substring(0, 36) : text),
                        BLUE, new Runnable() {
                            @Override public void run() {
                                prefs.restore(text); host.onSettingsChanged();
                                host.onToast("已恢复"); render();
                            }
                        }));
            }
        }
        body.addView(c);
        if (!list.isEmpty()) {
            LinearLayout clr = card();
            clr.addView(actionRow("清空最近删除", Color.parseColor("#FF3B30"), new Runnable() {
                @Override public void run() {
                    prefs.setRecentDeleted(new ArrayList<String>()); render();
                }
            }));
            body.addView(clr);
        }
    }

    private void renderOnboarding() {
        body.addView(bigTitle("启用 墨指"));
        LinearLayout c = card();
        c.addView(numberedRow(1, "安装 APK（debug 签名，可直接安装）"));
        c.addView(numberedRow(2, "系统设置 → 语言和输入法 → 启用「墨指 同步键盘」"));
        c.addView(numberedRow(3, "在输入框点键盘切换图标，选择 墨指"));
        c.addView(numberedRow(4, "在主 App 填电脑地址 http://192.168.1.2:8787 并保存"));
        c.addView(numberedRow(5, "点键盘工具条「⋯」进入设置，检查同步状态"));
        body.addView(c);
        body.addView(foot("键盘里：点卡片直接上屏；💻 = 电脑复制，📱 = 手机发的；图片显示缩略图；蓝色「发送」把输入框文字发回电脑。"));
        LinearLayout go = card();
        go.addView(actionRow("开始使用 →", BLUE, new Runnable() {
            @Override public void run() { close(); }
        }));
        body.addView(go);
    }

    private void renderAbout() {
        LinearLayout c = card();
        c.addView(info("墨指 v1.8.22 · 真·系统输入法"));
        c.addView(info("安卓：系统输入法 InputMethodService（BIND_INPUT_METHOD）"));
        c.addView(info("iOS：键盘扩展 .appex（com.apple.keyboard-service）"));
        c.addView(info("界面按 最新版原型原生实现，无 WebView、无演示动画。"));
        c.addView(info("数据只在你的局域网内传输，不经过公网。"));
        body.addView(c);
    }

    private void renderConfirmClear() {
        LinearLayout c = card();
        c.addView(info("将清空本机剪贴板历史与最近删除，并删除电脑上的全部同步记录。此操作不可撤销。"));
        body.addView(c);
        LinearLayout ops = card();
        ops.addView(actionRow("确认清除", Color.parseColor("#FF3B30"), new Runnable() {
            @Override public void run() {
                prefs.clearClips();
                prefs.setRecentDeleted(new ArrayList<String>());
                host.onClearAll(); host.onSettingsChanged();
                host.onToast("历史已清除"); back();
            }
        }));
        ops.addView(actionRow("取消", BLUE, new Runnable() {
            @Override public void run() { back(); }
        }));
        body.addView(ops);
    }

    // ---------------- 通用行组件 ----------------

    private TextView bigTitle(String text) {
        TextView t = new TextView(ctx);
        t.setText(text); t.setTextSize(22); t.setTextColor(Color.BLACK);
        t.getPaint().setFakeBoldText(true);
        t.setPadding(0, dp(4), 0, dp(8));
        return t;
    }

    private TextView groupTitle(String text) {
        TextView t = new TextView(ctx);
        t.setText(text); t.setTextSize(12); t.setTextColor(SUB);
        t.setPadding(dp(2), dp(10), 0, dp(3));
        return t;
    }

    private TextView foot(String text) {
        TextView t = new TextView(ctx);
        t.setText(text); t.setTextSize(11); t.setTextColor(SUB);
        t.setPadding(dp(2), dp(3), dp(2), dp(6));
        return t;
    }

    private LinearLayout card() {
        LinearLayout box = new LinearLayout(ctx);
        box.setOrientation(LinearLayout.VERTICAL);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(CARD); gd.setCornerRadius(dp(10));
        box.setBackground(gd);
        box.setPadding(0, dp(3), 0, dp(3));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, 0, 0, dp(2));
        box.setLayoutParams(lp);
        return box;
    }

    private View navRow(final String title, String value, final String page) {
        LinearLayout row = rowBase();
        TextView l = new TextView(ctx);
        l.setText(title); l.setTextSize(14); l.setTextColor(Color.BLACK);
        row.addView(l, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        if (value != null && !value.isEmpty()) {
            TextView v = new TextView(ctx);
            v.setText(value); v.setTextSize(12); v.setTextColor(SUB);
            row.addView(v);
        }
        TextView chev = new TextView(ctx);
        chev.setText("›"); chev.setTextSize(18); chev.setTextColor(SUB);
        row.addView(chev);
        row.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { push(page); }
        });
        return row;
    }

    private View actionRow(String title, final int color, final String page) {
        return actionRow(title, color, new Runnable() {
            @Override public void run() { push(page); }
        });
    }

    private View actionRow(String title, int color, final Runnable action) {
        TextView b = new TextView(ctx);
        b.setText(title); b.setTextSize(14); b.setTextColor(color);
        b.setPadding(dp(14), dp(11), dp(14), dp(11));
        b.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { action.run(); }
        });
        return b;
    }

    private View switchRow(String title, String sub, boolean on,
                           CompoundButton.OnCheckedChangeListener listener) {
        LinearLayout row = rowBase();
        LinearLayout texts = new LinearLayout(ctx);
        texts.setOrientation(LinearLayout.VERTICAL);
        TextView l = new TextView(ctx);
        l.setText(title); l.setTextSize(14); l.setTextColor(Color.BLACK);
        texts.addView(l);
        if (sub != null && !sub.isEmpty()) {
            TextView s = new TextView(ctx);
            s.setText(sub); s.setTextSize(11); s.setTextColor(SUB);
            texts.addView(s);
        }
        row.addView(texts, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Switch sw = new Switch(ctx);
        sw.setChecked(on);
        sw.setOnCheckedChangeListener(listener);
        row.addView(sw);
        return row;
    }

    private View stepperRow(String title, String value,
                            final Runnable minus, final Runnable plus) {
        LinearLayout row = rowBase();
        TextView l = new TextView(ctx);
        l.setText(title); l.setTextSize(14); l.setTextColor(Color.BLACK);
        row.addView(l, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        TextView v = new TextView(ctx);
        v.setText(value); v.setTextSize(14); v.setTextColor(BLUE);
        row.addView(v);
        TextView m = plainButton("−");
        row.addView(m, new LinearLayout.LayoutParams(dp(40), dp(36)));
        m.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { minus.run(); }
        });
        TextView p = plainButton("+");
        row.addView(p, new LinearLayout.LayoutParams(dp(40), dp(36)));
        p.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { plus.run(); }
        });
        return row;
    }

    private View segmentRow(String title, String[] labels, int selected,
                            final RadioGroup.OnCheckedChangeListener listener) {
        LinearLayout box = new LinearLayout(ctx);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(14), dp(8), dp(14), dp(8));
        TextView l = new TextView(ctx);
        l.setText(title); l.setTextSize(14); l.setTextColor(Color.BLACK);
        box.addView(l);
        RadioGroup rg = new RadioGroup(ctx);
        rg.setOrientation(RadioGroup.HORIZONTAL);
        for (int i = 0; i < labels.length; i++) {
            RadioButton rb = new RadioButton(ctx);
            // id 从 1 开始：RadioGroup.check(0) 会被当成 NO_ID
            rb.setId(i + 1);
            rb.setText(labels[i]);
            rb.setTextSize(12);
            rb.setPadding(dp(2), 0, dp(10), 0);
            rg.addView(rb);
        }
        if (selected >= 0 && selected < labels.length) rg.check(selected + 1);
        rg.setOnCheckedChangeListener(new RadioGroup.OnCheckedChangeListener() {
            @Override public void onCheckedChanged(RadioGroup group, int checkedId) {
                if (checkedId > 0) listener.onCheckedChanged(group, checkedId - 1);
            }
        });
        box.addView(rg);
        return box;
    }

    private View info(String text) {
        TextView t = new TextView(ctx);
        t.setText(text); t.setTextSize(12); t.setTextColor(Color.BLACK);
        t.setPadding(dp(14), dp(9), dp(14), dp(9));
        return t;
    }

    private View numberedRow(int n, String text) {
        LinearLayout row = new LinearLayout(ctx);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(dp(14), dp(8), dp(14), dp(8));
        TextView badge = new TextView(ctx);
        badge.setText(String.valueOf(n));
        badge.setTextSize(12); badge.setTextColor(Color.WHITE);
        badge.setGravity(Gravity.CENTER);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(BLUE); gd.setCornerRadius(dp(10));
        badge.setBackground(gd);
        row.addView(badge, new LinearLayout.LayoutParams(dp(20), dp(20)));
        TextView t = new TextView(ctx);
        t.setText(text); t.setTextSize(13); t.setTextColor(Color.BLACK);
        t.setPadding(dp(10), 0, 0, 0);
        row.addView(t, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return row;
    }

    private View qaRow(String q, String a) {
        LinearLayout box = new LinearLayout(ctx);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(14), dp(9), dp(14), dp(9));
        TextView ql = new TextView(ctx);
        ql.setText("问：" + q); ql.setTextSize(12); ql.setTextColor(Color.BLACK);
        ql.getPaint().setFakeBoldText(true);
        box.addView(ql);
        TextView al = new TextView(ctx);
        al.setText("答：" + a); al.setTextSize(12); al.setTextColor(SUB);
        box.addView(al);
        return box;
    }

    private View symbolRow(final List<String> syms, final int i) {
        LinearLayout row = rowBase();
        TextView idx = new TextView(ctx);
        idx.setText(String.valueOf(i + 1)); idx.setTextSize(12); idx.setTextColor(SUB);
        idx.setWidth(dp(22));
        row.addView(idx);
        TextView ch = new TextView(ctx);
        ch.setText(syms.get(i)); ch.setTextSize(17); ch.setTextColor(Color.BLACK);
        row.addView(ch);
        View grow = new View(ctx);
        row.addView(grow, new LinearLayout.LayoutParams(0, 1, 1f));
        row.addView(miniButton("↑", i > 0, new Runnable() {
            @Override public void run() {
                List<String> a = new ArrayList<String>(syms);
                java.util.Collections.swap(a, i, i - 1);
                prefs.setSymbols(a); host.onSettingsChanged(); render();
            }
        }));
        row.addView(miniButton("↓", i < syms.size() - 1, new Runnable() {
            @Override public void run() {
                List<String> a = new ArrayList<String>(syms);
                java.util.Collections.swap(a, i, i + 1);
                prefs.setSymbols(a); host.onSettingsChanged(); render();
            }
        }));
        row.addView(miniButton("✕", syms.size() > 1, new Runnable() {
            @Override public void run() {
                List<String> a = new ArrayList<String>(syms);
                a.remove(i);
                prefs.setSymbols(a); host.onSettingsChanged(); render();
            }
        }));
        return row;
    }

    private View addSymbolRow() {
        LinearLayout row = rowBase();
        symbolField = new EditText(ctx);
        symbolField.setHint("输入要添加的符号");
        symbolField.setTextSize(13);
        row.addView(symbolField, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        TextView add = plainButton("添加");
        add.setTextColor(BLUE);
        row.addView(add, new LinearLayout.LayoutParams(dp(52), dp(36)));
        add.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                String s = symbolField.getText().toString().trim();
                if (s.isEmpty()) return;
                List<String> a = new ArrayList<String>(prefs.symbols());
                a.add(s.length() > 4 ? s.substring(0, 4) : s);
                prefs.setSymbols(a);
                host.onSettingsChanged();
                host.onToast("已添加 " + s);
                render();
            }
        });
        return row;
    }

    private TextView miniButton(String title, boolean enabled, final Runnable action) {
        TextView b = new TextView(ctx);
        b.setText(title); b.setTextSize(14); b.setGravity(Gravity.CENTER);
        b.setTextColor("✕".equals(title) ? Color.parseColor("#FF3B30") : BLUE);
        b.setEnabled(enabled);
        b.setAlpha(enabled ? 1f : 0.3f);
        b.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { action.run(); }
        });
        return b;
    }

    private LinearLayout rowBase() {
        LinearLayout row = new LinearLayout(ctx);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(dp(14), dp(8), dp(10), dp(8));
        row.setMinimumHeight(dp(38));
        return row;
    }

    private Button plainButton(String text) {
        Button b = new Button(ctx);
        b.setText(text);
        b.setTextSize(14);
        b.setTextColor(BLUE);
        b.setBackgroundColor(Color.TRANSPARENT);
        b.setAllCaps(false);
        b.setPadding(0, 0, 0, 0);
        return b;
    }

    private int dp(int v) {
        return (int) (v * ctx.getResources().getDisplayMetrics().density + 0.5f);
    }
}
