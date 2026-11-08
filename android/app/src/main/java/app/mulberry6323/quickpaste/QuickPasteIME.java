package app.mulberry6323.quickpaste;

import android.annotation.SuppressLint;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.inputmethodservice.InputMethodService;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/** 自定义键盘主控制器，功能与 iOS 版 KeyboardViewController 对齐。 */
public class QuickPasteIME extends InputMethodService {

    private static final int BG = Color.parseColor("#F2F2F7");
    private static final int CARD = Color.WHITE;
    private static final int KEY_BG = Color.parseColor("#E6E6EC");
    private static final int TEXT = Color.parseColor("#1C1C1E");
    private static final int MUTED = Color.parseColor("#7A7A82");
    private static final int BLUE = Color.parseColor("#0A7CFF");
    private static final int RED = Color.parseColor("#D70015");

    private Prefs prefs;
    private FrameLayout container;
    private LinearLayout content;
    private FrameLayout menuOverlay;
    private LinearLayout menuStack;
    private LinearLayout tabBar;
    private Button tabClip;
    private Button tabPhrase;
    private LinearLayout symRow;
    private Button copyBtn;
    private Button deleteBtn;
    private ScrollView listScroll;
    private LinearLayout listBox;
    private LinearLayout calcBox;
    private TextView calcExpr;
    private TextView calcResult;

    private String calcExpression = "";
    private boolean isCalcMode = false;
    private final ArrayList<String> undoStack = new ArrayList<>();

    private ClipboardManager cm;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private Runnable poller;
    private ClipboardManager.OnPrimaryClipChangedListener clipListener;

    private float spaceOriginX = 0f;
    private int spaceLastSteps = 0;
    private boolean spaceMoved = false;

    // ---------------------------------------------------------------- 生命周期

    @Override
    public void onCreate() {
        super.onCreate();
        prefs = new Prefs(this);
        cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        clipListener = () -> {
            if (prefs.continuousCopy()) {
                captureClipboard();
                refreshList();
            }
        };
    }

    @Override
    public View onCreateInputView() {
        container = new FrameLayout(this);
        container.setBackgroundColor(BG);
        container.setLayoutParams(new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(prefs.heightDp())));

        content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setBackgroundColor(BG);
        container.addView(content, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));

        content.addView(buildToolbar(), lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(42)));

        buildTabs();
        content.addView(tabBar, lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(32)));

        listScroll = new ScrollView(this);
        listBox = new LinearLayout(this);
        listBox.setOrientation(LinearLayout.VERTICAL);
        listBox.setPadding(dp(8), dp(4), dp(8), dp(4));
        listScroll.addView(listBox, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        content.addView(listScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        buildCalc();
        calcBox.setVisibility(View.GONE);
        content.addView(calcBox, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        content.addView(buildBottomBar(), lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)));

        buildMenuOverlay();

        refreshTabBar();
        refreshCopyButton();
        refreshSymbols();
        refreshList();
        return container;
    }

    @Override
    public void onStartInputView(EditorInfo info, boolean restarting) {
        super.onStartInputView(info, restarting);
        applyHeight();
        captureClipboard();
        refreshTabBar();
        refreshCopyButton();
        refreshSymbols();
        refreshList();
        if (prefs.continuousCopy()) startPolling();
    }

    @Override
    public void onFinishInputView(boolean finishingInput) {
        stopPolling();
        super.onFinishInputView(finishingInput);
    }

    @Override
    public void onDestroy() {
        stopPolling();
        super.onDestroy();
    }

    // ---------------------------------------------------------------- 工具栏

    private LinearLayout buildToolbar() {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(8), 0, dp(8), 0);

        Button collapse = toolBtn("⌄");
        collapse.setOnClickListener(v -> requestHideSelf(0));
        collapse.setOnLongClickListener(v -> {
            openMenu();
            return true;
        });
        bar.addView(collapse);

        Button globe = toolBtn("🌐");
        globe.setOnClickListener(v -> switchIme());
        bar.addView(globe);

        copyBtn = toolBtn("⧉");
        copyBtn.setOnClickListener(v -> {
            prefs.setContinuousCopy(!prefs.continuousCopy());
            refreshCopyButton();
            if (prefs.continuousCopy()) startPolling();
            else stopPolling();
        });
        bar.addView(copyBtn);

        HorizontalScrollView symScroll = new HorizontalScrollView(this);
        symScroll.setHorizontalScrollBarEnabled(false);
        symRow = new LinearLayout(this);
        symRow.setOrientation(LinearLayout.HORIZONTAL);
        symRow.setGravity(Gravity.CENTER_VERTICAL);
        symScroll.addView(symRow, new HorizontalScrollView.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
        LinearLayout.LayoutParams symLp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 1f);
        bar.addView(symScroll, symLp);

        deleteBtn = toolBtn("✕");
        deleteBtn.setOnClickListener(v -> backspace());
        final float[] startY = {0f};
        deleteBtn.setOnTouchListener((v, ev) -> {
            if (ev.getAction() == MotionEvent.ACTION_DOWN) {
                startY[0] = ev.getY();
                return false;
            }
            if (ev.getAction() == MotionEvent.ACTION_UP) {
                float dy = ev.getY() - startY[0];
                if (dy < -dp(28)) {
                    clearInput();
                    return true;
                }
                if (dy > dp(28)) {
                    restoreInput();
                    return true;
                }
            }
            return false;
        });
        bar.addView(deleteBtn);

        return bar;
    }

    private void refreshSymbols() {
        if (symRow == null) return;
        symRow.removeAllViews();
        List<String> syms = prefs.symbols();
        int count = Math.min(prefs.symbolCount(), syms.size());
        for (int i = 0; i < count; i++) {
            final String s = syms.get(i);
            Button b = toolBtn(s);
            b.setOnClickListener(v -> insert(s));
            symRow.addView(b);
        }
        Button more = toolBtn("⋯");
        more.setOnClickListener(v -> openMenu());
        symRow.addView(more);
    }

    private void refreshCopyButton() {
        if (copyBtn == null) return;
        boolean on = prefs.continuousCopy();
        copyBtn.setTextColor(on ? BLUE : TEXT);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(on ? Color.parseColor("#DCEBFF") : Color.TRANSPARENT);
        gd.setCornerRadius(dp(7));
        copyBtn.setBackground(gd);
    }

    // ---------------------------------------------------------------- Tab

    private void buildTabs() {
        tabBar = new LinearLayout(this);
        tabBar.setOrientation(LinearLayout.HORIZONTAL);
        tabBar.setPadding(dp(8), 0, dp(8), 0);
        tabClip = tabBtn("剪贴板");
        tabPhrase = tabBtn("常用语");
        tabClip.setOnClickListener(v -> {
            prefs.setTab("clip");
            refreshTabBar();
            refreshList();
        });
        tabPhrase.setOnClickListener(v -> {
            prefs.setTab("phrase");
            refreshTabBar();
            refreshList();
        });
        tabBar.addView(tabClip, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 1f));
        tabBar.addView(tabPhrase, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 1f));
    }

    private void refreshTabBar() {
        if (tabClip == null) return;
        boolean isClip = "clip".equals(prefs.tab());
        paintTab(tabClip, isClip);
        paintTab(tabPhrase, !isClip);
    }

    private void paintTab(Button b, boolean on) {
        b.setTextColor(on ? BLUE : MUTED);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(on ? Color.parseColor("#DCEBFF") : Color.TRANSPARENT);
        gd.setCornerRadius(dp(7));
        b.setBackground(gd);
    }

    // ---------------------------------------------------------------- 内容列表

    private void refreshList() {
        if (listBox == null) return;
        listBox.removeAllViews();
        List<String> items = prefs.items(prefs.tab());
        if (items.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText("clip".equals(prefs.tab()) ? "暂无剪贴板记录" : "暂无常用语");
            empty.setTextSize(13);
            empty.setTextColor(MUTED);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(0, dp(14), 0, dp(14));
            listBox.addView(empty, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT));
            return;
        }
        if (prefs.columns() == 1) {
            for (String s : items) listBox.addView(makeCard(s, false));
            return;
        }
        LinearLayout row = null;
        for (int i = 0; i < items.size(); i++) {
            if (i % 2 == 0) {
                row = new LinearLayout(this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                listBox.addView(row, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT));
            }
            row.addView(makeCard(items.get(i), true));
        }
        if (items.size() % 2 == 1 && row != null) {
            View filler = new View(this);
            LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(0, dp(40), 1f);
            flp.setMargins(dp(3), dp(3), dp(3), dp(3));
            row.addView(filler, flp);
        }
    }

    private Button makeCard(final String text, boolean weighted) {
        Button b = new Button(this);
        b.setText(text.length() > 60 ? text.substring(0, 60) + "…" : text);
        b.setAllCaps(false);
        b.setTextSize(13);
        b.setTextColor(TEXT);
        b.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
        b.setMaxLines(2);
        b.setEllipsize(TextUtils.TruncateAt.END);
        b.setPadding(dp(8), dp(4), dp(8), dp(4));
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(CARD);
        gd.setCornerRadius(dp(9));
        b.setBackground(gd);
        b.setOnClickListener(v -> insert(text));
        b.setOnLongClickListener(v -> {
            openCardMenu(text);
            return true;
        });
        LinearLayout.LayoutParams p;
        if (weighted) p = new LinearLayout.LayoutParams(0, dp(40), 1f);
        else p = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(40));
        p.setMargins(dp(3), dp(3), dp(3), dp(3));
        b.setLayoutParams(p);
        return b;
    }

    // ---------------------------------------------------------------- 计算器

    private void buildCalc() {
        calcBox = new LinearLayout(this);
        calcBox.setOrientation(LinearLayout.VERTICAL);
        calcBox.setPadding(dp(10), dp(4), dp(10), dp(4));

        calcExpr = new TextView(this);
        calcExpr.setTextSize(12);
        calcExpr.setTextColor(MUTED);
        calcExpr.setGravity(Gravity.END);
        calcBox.addView(calcExpr, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        calcResult = new TextView(this);
        calcResult.setTextSize(20);
        calcResult.setTextColor(TEXT);
        calcResult.setTypeface(Typeface.DEFAULT_BOLD);
        calcResult.setGravity(Gravity.END);
        calcBox.addView(calcResult, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        String[][] rows = {
                {"7", "8", "9", "÷", "⌫"},
                {"4", "5", "6", "×", "("},
                {"1", "2", "3", "−", ")"},
                {"0", ".", "=", "+", "输入"}
        };
        for (String[] keys : rows) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            for (String k : keys) {
                Button b = keyBtn(k);
                b.setOnClickListener(v -> handleCalcKey(k));
                LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(0, dp(30), 1f);
                p.setMargins(dp(2), dp(2), dp(2), dp(2));
                row.addView(b, p);
            }
            calcBox.addView(row, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT));
        }
    }

    private void toggleCalcMode() {
        isCalcMode = !isCalcMode;
        calcBox.setVisibility(isCalcMode ? View.VISIBLE : View.GONE);
        listScroll.setVisibility(isCalcMode ? View.GONE : View.VISIBLE);
        tabBar.setVisibility(isCalcMode ? View.GONE : View.VISIBLE);
        if (isCalcMode) {
            calcExpression = "";
            updateCalcDisplay();
        }
    }

    private void handleCalcKey(String k) {
        switch (k) {
            case "输入":
                try {
                    insert(CalcEngine.format(CalcEngine.evaluate(calcExpression)));
                    toggleCalcMode();
                } catch (Exception ignored) {
                }
                break;
            case "⌫":
                if (!calcExpression.isEmpty()) {
                    calcExpression = calcExpression.substring(0, calcExpression.length() - 1);
                }
                updateCalcDisplay();
                break;
            case "=":
                updateCalcDisplay();
                break;
            default:
                calcExpression += k;
                updateCalcDisplay();
        }
    }

    private void updateCalcDisplay() {
        calcExpr.setText(calcExpression.isEmpty() ? "输入算式，例如 128×3" : calcExpression);
        if (calcExpression.isEmpty()) {
            calcResult.setText("");
            return;
        }
        try {
            calcResult.setText("= " + CalcEngine.format(CalcEngine.evaluate(calcExpression)));
            calcResult.setTextColor(TEXT);
        } catch (Exception e) {
            calcResult.setText("—");
            calcResult.setTextColor(MUTED);
        }
    }

    // ---------------------------------------------------------------- 底行

    private LinearLayout buildBottomBar() {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(8), dp(2), dp(8), dp(4));

        Button calc = keyBtn("ƒ(x)");
        calc.setOnClickListener(v -> toggleCalcMode());
        bar.addView(calc, new LinearLayout.LayoutParams(dp(58),
                ViewGroup.LayoutParams.MATCH_PARENT));

        Button space = keyBtn("空格");
        space.setOnTouchListener((v, ev) -> {
            switch (ev.getAction()) {
                case MotionEvent.ACTION_DOWN:
                    spaceOriginX = ev.getX();
                    spaceLastSteps = 0;
                    spaceMoved = false;
                    return true;
                case MotionEvent.ACTION_MOVE:
                    if (prefs.spaceCursor()) {
                        int steps = (int) ((ev.getX() - spaceOriginX) / dp(10));
                        int delta = steps - spaceLastSteps;
                        if (delta != 0) {
                            moveCursor(delta);
                            spaceLastSteps = steps;
                            spaceMoved = true;
                        }
                    }
                    return true;
                case MotionEvent.ACTION_UP:
                    if (!spaceMoved) insert(" ");
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    return true;
                default:
                    return false;
            }
        });
        LinearLayout.LayoutParams spaceLp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 1f);
        spaceLp.setMargins(dp(4), 0, dp(4), 0);
        bar.addView(space, spaceLp);

        Button newline = keyBtn("换行");
        newline.setOnClickListener(v -> insert("\n"));
        bar.addView(newline, new LinearLayout.LayoutParams(dp(52),
                ViewGroup.LayoutParams.MATCH_PARENT));

        Button send = keyBtn("发送");
        send.setTextColor(Color.WHITE);
        GradientDrawable sgd = new GradientDrawable();
        sgd.setColor(BLUE);
        sgd.setCornerRadius(dp(8));
        send.setBackground(sgd);
        send.setTypeface(Typeface.DEFAULT_BOLD);
        send.setOnClickListener(v -> {
            insert("\n");
            if (prefs.autoCollapse()) requestHideSelf(0);
        });
        LinearLayout.LayoutParams sendLp = new LinearLayout.LayoutParams(dp(52),
                ViewGroup.LayoutParams.MATCH_PARENT);
        sendLp.setMargins(dp(4), 0, 0, 0);
        bar.addView(send, sendLp);

        return bar;
    }

    // ---------------------------------------------------------------- 设置菜单（键盘内浮层）

    private void buildMenuOverlay() {
        menuOverlay = new FrameLayout(this);
        menuOverlay.setBackgroundColor(Color.parseColor("#66000000"));
        menuOverlay.setClickable(true);
        menuOverlay.setOnClickListener(v -> closeMenu());
        menuOverlay.setVisibility(View.GONE);

        menuStack = new LinearLayout(this);
        menuStack.setOrientation(LinearLayout.VERTICAL);
        menuStack.setClickable(true);
        menuStack.setPadding(0, dp(6), 0, dp(6));
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(CARD);
        gd.setCornerRadius(dp(12));
        menuStack.setBackground(gd);

        FrameLayout.LayoutParams mlp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER_VERTICAL);
        mlp.setMargins(dp(14), 0, dp(14), 0);
        menuOverlay.addView(menuStack, mlp);
        container.addView(menuOverlay, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
    }

    private void openMenu() {
        if (menuOverlay == null) return;
        menuStack.removeAllViews();
        menuOverlay.setVisibility(View.VISIBLE);
        menuStack.addView(menuTitle("键盘设置"));

        menuStack.addView(menuRow("剪贴板", "clip".equals(prefs.tab()) ? "当前" : null, false,
                () -> {
                    prefs.setTab("clip");
                    refreshTabBar();
                    refreshList();
                    closeMenu();
                }));
        menuStack.addView(menuRow("常用语", "phrase".equals(prefs.tab()) ? "当前" : null, false,
                () -> {
                    prefs.setTab("phrase");
                    refreshTabBar();
                    refreshList();
                    closeMenu();
                }));
        menuStack.addView(menuRow("列数", prefs.columns() + " 列", false, () -> {
            prefs.setColumns(prefs.columns() == 1 ? 2 : 1);
            refreshList();
            openMenu();
        }));
        menuStack.addView(menuRow("键盘高度", prefs.heightDp() + " dp", false, () -> {
            prefs.setHeightDp(prefs.heightDp() >= 300 ? 220 : prefs.heightDp() + 20);
            applyHeight();
            openMenu();
        }));
        menuStack.addView(menuRow("空格滑动移光标", prefs.spaceCursor() ? "开" : "关", false, () -> {
            prefs.setSpaceCursor(!prefs.spaceCursor());
            openMenu();
        }));
        menuStack.addView(menuRow("发送后收起键盘", prefs.autoCollapse() ? "开" : "关", false, () -> {
            prefs.setAutoCollapse(!prefs.autoCollapse());
            openMenu();
        }));
        menuStack.addView(menuRow("清空输入框", null, false, () -> {
            clearInput();
            closeMenu();
        }));
        menuStack.addView(menuRow("切换系统键盘", null, false, () -> {
            switchIme();
            closeMenu();
        }));
        menuStack.addView(menuRow("关闭菜单", null, false, this::closeMenu));
    }

    private void openCardMenu(final String text) {
        if (menuOverlay == null) return;
        menuStack.removeAllViews();
        menuOverlay.setVisibility(View.VISIBLE);
        String preview = text.length() > 24 ? text.substring(0, 24) + "…" : text;
        menuStack.addView(menuTitle(preview));
        menuStack.addView(menuRow("插入到输入框", null, false, () -> {
            insert(text);
            closeMenu();
        }));
        menuStack.addView(menuRow("置顶 / 取消置顶", null, false, () -> {
            prefs.togglePin(text);
            refreshList();
            closeMenu();
        }));
        menuStack.addView(menuRow("删除这条", null, true, () -> {
            prefs.remove(text, prefs.tab());
            refreshList();
            closeMenu();
        }));
        menuStack.addView(menuRow("关闭菜单", null, false, this::closeMenu));
    }

    private void closeMenu() {
        if (menuOverlay != null) menuOverlay.setVisibility(View.GONE);
    }

    private TextView menuTitle(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(12);
        tv.setTextColor(MUTED);
        tv.setGravity(Gravity.CENTER);
        tv.setPadding(0, dp(4), 0, dp(4));
        return tv;
    }

    private Button menuRow(String title, String value, boolean danger, Runnable action) {
        Button b = new Button(this);
        b.setText(value == null ? title : title + "　" + value);
        b.setAllCaps(false);
        b.setTextSize(14);
        b.setTextColor(danger ? RED : TEXT);
        b.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
        b.setBackgroundColor(Color.TRANSPARENT);
        b.setPadding(dp(16), 0, dp(16), 0);
        b.setOnClickListener(v -> action.run());
        b.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(38)));
        return b;
    }

    // ---------------------------------------------------------------- 剪贴板

    private void captureClipboard() {
        try {
            if (cm == null || !cm.hasPrimaryClip()) return;
            ClipData clip = cm.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) return;
            CharSequence cs = clip.getItemAt(0).getText();
            if (cs != null) prefs.capture(cs.toString());
        } catch (SecurityException e) {
            // Android 10+ 限制后台读取剪贴板；键盘显示时通常可读，读不到就跳过。
        } catch (Exception ignored) {
        }
    }

    private void startPolling() {
        stopPolling();
        if (!prefs.continuousCopy()) return;
        try {
            if (cm != null) cm.addPrimaryClipChangedListener(clipListener);
        } catch (Exception ignored) {
        }
        poller = new Runnable() {
            @Override
            public void run() {
                captureClipboard();
                refreshList();
                handler.postDelayed(this, 1200);
            }
        };
        handler.postDelayed(poller, 1200);
    }

    private void stopPolling() {
        if (poller != null) {
            handler.removeCallbacks(poller);
            poller = null;
        }
        try {
            if (cm != null) cm.removePrimaryClipChangedListener(clipListener);
        } catch (Exception ignored) {
        }
    }

    // ---------------------------------------------------------------- 输入操作

    private void insert(String s) {
        InputConnection ic = getCurrentInputConnection();
        if (ic != null) ic.commitText(s, 1);
    }

    private void backspace() {
        sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL);
    }

    private void moveCursor(int delta) {
        int code = delta < 0 ? KeyEvent.KEYCODE_DPAD_LEFT : KeyEvent.KEYCODE_DPAD_RIGHT;
        int n = Math.min(Math.abs(delta), 50);
        for (int i = 0; i < n; i++) sendDownUpKeyEvents(code);
    }

    private void clearInput() {
        InputConnection ic = getCurrentInputConnection();
        if (ic == null) return;
        CharSequence before = ic.getTextBeforeCursor(10000, 0);
        if (before != null && before.length() > 0) {
            undoStack.add(before.toString());
            ic.deleteSurroundingText(before.length(), 0);
        }
    }

    private void restoreInput() {
        if (!undoStack.isEmpty()) insert(undoStack.remove(undoStack.size() - 1));
    }

    @SuppressLint("NewApi")
    private void switchIme() {
        boolean ok = false;
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                ok = switchToNextInputMethod(false);
            } catch (Exception ignored) {
            }
        }
        if (!ok) {
            InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
            if (imm != null) imm.showInputMethodPicker();
        }
    }

    private void applyHeight() {
        if (container == null) return;
        int h = dp(prefs.heightDp());
        container.setMinimumHeight(h);
        ViewGroup.LayoutParams p = container.getLayoutParams();
        if (p == null) p = new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, h);
        p.height = h;
        container.setLayoutParams(p);
        container.requestLayout();
    }

    // ---------------------------------------------------------------- UI 辅助

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }

    private LinearLayout.LayoutParams lp(int w, int h) {
        return new LinearLayout.LayoutParams(w, h);
    }

    private Button toolBtn(String text) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextSize(15);
        b.setTextColor(TEXT);
        b.setPadding(0, 0, 0, 0);
        b.setBackgroundColor(Color.TRANSPARENT);
        b.setMinWidth(dp(30));
        b.setMinimumWidth(dp(30));
        b.setLayoutParams(new LinearLayout.LayoutParams(dp(32), dp(32)));
        return b;
    }

    private Button tabBtn(String text) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextSize(13);
        b.setTextColor(MUTED);
        b.setBackgroundColor(Color.TRANSPARENT);
        return b;
    }

    private Button keyBtn(String text) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextSize(14);
        b.setTextColor(TEXT);
        b.setPadding(0, 0, 0, 0);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(KEY_BG);
        gd.setCornerRadius(dp(7));
        b.setBackground(gd);
        return b;
    }
}
