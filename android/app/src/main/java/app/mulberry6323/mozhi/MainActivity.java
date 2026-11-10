package app.mulberry6323.mozhi;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;

/**
 * 主 App：输入法启用引导 + v1.6 局域网同步设置。
 * 界面按 quickpaste-ios-prototype.html 的「局域网同步」设置页组织。
 * 与键盘同进程共享 SharedPreferences，不需要任何额外权限或 entitlement。
 */
public class MainActivity extends Activity {

    private static final int BG = Color.parseColor("#F3F4F9");
    private static final int CARD = Color.WHITE;
    private static final int BLUE = Color.parseColor("#0A7CFF");
    private static final int GREEN = Color.parseColor("#34C759");
    private static final int TEXT = Color.parseColor("#000000");
    private static final int SUB = Color.parseColor("#8A8A8F");

    private Prefs prefs;
    private LinearLayout page;
    private EditText urlEdit;
    private EditText pairEdit;
    private EditText phrasesEdit;
    private TextView statusLabel;
    private TextView connLabel;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = new Prefs(this);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(BG);
        page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setPadding(dp(16), dp(18), dp(16), dp(36));
        scroll.addView(page, new ScrollView.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        setContentView(scroll);

        TextView title = new TextView(this);
        title.setText("墨指 同步键盘");
        title.setTextSize(26);
        title.setTextColor(TEXT);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        page.addView(title);
        TextView sub = label("v1.8.19 · 真·系统输入法 · 电脑 ↔ 手机 局域网剪贴板");
        sub.setTextSize(13);
        page.addView(sub);
        page.addView(spacer(10));

        // ---- 连接状态 ----
        page.addView(cardBegin("连接状态"));
        connLabel = label("正在检测…");
        connLabel.setTextSize(14);
        page.addView(connLabel);
        page.addView(cardEnd());
        page.addView(spacer(10));

        // ---- 连接设置 ----
        page.addView(cardBegin("局域网同步（CopyQ）"));
        page.addView(field("电脑地址"));
        urlEdit = input(prefs.syncUrl(), InputType.TYPE_TEXT_VARIATION_URI);
        page.addView(urlEdit);
        page.addView(label("例：http://192.168.1.2:8787　（电脑上打开 /api/status 可看 lanIPs）"));
        page.addView(field("配对码（可留空）"));
        pairEdit = input(prefs.syncPair(), InputType.TYPE_CLASS_TEXT);
        page.addView(pairEdit);
        LinearLayout btns = new LinearLayout(this);
        btns.setOrientation(LinearLayout.HORIZONTAL);
        Button save = new Button(this);
        save.setText("保存并测试");
        save.setAllCaps(false);
        save.setTextColor(Color.WHITE);
        GradientDrawable sg = new GradientDrawable();
        sg.setColor(BLUE);
        sg.setCornerRadius(dp(10));
        save.setBackground(sg);
        save.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                prefs.setSyncUrl(urlEdit.getText().toString());
                prefs.setSyncPair(pairEdit.getText().toString());
                toast("已保存，键盘会自动读取");
                testConnection();
            }
        });
        btns.addView(save, new LinearLayout.LayoutParams(0, dp(42), 1f));
        Button test = new Button(this);
        test.setText("仅测试");
        test.setAllCaps(false);
        test.setTextColor(BLUE);
        test.setBackground(roundBg(CARD, 10));
        test.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                testConnection();
            }
        });
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(0, dp(42), 1f);
        tlp.setMargins(dp(8), 0, 0, 0);
        btns.addView(test, tlp);
        page.addView(btns, lpMatch());
        page.addView(cardEnd());
        page.addView(spacer(10));

        // ---- 启用键盘 ----
        page.addView(cardBegin("1. 启用输入法"));
        statusLabel = label("");
        page.addView(statusLabel);
        page.addView(button("打开系统「键盘与输入法」设置", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS));
                } catch (Exception e) {
                    toast("请手动打开系统设置 → 系统 → 语言与输入法");
                }
            }
        }));
        page.addView(button("直接弹出「选择输入法」", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                if (imm != null) imm.showInputMethodPicker();
            }
        }));
        page.addView(label("勾选「墨指 同步键盘」，在任意输入框长按 → 选择输入法即可切换。"));
        page.addView(field("立即测试（切到 墨指 键盘后使用）"));
        EditText testInput = new EditText(this);
        testInput.setHint("点这里输入，键盘里的同步条目点一下就会插到这里");
        testInput.setMinLines(2);
        testInput.setGravity(Gravity.TOP);
        testInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        testInput.setBackground(roundBg(CARD, 10));
        testInput.setPadding(dp(12), dp(10), dp(12), dp(10));
        testInput.setTextColor(TEXT);
        page.addView(testInput, lpMatch());
        page.addView(cardEnd());
        page.addView(spacer(10));

        // ---- 常用语 ----
        page.addView(cardBegin("2. 常用语（每行一条，键盘里可切换）"));
        phrasesEdit = new EditText(this);
        phrasesEdit.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        phrasesEdit.setGravity(Gravity.TOP);
        phrasesEdit.setMinLines(4);
        phrasesEdit.setBackground(roundBg(CARD, 10));
        phrasesEdit.setPadding(dp(12), dp(10), dp(12), dp(10));
        phrasesEdit.setText(joinLines(prefs.phrases()));
        page.addView(phrasesEdit, lpMatch());
        page.addView(button("保存常用语", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                prefs.setPhrases(splitLines(phrasesEdit.getText().toString()));
                toast("已保存，键盘会自动读取");
            }
        }));
        page.addView(cardEnd());
        page.addView(spacer(10));

        // ---- 开关 ----
        page.addView(cardBegin("3. 键盘设置"));
        page.addView(check("自动同步（每 3 秒拉取电脑剪贴板）", prefs.syncAuto(),
                new android.widget.CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(android.widget.CompoundButton b, boolean on) {
                        prefs.setSyncAuto(on);
                    }
                }));
        page.addView(check("剪贴板卡片两列显示", prefs.columns() == 2,
                new android.widget.CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(android.widget.CompoundButton b, boolean on) {
                        prefs.setColumns(on ? 2 : 1);
                    }
                }));
        page.addView(check("空格键左右滑动移光标", prefs.spaceCursor(),
                new android.widget.CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(android.widget.CompoundButton b, boolean on) {
                        prefs.setSpaceCursor(on);
                    }
                }));
        page.addView(check("点条目后自动收起键盘", prefs.autoCollapse(),
                new android.widget.CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(android.widget.CompoundButton b, boolean on) {
                        prefs.setAutoCollapse(on);
                    }
                }));
        page.addView(cardEnd());
        page.addView(spacer(10));

        // ---- 说明 ----
        page.addView(cardBegin("怎么用"));
        page.addView(label(
                "· 电脑端 墨指 同步服务保持开启，手机与电脑连同一 WiFi\n"
                        + "· 在任意 App 的输入框切到 墨指 同步键盘\n"
                        + "· 电脑复制的文字/截图会出现在键盘卡片里，点一下直接上屏\n"
                        + "· 💻 = 电脑复制，📱 = 手机发的；图片卡片显示缩略图\n"
                        + "· 底行蓝色「发送」把当前输入框文字发回电脑，电脑 Ctrl+V 可粘贴\n"
                        + "· 长按卡片：放大图片 / 复制 / 发送到电脑 / 删除\n"
                        + "· 长按工具条 ⧉ 或 ⋯ 打开菜单：发送剪贴板文字或图片、改设置\n"
                        + "· ✕ 轻点退格、上滑清空输入框、下滑恢复；🌐 切换系统键盘\n"
                        + "· ƒ(x) 是计算器，算完点「输入」把结果插进输入框"));
        page.addView(spacer(6));
        page.addView(label(
                "数据只在同一 WiFi 内传输，不经过公网。密码框等敏感输入系统会强制切回原生键盘。"
                        + "电脑 IP 由路由器分配，重连 WiFi 后可能变化，改这里保存一次即可。"));
        page.addView(cardEnd());

        refreshStatus();
        testConnection();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshStatus();
    }

    private void testConnection() {
        connLabel.setTextColor(SUB);
        connLabel.setText("正在连接 " + prefs.syncUrl() + " …");
        final SyncClient c = new SyncClient(prefs.syncUrl(), prefs.syncPair());
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    final SyncClient.Result r = c.fetch(1);
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            connLabel.setTextColor(GREEN);
                            connLabel.setText("✔ 已连接 · 共 " + r.count + " 条 · 后端 "
                                    + (r.backend.isEmpty() ? "服务内存" : r.backend));
                        }
                    });
                } catch (final Exception e) {
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            connLabel.setTextColor(Color.parseColor("#FF3B30"));
                            connLabel.setText("✘ 连接失败：" + e.getMessage()
                                    + "\n请确认电脑服务已启动、同一 WiFi、地址正确");
                        }
                    });
                }
            }
        }).start();
    }

    private void refreshStatus() {
        boolean enabled = false;
        try {
            InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) {
                for (InputMethodInfo info : imm.getEnabledInputMethodList()) {
                    if (getPackageName().equals(info.getPackageName())) {
                        enabled = true;
                        break;
                    }
                }
            }
        } catch (Exception ignored) {
        }
        String current = null;
        try {
            current = Settings.Secure.getString(getContentResolver(),
                    Settings.Secure.DEFAULT_INPUT_METHOD);
        } catch (Exception ignored) {
        }
        boolean isDefault = current != null && current.contains(getPackageName());
        if (isDefault) {
            statusLabel.setText("状态：已启用，且已是当前输入法 ✔");
            statusLabel.setTextColor(GREEN);
        } else if (enabled) {
            statusLabel.setText("状态：已启用，但还不是当前输入法（点下面按钮切换）");
            statusLabel.setTextColor(BLUE);
        } else {
            statusLabel.setText("状态：尚未启用，请先到系统设置里勾选「墨指 同步键盘」");
            statusLabel.setTextColor(BLUE);
        }
    }

    // ---- UI 辅助 ----

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }

    private LinearLayout.LayoutParams lpMatch() {
        return new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    private View spacer(int h) {
        View v = new View(this);
        v.setLayoutParams(new LinearLayout.LayoutParams(1, dp(h)));
        return v;
    }

    private TextView cardBegin(String title) {
        TextView tv = new TextView(this);
        tv.setText(title);
        tv.setTextSize(15);
        tv.setTextColor(TEXT);
        tv.setTypeface(Typeface.DEFAULT_BOLD);
        tv.setPadding(dp(14), dp(10), dp(14), dp(6));
        tv.setBackground(roundBg(CARD, 14));
        return tv;
    }

    private View cardEnd() {
        View v = new View(this);
        v.setLayoutParams(new LinearLayout.LayoutParams(1, dp(10)));
        return v;
    }

    private TextView field(String text) {
        TextView tv = label(text);
        tv.setPadding(dp(14), dp(6), dp(14), dp(2));
        return tv;
    }

    private TextView label(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(13);
        tv.setTextColor(SUB);
        tv.setPadding(dp(14), dp(3), dp(14), dp(3));
        return tv;
    }

    private EditText input(String value, int inputType) {
        EditText et = new EditText(this);
        et.setInputType(inputType);
        et.setText(value);
        et.setSelection(et.getText().length());
        et.setTextSize(14);
        et.setTextColor(TEXT);
        et.setBackground(roundBg(CARD, 10));
        et.setPadding(dp(12), dp(10), dp(12), dp(10));
        LinearLayout.LayoutParams p = lpMatch();
        p.setMargins(dp(14), dp(2), dp(14), dp(6));
        et.setLayoutParams(p);
        return et;
    }

    private Button button(String text, View.OnClickListener listener) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextColor(BLUE);
        b.setTextSize(14);
        b.setBackground(roundBg(CARD, 10));
        b.setOnClickListener(listener);
        LinearLayout.LayoutParams p = lpMatch();
        p.setMargins(dp(14), dp(4), dp(14), dp(4));
        b.setLayoutParams(p);
        return b;
    }

    private CheckBox check(String text, boolean checked,
                           android.widget.CompoundButton.OnCheckedChangeListener listener) {
        CheckBox cb = new CheckBox(this);
        cb.setText(text);
        cb.setTextSize(13);
        cb.setTextColor(TEXT);
        cb.setChecked(checked);
        cb.setOnCheckedChangeListener(listener);
        cb.setPadding(dp(14), dp(4), dp(14), dp(4));
        return cb;
    }

    private GradientDrawable roundBg(int color, int radiusDp) {
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(color);
        gd.setCornerRadius(dp(radiusDp));
        return gd;
    }

    private static String joinLines(List<String> items) {
        StringBuilder sb = new StringBuilder();
        for (String s : items) {
            if (sb.length() > 0) sb.append('\n');
            sb.append(s);
        }
        return sb.toString();
    }

    private static List<String> splitLines(String raw) {
        List<String> out = new ArrayList<String>();
        for (String line : raw.split("\\n")) {
            String s = line.trim();
            if (!s.isEmpty()) out.add(s);
        }
        return out;
    }

    private void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_SHORT).show();
    }
}
