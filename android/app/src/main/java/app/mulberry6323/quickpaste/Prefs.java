package app.mulberry6323.quickpaste;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * 键盘与主 App 共享的状态。安卓上二者默认同进程，SharedPreferences 天然共享，
 * 因此不需要 iOS 的 App Group / entitlement。
 */
public final class Prefs {

    public static final String DEFAULT_URL = "http://192.168.1.2:8787";

    private static final String FILE = "qp";
    private final SharedPreferences sp;

    public Prefs(Context ctx) {
        sp = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    private static int clamp(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    // ---- 局域网同步（v1.6） ----

    public String syncUrl() {
        String s = sp.getString("qp.syncUrl", DEFAULT_URL);
        if (s == null) s = DEFAULT_URL;
        s = s.trim();
        if (s.isEmpty()) return DEFAULT_URL;
        if (!s.startsWith("http://") && !s.startsWith("https://")) s = "http://" + s;
        while (s.endsWith("/")) s = s.substring(0, s.length() - 1);
        return s;
    }

    public void setSyncUrl(String v) {
        String s = v == null ? "" : v.trim();
        if (!s.isEmpty() && !s.startsWith("http://") && !s.startsWith("https://")) {
            s = "http://" + s;
        }
        sp.edit().putString("qp.syncUrl", s).apply();
    }

    public String syncPair() {
        String s = sp.getString("qp.syncPair", "");
        return s == null ? "" : s.trim();
    }

    public void setSyncPair(String v) {
        sp.edit().putString("qp.syncPair", v == null ? "" : v.trim()).apply();
    }

    /** 自动同步（每 3 秒拉取一次），默认开启。 */
    public boolean syncAuto() {
        return sp.getBoolean("qp.syncAuto", true);
    }

    public void setSyncAuto(boolean v) {
        sp.edit().putBoolean("qp.syncAuto", v).apply();
    }

    // ---- 布局 ----

    public int columns() {
        return clamp(sp.getInt("qp.columns", 1), 1, 2);
    }

    public void setColumns(int v) {
        sp.edit().putInt("qp.columns", clamp(v, 1, 2)).apply();
    }

    public int heightDp() {
        return clamp(sp.getInt("qp.height", 290), 220, 340);
    }

    public void setHeightDp(int v) {
        sp.edit().putInt("qp.height", clamp(v, 220, 340)).apply();
    }

    // ---- 交互开关 ----

    public boolean spaceCursor() {
        return sp.getBoolean("qp.spaceCursor", true);
    }

    public void setSpaceCursor(boolean v) {
        sp.edit().putBoolean("qp.spaceCursor", v).apply();
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
            return new ArrayList<String>(Arrays.asList("。", "，", "？", "！", "："));
        }
        return saved;
    }

    public int symbolCount() {
        return clamp(sp.getInt("qp.symbolCount", 4), 2, 5);
    }

    public List<String> phrases() {
        List<String> saved = getList("qp.phrases");
        if (saved.isEmpty()) {
            return new ArrayList<String>(Arrays.asList(
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

    /** 本机剪贴板采集（离线兜底，也用于「连续复制」）。 */
    public boolean capture(String text) {
        if (text == null) return false;
        String t = text.trim();
        if (t.isEmpty()) return false;
        List<String> history = new ArrayList<String>(clips());
        if (!history.isEmpty() && history.get(0).equals(t)) return false;
        for (int i = history.size() - 1; i >= 0; i--) {
            if (history.get(i).equals(t)) history.remove(i);
        }
        history.add(0, t);
        if (history.size() > 30) history = new ArrayList<String>(history.subList(0, 30));
        setList("qp.clips", history);
        return true;
    }

    /** 常用语 Tab 的内容（剪贴板 Tab 已改为局域网同步数据）。 */
    public List<String> items(String tab) {
        List<String> all = "phrase".equals(tab) ? phrases() : clips();
        List<String> pin = pinned();
        List<String> out = new ArrayList<String>();
        for (String p : pin) if (all.contains(p)) out.add(p);
        for (String s : all) if (!pin.contains(s)) out.add(s);
        return out;
    }

    public void remove(String text, String tab) {
        List<String> all = new ArrayList<String>("phrase".equals(tab) ? phrases() : clips());
        all.remove(text);
        if ("phrase".equals(tab)) setPhrases(all);
        else setList("qp.clips", all);
        List<String> pin = new ArrayList<String>(pinned());
        pin.remove(text);
        setList("qp.pinned", pin);
    }

    public void togglePin(String text) {
        List<String> pin = new ArrayList<String>(pinned());
        if (pin.contains(text)) pin.remove(text);
        else pin.add(text);
        setList("qp.pinned", pin);
    }

    // ---- JSON 序列化（org.json 为 Android 内置）----

    private List<String> getList(String key) {
        List<String> out = new ArrayList<String>();
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
