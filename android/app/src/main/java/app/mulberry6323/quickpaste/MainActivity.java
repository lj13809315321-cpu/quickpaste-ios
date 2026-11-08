package app.mulberry6323.quickpaste;

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

/** 主应用：启用引导、常用语编辑、剪贴板历史、开关设置与功能说明。 */
public class MainActivity extends Activity {

    private Prefs prefs;
    private LinearLayout page;
    private EditText phrasesEdit;
    private TextView clipSummary;
    private TextView statusLabel;

    private static final int BG = Color.parseColor("#F5F5F9");
    private static final int CARD = Color.WHITE;
    private static final int TEXT = Color.parseColor("#1C1C1E");
    private static final int MUTED = Color.parseColor("#6B6B72");
    private static final int BLUE = Color.parseColor("#0A7CFF");

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = new Prefs(this);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(BG);
        page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setPadding(dp(16), dp(20), dp(16), dp(32));
        scroll.addView(page, new ScrollView.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        setContentView(scroll);

        TextView title = new TextView(this);
        title.setText("QuickPaste");
        title.setTextSize(26);
        title.setTextColor(TEXT);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        page.addView(title);
        TextView sub = label("剪贴板 · 常用语 · 计算器键盘（安卓版）");
        sub.setTextSize(13);
        page.addView(sub);
        page.addView(spacer(14));

        // ---- 启用键盘 ----
        page.addView(section("1. 启用键盘"));
        statusLabel = label("");
        page.addView(statusLabel);
        page.addView(button("打开系统「键盘与输入法」设置", v -> {
            try {
                startActivity(new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS));
            } catch (Exception e) {
                toast("请手动打开系统设置 → 系统 → 语言与输入法");
            }
        }));
        page.addView(button("直接弹出「选择输入法」", v -> {
            InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.showInputMethodPicker();
        }));
        page.addView(label("在列表里勾选「QuickPaste 键盘」，回到任一输入框长按 → 选择输入法即可切换。"));
        page.addView(spacer(8));

        // ---- 立即测试 ----
        page.addView(section("2. 立即测试"));
        page.addView(label("点下面这个输入框，切到 QuickPaste 键盘后就能直接试功能："));
        EditText test = new EditText(this);
        test.setHint("在这里输入，试试点常用语 / 剪贴板 / 计算器");
        test.setMinLines(2);
        test.setGravity(Gravity.TOP);
        test.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        test.setBackgroundColor(CARD);
        test.setPadding(dp(12), dp(10), dp(12), dp(10));
        test.setTextColor(TEXT);
        test.setHintTextColor(MUTED);
        page.addView(test, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        page.addView(spacer(8));

        // ---- 常用语 ----
        page.addView(section("3. 常用语（每行一条）"));
        phrasesEdit = new EditText(this);
        phrasesEdit.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        phrasesEdit.setGravity(Gravity.TOP);
        phrasesEdit.setMinLines(4);
        phrasesEdit.setBackgroundColor(CARD);
        phrasesEdit.setPadding(dp(12), dp(10), dp(12), dp(10));
        phrasesEdit.setTextColor(TEXT);
        phrasesEdit.setText(joinLines(prefs.phrases()));
        page.addView(phrasesEdit, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        page.addView(button("保存常用语", v -> {
            prefs.setPhrases(splitLines(phrasesEdit.getText().toString()));
            toast("常用语已保存，键盘会自动读取");
        }));
        page.addView(spacer(8));

        // ---- 剪贴板历史 ----
        page.addView(section("4. 剪贴板记录"));
        clipSummary = label("");
        page.addView(clipSummary);
        page.addView(button("清空剪贴板记录", v -> {
            prefs.clearClips();
            refreshClipSummary();
            toast("已清空");
        }));
        page.addView(label("键盘里点「⧉」开启连续复制后，会自动记录你复制的文字（最多 30 条）。"));
        page.addView(spacer(8));

        // ---- 开关 ----
        page.addView(section("5. 键盘设置"));
        page.addView(check("连续复制（自动记录剪贴板）", prefs.continuousCopy(),
                (b, on) -> prefs.setContinuousCopy(on)));
        page.addView(check("列表两列显示", prefs.columns() == 2,
                (b, on) -> prefs.setColumns(on ? 2 : 1)));
        page.addView(check("空格键左右滑动移光标", prefs.spaceCursor(),
                (b, on) -> prefs.setSpaceCursor(on)));
        page.addView(check("发送后自动收起键盘", prefs.autoCollapse(),
                (b, on) -> prefs.setAutoCollapse(on)));
        page.addView(spacer(8));

        // ---- 操作说明 ----
        page.addView(section("键盘操作"));
        page.addView(label("· 顶部「剪贴板 / 常用语」切换；点一条即插入到光标处\n"
                + "· 长按一条：置顶 / 删除\n"
                + "· ✕ 轻点退格，上滑清空输入框，下滑恢复\n"
                + "· ⌄ 轻点收起键盘，长按打开键盘内设置菜单\n"
                + "· ⧉ 蓝色为连续复制已开启\n"
                + "· ƒ(x) 打开计算器，算完点「输入」把结果插进输入框\n"
                + "· 🌐 切换到下一个输入法"));
        page.addView(spacer(8));
        page.addView(section("说明"));
        page.addView(label("安卓版与 iOS 版功能一致，数据存在本机，不联网、不上传。"
                + "剪贴板读取在系统限制下仅当键盘显示时可用；"
                + "密码框等敏感输入系统会强制使用原生键盘。"));

        refreshClipSummary();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshStatus();
        refreshClipSummary();
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
        String text;
        if (isDefault) {
            text = "状态：已启用，且已是当前输入法 ✔";
        } else if (enabled) {
            text = "状态：已启用，但还不是当前输入法（点下面按钮切换）";
        } else {
            text = "状态：尚未启用，请先到系统设置里勾选「QuickPaste 键盘」";
        }
        statusLabel.setText(text);
        statusLabel.setTextColor(isDefault ? Color.parseColor("#1B8A3A") : BLUE);
    }

    private void refreshClipSummary() {
        int n = prefs.clips().size();
        clipSummary.setText(n == 0 ? "暂无记录" : "已记录 " + n + " 条（最新在最前）");
    }

    // ---- UI 辅助 ----

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }

    private View spacer(int h) {
        View v = new View(this);
        v.setLayoutParams(new LinearLayout.LayoutParams(1, dp(h)));
        return v;
    }

    private TextView section(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(16);
        tv.setTextColor(TEXT);
        tv.setTypeface(Typeface.DEFAULT_BOLD);
        tv.setPadding(0, dp(12), 0, dp(4));
        return tv;
    }

    private TextView label(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(13);
        tv.setTextColor(MUTED);
        tv.setPadding(0, dp(3), 0, dp(3));
        return tv;
    }

    private Button button(String text, View.OnClickListener listener) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextColor(BLUE);
        b.setTextSize(14);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(CARD);
        gd.setCornerRadius(dp(10));
        b.setBackground(gd);
        b.setOnClickListener(listener);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(44));
        lp.setMargins(0, dp(4), 0, dp(4));
        b.setLayoutParams(lp);
        return b;
    }

    private CheckBox check(String text, boolean checked,
                           android.widget.CompoundButton.OnCheckedChangeListener listener) {
        CheckBox cb = new CheckBox(this);
        cb.setText(text);
        cb.setTextSize(14);
        cb.setTextColor(TEXT);
        cb.setChecked(checked);
        cb.setOnCheckedChangeListener(listener);
        return cb;
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
        List<String> out = new ArrayList<>();
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
