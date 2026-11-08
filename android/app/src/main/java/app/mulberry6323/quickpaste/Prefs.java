package app.mulberry6323.quickpaste;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * 键盘的全部本地状态。安卓上 Activity 与输入法服务默认同进程、共享
 * SharedPreferences，因此不需要 iOS 那边的 App Group / 通配符描述文件。
 */
public final class Prefs {

    private static final String FILE = "qp";
    private final SharedPreferences sp;

    public Prefs(Context ctx) {
        sp = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    private static int clamp(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    // ---- 布局 ----

    public int columns() {
        return clamp(sp.getInt("qp.columns", 1), 1, 2);
    }

    public void setColumns(int v) {
        sp.edit().putInt("qp.columns", clamp(v, 1, 2)).apply();
    }

    public int heightDp() {
        return clamp(sp.getInt("qp.height", 260), 200, 320);
    }

    public void setHeightDp(int v) {
        sp.edit().putInt("qp.height", clamp(v, 200, 320)).apply();
    }

    // ---- 交互开关 ----

    public boolean spaceCursor() {
        return sp.getBoolean("qp.spaceCursor", true);
    }

    public void setSpaceCursor(boolean v) {
        sp.edit().putBoolean("qp.spaceCursor", v).apply();
    }

    public boolean continuousCopy() {
        return sp.getBoolean("qp.continuous", false);
    }

    public void setContinuousCopy(boolean v) {
        sp.edit().putBoolean("qp.continuous", v).apply();
    }

    public boolean autoCollapse() {
        return sp.getBoolean("qp.autoCollapse", false);
    }

    public void setAutoCollapse(boolean v) {
        sp.edit().putBoolean("qp.autoCollapse", v).apply();
    }

    // ---- 内容 ----

    public String tab() {
        return sp.getString("qp.tab", "clip");
    }

    public void setTab(String v) {
        sp.edit().putString("qp.tab", v).apply();
    }

    public List<String> symbols() {
        List<String> saved = getList("qp.symbols");
        if (saved.isEmpty()) {
            return new ArrayList<>(Arrays.asList("。", "，", "？", "！", "："));
        }
        return saved;
    }

    public int symbolCount() {
        return clamp(sp.getInt("qp.symbolCount", 4), 2, 5);
    }

    public List<String> phrases() {
        List<String> saved = getList("qp.phrases");
        if (saved.isEmpty()) {
            return new ArrayList<>(Arrays.asList(
                    "好的，收到", "稍后回复你", "谢谢！", "地址：", "明天上午方便吗"));
        }
        return saved;
    }

    public void setPhrases(List<String> v) {
        setList("qp.phrases", v);
    }

    public List<String> clips() {
        return getList("qp.clips");
    }

    public List<String> pinned() {
        return getList("qp.pinned");
    }

    public void clearClips() {
        setList("qp.clips", new ArrayList<String>());
    }

    /** 把当前剪贴板文字记入历史；重复内容只保留最新一条，最多 30 条。 */
    public boolean capture(String text) {
        if (text == null) return false;
        String t = text.trim();
        if (t.isEmpty()) return false;
        List<String> history = new ArrayList<>(clips());
        if (!history.isEmpty() && history.get(0).equals(t)) return false;
        for (int i = history.size() - 1; i >= 0; i--) {
            if (history.get(i).equals(t)) history.remove(i);
        }
        history.add(0, t);
        if (history.size() > 30) history = new ArrayList<>(history.subList(0, 30));
        setList("qp.clips", history);
        return true;
    }

    /** 当前 Tab 要显示的内容：置顶项排在前面。 */
    public List<String> items(String tab) {
        List<String> all = "phrase".equals(tab) ? phrases() : clips();
        List<String> pin = pinned();
        List<String> out = new ArrayList<>();
        for (String p : pin) if (all.contains(p)) out.add(p);
        for (String s : all) if (!pin.contains(s)) out.add(s);
        return out;
    }

    public void remove(String text, String tab) {
        List<String> all = new ArrayList<>("phrase".equals(tab) ? phrases() : clips());
        all.remove(text);
        if ("phrase".equals(tab)) setPhrases(all);
        else setList("qp.clips", all);
        List<String> pin = new ArrayList<>(pinned());
        pin.remove(text);
        setList("qp.pinned", pin);
    }

    public void togglePin(String text) {
        List<String> pin = new ArrayList<>(pinned());
        if (pin.contains(text)) pin.remove(text);
        else pin.add(text);
        setList("qp.pinned", pin);
    }

    // ---- JSON 序列化（org.json 为 Android 内置，无需第三方依赖）----

    private List<String> getList(String key) {
        List<String> out = new ArrayList<>();
        String raw = sp.getString(key, null);
        if (raw == null || raw.isEmpty()) return out;
        try {
            JSONArray arr = new JSONArray(raw);
            for (int i = 0; i < arr.length(); i++) out.add(arr.getString(i));
        } catch (Exception ignored) {
        }
        return out;
    }

    private void setList(String key, List<String> v) {
        JSONArray arr = new JSONArray();
        for (String s : v) arr.put(s);
        sp.edit().putString(key, arr.toString()).apply();
    }
}
