package app.mulberry6323.mozhi;

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

    /** 复制后自动推送到电脑，默认开启（手机一复制，电脑那边就该有）。 */
    public boolean autoPush() {
        return sp.getBoolean("qp.autoPush", true);
    }

    public void setAutoPush(boolean v) {
        sp.edit().putBoolean("qp.autoPush", v).apply();
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

    // ---- v1.6 设置详情（与 HTML 原型 state.toggles 一一对应） ----

    public boolean floatClose() { return sp.getBoolean("qp.floatClose", true); }
    public void setFloatClose(boolean v) { sp.edit().putBoolean("qp.floatClose", v).apply(); }

    public boolean directSwitch() { return sp.getBoolean("qp.directSwitch", false); }
    public void setDirectSwitch(boolean v) { sp.edit().putBoolean("qp.directSwitch", v).apply(); }

    public boolean savedTip() { return sp.getBoolean("qp.savedTip", true); }
    public void setSavedTip(boolean v) { sp.edit().putBoolean("qp.savedTip", v).apply(); }

    public boolean clearBtn() { return sp.getBoolean("qp.clearBtn", true); }
    public void setClearBtn(boolean v) { sp.edit().putBoolean("qp.clearBtn", v).apply(); }

    public boolean continuous() { return sp.getBoolean("qp.continuous", false); }
    public void setContinuous(boolean v) { sp.edit().putBoolean("qp.continuous", v).apply(); }

    public boolean onlyUnsorted() { return sp.getBoolean("qp.onlyUnsorted", false); }
    public void setOnlyUnsorted(boolean v) { sp.edit().putBoolean("qp.onlyUnsorted", v).apply(); }

    public String align() { return sp.getString("qp.align", "left"); }
    public void setAlign(String v) { sp.edit().putString("qp.align", v).apply(); }

    public String storage() { return sp.getString("qp.storage", "剪贴板历史"); }
    public void setStorage(String v) { sp.edit().putString("qp.storage", v).apply(); }

    /** 历史保留天数，0 = 永久。 */
    public int historyDays() { return clamp(sp.getInt("qp.historyDays", 30), 0, 365); }
    public void setHistoryDays(int v) { sp.edit().putInt("qp.historyDays", clamp(v, 0, 365)).apply(); }

    public void setSymbols(List<String> v) { setList("qp.symbols", v); }
    public void setSymbolCount(int v) { sp.edit().putInt("qp.symbolCount", clamp(v, 2, 5)).apply(); }

    public List<String> recentDeleted() { return getList("qp.recentDeleted"); }
    public void setRecentDeleted(List<String> v) { setList("qp.recentDeleted", v); }
    public void clearRecentDeleted() { setList("qp.recentDeleted", new ArrayList<String>()); }

    /** 按历史保留天数清理过期记录（置顶不受影响）。时间戳存于 qp.clipTimes。 */
    public int pruneHistory() {
        int days = historyDays();
        if (days <= 0) return 0;
        long cutoff = System.currentTimeMillis() - (long) days * 86400000L;
        List<String> texts = new ArrayList<String>(clips());
        List<String> rawTimes = getList("qp.clipTimes");
        List<String> pin = pinned();
        List<String> keepText = new ArrayList<String>();
        List<String> keepTime = new ArrayList<String>();
        for (int i = 0; i < texts.size(); i++) {
            String t = texts.get(i);
            long ts = System.currentTimeMillis();
            if (i < rawTimes.size()) {
                try { ts = Long.parseLong(rawTimes.get(i)); } catch (Exception ignored) { }
            }
            if (pin.contains(t) || ts >= cutoff) {
                keepText.add(t);
                keepTime.add(String.valueOf(ts));
            }
        }
        int removed = texts.size() - keepText.size();
        if (removed > 0) {
            setList("qp.clips", keepText);
            setList("qp.clipTimes", keepTime);
        }
        return removed;
    }

    public void restore(String text) {
        List<String> del = new ArrayList<String>(recentDeleted());
        del.remove(text);
        setRecentDeleted(del);
        List<String> history = new ArrayList<String>(clips());
        List<String> times = new ArrayList<String>(getList("qp.clipTimes"));
        history.add(0, text);
        times.add(0, String.valueOf(System.currentTimeMillis()));
        setList("qp.clips", history);
        setList("qp.clipTimes", times);
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

    /** 与 clips 按下标一一对应的收录时刻（毫秒字符串）。用于统一排序。 */
    public List<String> clipTimes() {
        return getList("qp.clipTimes");
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
        List<String> times = new ArrayList<String>(getList("qp.clipTimes"));
        String now = String.valueOf(System.currentTimeMillis());
        // 补齐时间戳，保证与 clips 一一对应
        while (times.size() < history.size()) times.add(now);
        if (times.size() > history.size()) times = new ArrayList<String>(times.subList(0, history.size()));

        if (!history.isEmpty() && history.get(0).equals(t)) return false;
        for (int i = history.size() - 1; i >= 0; i--) {
            if (history.get(i).equals(t)) {
                history.remove(i);
                if (i < times.size()) times.remove(i);
            }
        }
        history.add(0, t);
        times.add(0, now);
        if (history.size() > 100) {
            history = new ArrayList<String>(history.subList(0, 100));
            times = new ArrayList<String>(times.subList(0, 100));
        }
        setList("qp.clips", history);
        setList("qp.clipTimes", times);
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
