package app.mulberry6323.quickpaste;

import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.inputmethodservice.InputMethodService;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.util.Base64;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputContentInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * QuickPaste v1.6 真·系统输入法。
 *
 * 界面 1:1 对齐 quickpaste-ios-prototype.html 的键盘页：
 *   连接状态头(.syncHead) / 工具条(.kbToolbar) / 剪贴板卡片(.kbCard + .srcIcon)
 *   / 图片缩略图(.kbThumb) / 清空行(.kbClear) / 底行按键(.kbKeys) / 浮层菜单(.kbPick)
 * 数据源不再是演示用本地数组，而是电脑端 sync/server.js 的局域网同步服务。
 */
public class QuickPasteIME extends InputMethodService {

    private static final int BG = Color.parseColor("#F3F4F9");
    private static final int CARD = Color.WHITE;
    private static final int BLUE = Color.parseColor("#0A7CFF");
    private static final int GREEN = Color.parseColor("#34C759");
    private static final int ORANGE = Color.parseColor("#FF9500");
    private static final int RED = Color.parseColor("#FF3B30");
    private static final int TEXT = Color.parseColor("#000000");
    private static final int SUB = Color.parseColor("#8A8A8F");
    private static final int SEP = Color.parseColor("#E6E6EB");
    private static final int KEY_BG = Color.parseColor("#D4D6DE");

    private Prefs prefs;
    private ClipboardManager cm;
    private final ExecutorService net = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final List<SyncItem> syncItems = new ArrayList<SyncItem>();
    private final Map<String, Bitmap> thumbs = new HashMap<String, Bitmap>();

    private String syncSig = "";
    private String syncState = "off";
    private String syncError = "";
    private String backend = "";
    private String hostPackage = "";
    private int syncCount = 0;
    private long lastSync = 0;
    private boolean polling = false;

    private final Runnable pollTask = new Runnable() {
        @Override
        public void run() {
            if (!polling) return;
            pull(false);
            ui.postDelayed(this, 3000);
        }
    };

    private FrameLayout container;
    private LinearLayout content;
    private View headDot;
    private TextView headTitle;
    private TextView headDesc;
    private Button autoBtn;
    private LinearLayout symRow;
    private LinearLayout tabBar;
    private Button tabClip;
    private Button tabPhrase;
    private ScrollView listScroll;
    private LinearLayout listBox;
    private LinearLayout calcBox;
    private TextView calcExpr;
    private TextView calcResult;
    private FrameLayout menuOverlay;
    private LinearLayout menuStack;
    /** v1.6 完整多页设置界面 */
    private ImeSettings settings;
    private View clearRowView;
    private FrameLayout imgOverlay;
    private ImageView imgBig;

    private String calcExpression = "";
    private boolean isCalcMode = false;
    private final ArrayList<String> undoStack = new ArrayList<String>();
    private float spaceOriginX = 0f;
    private int spaceLastSteps = 0;
    private boolean spaceMoved = false;

    // ------------------------------------------------------------ 生命周期

    @Override
    public void onCreate() {
        super.onCreate();
        prefs = new Prefs(this);
        cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
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

        buildHead();
        buildToolbar();
        buildTabs();
        buildList();
        buildCalc();
        buildClearRow();
        buildBottomBar();
        buildMenuOverlay();
        buildImageOverlay();

        settings = new ImeSettings(this, hostCallbacks);
        container.addView(settings.view(), new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));

        refreshHead();
        refreshTabBar();
        refreshSymbols();
        refreshList();
        return container;
    }

    @Override
    public void onStartInputView(EditorInfo info, boolean restarting) {
        super.onStartInputView(info, restarting);
        hostPackage = info.packageName == null ? "" : info.packageName;
        // 「历史保留时间」：每次呼出键盘执行一次过期清理
        int pruned = prefs.pruneHistory();
        if (pruned > 0 && prefs.savedTip()) toast("已清理 " + pruned + " 条过期记录");
        // 「连续复制」开关：呼出时自动收录系统剪贴板新文字
        if (prefs.continuous() && cm != null) {
            android.content.ClipData d = cm.getPrimaryClip();
            if (d != null && d.getItemCount() > 0 && d.getItemAt(0).getText() != null) {
                if (prefs.capture(d.getItemAt(0).getText().toString()) && prefs.savedTip()) {
                    toast("新内容已保存");
                }
            }
        }
        applyHeight();
        refreshHead();
        refreshTabBar();
        refreshSymbols();
        pull(true);
        startPolling();
    }

    @Override
    public void onFinishInputView(boolean finishingInput) {
        stopPolling();
        super.onFinishInputView(finishingInput);
    }

    @Override
    public void onDestroy() {
        stopPolling();
        net.shutdownNow();
        super.onDestroy();
    }

    // ------------------------------------------------------------ 同步

    private SyncClient client() {
        return new SyncClient(prefs.syncUrl(), prefs.syncPair());
    }

    private void pull(final boolean showConnecting) {
        if (showConnecting) {
            syncState = "connecting";
            refreshHead();
        }
        final SyncClient c = client();
        net.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    final SyncClient.Result r = c.fetch(30);
                    ui.post(new Runnable() {
                        @Override
                        public void run() {
                            applyResult(r);
                        }
                    });
                } catch (final Exception e) {
                    ui.post(new Runnable() {
                        @Override
                        public void run() {
                            syncError = e.getMessage() == null ? "连接失败" : e.getMessage();
                            syncState = "error";
                            refreshHead();
                        }
                    });
                }
            }
        });
    }

    private void applyResult(SyncClient.Result r) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < Math.min(10, r.items.size()); i++) {
            sb.append(r.items.get(i).id).append(':').append(r.items.get(i).ts).append('|');
        }
        String sig = sb.toString();
        if (!sig.equals(syncSig)) {
            syncSig = sig;
            syncItems.clear();
            syncItems.addAll(r.items);
            thumbs.clear();
            refreshList();
        }
        syncCount = r.count;
        backend = r.backend;
        lastSync = System.currentTimeMillis();
        syncState = "online";
        refreshHead();
    }

    private void startPolling() {
        stopPolling();
        if (!prefs.syncAuto()) return;
        polling = true;
        ui.postDelayed(pollTask, 1500);
    }

    private void stopPolling() {
        polling = false;
        ui.removeCallbacks(pollTask);
    }

    private void sendTextToPc(String text) {
        if (text == null || text.trim().isEmpty()) {
            toast("没有可发送的文字");
            return;
        }
        final String t = text;
        final SyncClient c = client();
        net.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    c.pushText(t);
                    ui.post(new Runnable() {
                        @Override
                        public void run() {
                            toast("已发送到电脑，Ctrl+V 可粘贴");
                            pull(false);
                        }
                    });
                } catch (final Exception e) {
                    ui.post(new Runnable() {
                        @Override
                        public void run() {
                            toast("发送失败：" + e.getMessage());
                        }
                    });
                }
            }
        });
    }

    private void sendInputTextToPc() {
        InputConnection ic = getCurrentInputConnection();
        CharSequence before = ic == null ? null : ic.getTextBeforeCursor(10000, 0);
        CharSequence sel = ic == null ? null : ic.getSelectedText(0);
        String t = sel != null && sel.length() > 0 ? sel.toString()
                : (before == null ? "" : before.toString());
        sendTextToPc(t);
    }

    private void sendClipboardTextToPc() {
        try {
            if (cm == null || !cm.hasPrimaryClip() || cm.getPrimaryClip() == null
                    || cm.getPrimaryClip().getItemCount() == 0) {
                toast("剪贴板里没有文字");
                return;
            }
            CharSequence cs = cm.getPrimaryClip().getItemAt(0).getText();
            sendTextToPc(cs == null ? "" : cs.toString());
        } catch (Exception e) {
            toast("读不到剪贴板");
        }
    }

    private void sendClipboardImageToPc() {
        try {
            if (cm == null || cm.getPrimaryClip() == null || cm.getPrimaryClip().getItemCount() == 0) {
                toast("剪贴板里没有内容");
                return;
            }
            Uri u = cm.getPrimaryClip().getItemAt(0).getUri();
            if (u == null) {
                toast("剪贴板里不是图片");
                return;
            }
            InputStream in = getContentResolver().openInputStream(u);
            byte[] data = readBytes(in);
            in.close();
            String mime = getContentResolver().getType(u);
            if (mime == null || !mime.startsWith("image/")) mime = "image/png";
            pushImage(data, mime);
        } catch (Exception e) {
            toast("读图片失败：" + e.getMessage());
        }
    }

    private void pushImage(final byte[] data, final String mime) {
        final SyncClient c = client();
        net.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    c.pushImage(data, mime);
                    ui.post(new Runnable() {
                        @Override
                        public void run() {
                            toast("图片已发送到电脑，Ctrl+V 可粘贴");
                            pull(false);
                        }
                    });
                } catch (final Exception e) {
                    ui.post(new Runnable() {
                        @Override
                        public void run() {
                            toast("发图失败：" + e.getMessage());
                        }
                    });
                }
            }
        });
    }

    private void deleteItem(final String id) {
        final SyncClient c = client();
        net.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    c.delete(id);
                    ui.post(new Runnable() {
                        @Override
                        public void run() {
                            toast("已删除");
                            syncSig = "";
                            pull(false);
                        }
                    });
                } catch (final Exception e) {
                    ui.post(new Runnable() {
                        @Override
                        public void run() {
                            toast("删除失败：" + e.getMessage());
                        }
                    });
                }
            }
        });
    }

    private static byte[] readBytes(InputStream in) throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) bos.write(buf, 0, n);
        return bos.toByteArray();
    }

    // ------------------------------------------------------------ 状态头 (.syncHead)

    private void buildHead() {
        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        head.setPadding(dp(14), dp(8), dp(14), dp(8));
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(CARD);
        gd.setCornerRadius(dp(18));
        head.setBackground(gd);
        head.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                pull(true);
            }
        });

        headDot = new View(this);
        head.addView(headDot, new LinearLayout.LayoutParams(dp(13), dp(13)));

        LinearLayout texts = new LinearLayout(this);
        texts.setOrientation(LinearLayout.VERTICAL);
        texts.setPadding(dp(12), 0, 0, 0);
        headTitle = new TextView(this);
        headTitle.setTextSize(16);
        headTitle.setTypeface(Typeface.DEFAULT_BOLD);
        headTitle.setTextColor(TEXT);
        headDesc = new TextView(this);
        headDesc.setTextSize(11);
        headDesc.setTextColor(SUB);
        headDesc.setMaxLines(2);
        headDesc.setEllipsize(TextUtils.TruncateAt.END);
        texts.addView(headTitle, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        texts.addView(headDesc, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        head.addView(texts, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout.LayoutParams hp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(60));
        hp.setMargins(dp(12), dp(8), dp(12), dp(2));
        content.addView(head, hp);
    }

    private void refreshHead() {
        if (headDot == null) return;
        int color;
        String title, desc;
        if ("online".equals(syncState)) {
            color = GREEN;
            title = "已连接 · " + ("copyq".equals(backend) ? "CopyQ 历史" : "电脑");
            desc = "共 " + syncCount + " 条 · 最近同步 " + timeStr(lastSync) + " · " + prefs.syncUrl();
        } else if ("connecting".equals(syncState)) {
            color = ORANGE;
            title = "正在连接…";
            desc = prefs.syncUrl();
        } else if ("error".equals(syncState)) {
            color = RED;
            title = "连接失败";
            desc = syncError + " · 点这里重试";
        } else {
            color = Color.parseColor("#C7C7CE");
            title = "未连接";
            desc = "点此连接 · 或到设置里确认电脑地址";
        }
        GradientDrawable dot = new GradientDrawable();
        dot.setShape(GradientDrawable.OVAL);
        dot.setColor(color);
        headDot.setBackground(dot);
        headTitle.setText(title);
        headDesc.setText(desc);

        if (autoBtn != null) {
            boolean on = prefs.syncAuto();
            autoBtn.setTextColor(on ? Color.WHITE : TEXT);
            GradientDrawable g = new GradientDrawable();
            g.setColor(on ? BLUE : KEY_BG);
            g.setCornerRadius(dp(9));
            autoBtn.setBackground(g);
        }
    }

    private static String timeStr(long ts) {
        if (ts <= 0) return "—";
        return new SimpleDateFormat("HH:mm", Locale.CHINA).format(new Date(ts));
    }

    // ------------------------------------------------------------ 工具条 (.kbToolbar)

    private void buildToolbar() {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(8), 0, dp(8), 0);

        Button collapse = toolBtn("⌄");
        collapse.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                requestHideSelf(0);
            }
        });
        collapse.setOnLongClickListener(new View.OnLongClickListener() {
            @Override
            public boolean onLongClick(View v) {
                openSettings();
                return true;
            }
        });
        bar.addView(collapse);

        Button globe = toolBtn("🌐");
        globe.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                switchIme();
            }
        });
        bar.addView(globe);

        autoBtn = toolBtn("⧉");
        autoBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                prefs.setSyncAuto(!prefs.syncAuto());
                if (prefs.syncAuto()) startPolling();
                else stopPolling();
                refreshHead();
                toast(prefs.syncAuto() ? "自动同步已开启（每 3 秒）" : "自动同步已关闭");
            }
        });
        autoBtn.setOnLongClickListener(new View.OnLongClickListener() {
            @Override
            public boolean onLongClick(View v) {
                if (prefs.directSwitch()) {
                    prefs.setTab("clip".equals(prefs.tab()) ? "phrase" : "clip");
                    refreshTabBar(); refreshList();
                } else openSettings();
                return true;
            }
        });
        bar.addView(autoBtn);

        HorizontalScrollView symScroll = new HorizontalScrollView(this);
        symScroll.setHorizontalScrollBarEnabled(false);
        symRow = new LinearLayout(this);
        symRow.setOrientation(LinearLayout.HORIZONTAL);
        symRow.setGravity(Gravity.CENTER_VERTICAL);
        symScroll.addView(symRow, new HorizontalScrollView.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
        bar.addView(symScroll, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 1f));

        Button deleteBtn = toolBtn("✕");
        // 原型 .kbTool.dark：黑底白字
        GradientDrawable dgd = new GradientDrawable();
        dgd.setColor(Color.parseColor("#2B2C31"));
        dgd.setCornerRadius(dp(9));
        deleteBtn.setBackground(dgd);
        deleteBtn.setTextColor(Color.WHITE);
        deleteBtn.setTextSize(18);
        deleteBtn.setLongClickable(true);
        deleteBtn.setOnLongClickListener(new View.OnLongClickListener() {
            @Override public boolean onLongClick(View v) { openSettings(); return true; }
        });
        deleteBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                backspace();
            }
        });
        final float[] startY = {0f};
        deleteBtn.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent ev) {
                if (ev.getAction() == MotionEvent.ACTION_DOWN) {
                    startY[0] = ev.getY();
                    return false;
                }
                if (ev.getAction() == MotionEvent.ACTION_UP) {
                    float dy = ev.getY() - startY[0];
                    if (dy < -dp(26)) {
                        clearInput();
                        return true;
                    }
                    if (dy > dp(26)) {
                        restoreInput();
                        return true;
                    }
                }
                return false;
            }
        });
        bar.addView(deleteBtn);

        content.addView(bar, lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(44)));
    }

    private void refreshSymbols() {
        if (symRow == null) return;
        symRow.removeAllViews();
        List<String> syms = prefs.symbols();
        int count = Math.min(prefs.symbolCount(), syms.size());
        for (int i = 0; i < count; i++) {
            final String s = syms.get(i);
            Button b = toolBtn(s);
            b.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    insert(s);
                }
            });
            symRow.addView(b);
        }
        Button more = toolBtn("⋯");
        // 「⋯」是完整设置界面入口
        more.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) { openSettings(); }
        });
        symRow.addView(more);
    }

    // ------------------------------------------------------------ Tab

    private void buildTabs() {
        tabBar = new LinearLayout(this);
        tabBar.setOrientation(LinearLayout.HORIZONTAL);
        tabBar.setPadding(dp(10), 0, dp(10), 0);
        tabClip = tabBtn("剪贴板（同步）");
        tabPhrase = tabBtn("常用语");
        tabClip.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                prefs.setTab("clip");
                refreshTabBar();
                refreshList();
            }
        });
        tabPhrase.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                prefs.setTab("phrase");
                refreshTabBar();
                refreshList();
            }
        });
        tabBar.addView(tabClip, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 1f));
        tabBar.addView(tabPhrase, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 1f));
        content.addView(tabBar, lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(30)));
    }

    private void refreshTabBar() {
        if (tabClip == null) return;
        paintTab(tabClip, "clip".equals(prefs.tab()));
        paintTab(tabPhrase, "phrase".equals(prefs.tab()));
    }

    private void paintTab(Button b, boolean on) {
        b.setTextColor(on ? BLUE : SUB);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(on ? Color.parseColor("#E8F1FF") : Color.TRANSPARENT);
        gd.setCornerRadius(dp(7));
        b.setBackground(gd);
    }

    // ------------------------------------------------------------ 列表 (.kbList / .kbCard)

    private void buildList() {
        listScroll = new ScrollView(this);
        listBox = new LinearLayout(this);
        listBox.setOrientation(LinearLayout.VERTICAL);
        listBox.setPadding(dp(8), dp(2), dp(8), dp(2));
        listScroll.addView(listBox, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        content.addView(listScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
    }

    private void refreshList() {
        if (listBox == null) return;
        listBox.removeAllViews();
        if ("phrase".equals(prefs.tab())) {
            List<String> items = prefs.items("phrase");
            if (items.isEmpty()) {
                listBox.addView(emptyText("暂无常用语，可在主 App 里编辑"));
                return;
            }
            for (final String s : items) listBox.addView(makeTextCard(s, false, null));
            return;
        }
        if (syncItems.isEmpty()) {
            String msg = "error".equals(syncState)
                    ? "连接失败\n点上方状态栏重试，或到设置里确认电脑地址"
                    : "暂无同步记录\n在电脑上复制文字或截图，会自动出现在这里";
            listBox.addView(emptyText(msg));
            Button b = new Button(this);
            b.setText("连接并刷新");
            b.setAllCaps(false);
            b.setTextColor(Color.WHITE);
            GradientDrawable gd = new GradientDrawable();
            gd.setColor(BLUE);
            gd.setCornerRadius(dp(10));
            b.setBackground(gd);
            b.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    pull(true);
                }
            });
            LinearLayout.LayoutParams p = lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(40));
            p.setMargins(dp(40), dp(8), dp(40), dp(8));
            listBox.addView(b, p);
            return;
        }
        if (prefs.columns() == 1) {
            for (SyncItem it : syncItems) listBox.addView(makeSyncCard(it, false));
            return;
        }
        LinearLayout row = null;
        for (int i = 0; i < syncItems.size(); i++) {
            if (i % 2 == 0) {
                row = new LinearLayout(this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                listBox.addView(row, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT));
            }
            row.addView(makeSyncCard(syncItems.get(i), true));
        }
        if (syncItems.size() % 2 == 1 && row != null) {
            View filler = new View(this);
            LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(0, dp(56), 1f);
            flp.setMargins(dp(3), dp(3), dp(3), dp(3));
            row.addView(filler, flp);
        }
    }

    private TextView emptyText(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(14);
        tv.setTextColor(SUB);
        tv.setGravity(Gravity.CENTER);
        tv.setPadding(0, dp(20), 0, dp(20));
        return tv;
    }

    private View makeTextCard(final String text, boolean weighted, final String itemId) {
        FrameLayout card = new FrameLayout(this);
        card.setBackground(roundBg(CARD, 12));
        card.setPadding(dp(10), dp(6), dp(26), dp(6));
        TextView tv = new TextView(this);
        tv.setText(text.length() > 72 ? text.substring(0, 72) + "…" : text);
        tv.setTextSize(15);
        tv.setTextColor(TEXT);
        tv.setMaxLines(2);
        tv.setEllipsize(TextUtils.TruncateAt.END);
        card.addView(tv, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL));
        card.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                insert(text);
                if (prefs.autoCollapse()) requestHideSelf(0);
            }
        });
        card.setOnLongClickListener(new View.OnLongClickListener() {
            @Override
            public boolean onLongClick(View v) {
                openCardMenu(null, text, itemId);
                return true;
            }
        });
        LinearLayout.LayoutParams p = weighted
                ? new LinearLayout.LayoutParams(0, dp(52), 1f)
                : lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(52));
        p.setMargins(dp(3), dp(3), dp(3), dp(3));
        card.setLayoutParams(p);
        return card;
    }

    private View makeSyncCard(final SyncItem it, boolean weighted) {
        FrameLayout card = new FrameLayout(this);
        card.setBackground(roundBg(CARD, 12));
        card.setPadding(dp(10), dp(6), dp(28), dp(6));

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        if (it.isImage()) {
            ImageView iv = new ImageView(this);
            Bitmap b = thumb(it);
            if (b != null) {
                iv.setImageBitmap(b);
                iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
            } else {
                iv.setBackgroundColor(SEP);
            }
            GradientDrawable ig = new GradientDrawable();
            ig.setColor(SEP);
            ig.setCornerRadius(dp(8));
            iv.setBackground(ig);
            row.addView(iv, new LinearLayout.LayoutParams(dp(40), dp(40)));
            TextView tag = new TextView(this);
            tag.setText("图片 · " + (it.fromPhone() ? "手机发来" : "电脑复制"));
            tag.setTextSize(13);
            tag.setTextColor(SUB);
            tag.setPadding(dp(10), 0, 0, 0);
            row.addView(tag, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        } else {
            TextView tv = new TextView(this);
            tv.setText(it.displayText());
            tv.setTextSize(15);
            tv.setTextColor(TEXT);
            tv.setMaxLines(2);
            tv.setEllipsize(TextUtils.TruncateAt.END);
            row.addView(tv, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        }
        card.addView(row, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL));

        TextView badge = new TextView(this);
        badge.setText(it.fromPhone() ? "📱" : "💻");
        badge.setTextSize(11);
        badge.setGravity(Gravity.CENTER);
        GradientDrawable bd = new GradientDrawable();
        bd.setColor(it.fromPhone() ? Color.parseColor("#E7F8EE") : Color.parseColor("#EEF1FF"));
        bd.setCornerRadius(dp(7));
        badge.setBackground(bd);
        card.addView(badge, new FrameLayout.LayoutParams(dp(20), dp(20),
                Gravity.END | Gravity.TOP));

        card.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (it.isImage()) showImage(it);
                else {
                    insert(it.text);
                    if (prefs.autoCollapse()) requestHideSelf(0);
                }
            }
        });
        card.setOnLongClickListener(new View.OnLongClickListener() {
            @Override
            public boolean onLongClick(View v) {
                openCardMenu(it, it.isImage() ? "图片" : it.displayText(), it.id);
                return true;
            }
        });

        LinearLayout.LayoutParams p = weighted
                ? new LinearLayout.LayoutParams(0, dp(56), 1f)
                : lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(56));
        p.setMargins(dp(3), dp(3), dp(3), dp(3));
        card.setLayoutParams(p);
        return card;
    }

    private Bitmap thumb(SyncItem it) {
        Bitmap cached = thumbs.get(it.id);
        if (cached != null) return cached;
        try {
            Bitmap b = decodeImage(it, 160);
            if (b != null) thumbs.put(it.id, b);
            return b;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static Bitmap decodeImage(SyncItem it, int maxPx) {
        byte[] raw = Base64.decode(it.image, Base64.DEFAULT);
        BitmapFactory.Options probe = new BitmapFactory.Options();
        probe.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(raw, 0, raw.length, probe);
        int longest = Math.max(probe.outWidth, probe.outHeight);
        int sample = 1;
        while (longest / sample > maxPx) sample *= 2;
        BitmapFactory.Options opt = new BitmapFactory.Options();
        opt.inSampleSize = sample;
        return BitmapFactory.decodeByteArray(raw, 0, raw.length, opt);
    }

    // ------------------------------------------------------------ 清空行 (.kbClear)

    private void buildClearRow() {
        TextView clear = new TextView(this);
        // 原型 .kbClear：蓝色 17px 居中，带垃圾桶图标
        clear.setText("清空剪贴板  🗑");
        clear.setTextSize(16);
        clear.setTextColor(BLUE);
        clear.setGravity(Gravity.CENTER);
        clear.setPadding(0, dp(6), 0, dp(6));
        clear.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                openClearConfirm();
            }
        });
        clearRowView = clear;
        clear.setVisibility(prefs.clearBtn() ? View.VISIBLE : View.GONE);
        content.addView(clear, lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(40)));
    }

    // ------------------------------------------------------------ 计算器

    private void buildCalc() {
        calcBox = new LinearLayout(this);
        calcBox.setOrientation(LinearLayout.VERTICAL);
        calcBox.setPadding(dp(10), dp(2), dp(10), dp(2));
        calcBox.setVisibility(View.GONE);

        calcExpr = new TextView(this);
        calcExpr.setTextSize(12);
        calcExpr.setTextColor(SUB);
        calcExpr.setGravity(Gravity.END);
        calcResult = new TextView(this);
        calcResult.setTextSize(22);
        calcResult.setTextColor(BLUE);
        calcResult.setTypeface(Typeface.DEFAULT_BOLD);
        calcResult.setGravity(Gravity.END);
        calcBox.addView(calcExpr, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        calcBox.addView(calcResult, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        String[][] rows = {
                {"7", "8", "9", "÷", "⌫"},
                {"4", "5", "6", "×", "("},
                {"1", "2", "3", "−", ")"},
                {"0", ".", "=", "+", "输入"}
        };
        for (String[] keys : rows) {
            LinearLayout r = new LinearLayout(this);
            r.setOrientation(LinearLayout.HORIZONTAL);
            for (final String k : keys) {
                Button b = keyBtn(k);
                b.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        handleCalcKey(k);
                    }
                });
                LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(0, dp(28), 1f);
                p.setMargins(dp(2), dp(2), dp(2), dp(2));
                r.addView(b, p);
            }
            calcBox.addView(r, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT));
        }
        content.addView(calcBox, lp(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
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
        if ("输入".equals(k)) {
            try {
                insert(CalcEngine.format(CalcEngine.evaluate(calcExpression)));
                toggleCalcMode();
            } catch (Exception ignored) {
            }
        } else if ("⌫".equals(k)) {
            if (!calcExpression.isEmpty()) {
                calcExpression = calcExpression.substring(0, calcExpression.length() - 1);
            }
            updateCalcDisplay();
        } else if (!"=".equals(k)) {
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
            calcResult.setTextColor(BLUE);
        } catch (Exception e) {
            calcResult.setText("—");
            calcResult.setTextColor(SUB);
        }
    }

    // ------------------------------------------------------------ 底行 (.kbKeys)

    private void buildBottomBar() {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(8), dp(2), dp(8), dp(6));

        Button calc = keyBtn("f(x) 计算");
        calc.setTextSize(12);
        calc.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                toggleCalcMode();
            }
        });
        bar.addView(calc, new LinearLayout.LayoutParams(dp(68),
                ViewGroup.LayoutParams.MATCH_PARENT));

        Button space = keyBtn("空格");
        space.setBackgroundColor(Color.WHITE);
        space.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent ev) {
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
            }
        });
        LinearLayout.LayoutParams spaceLp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 1f);
        spaceLp.setMargins(dp(4), 0, dp(4), 0);
        bar.addView(space, spaceLp);

        Button newline = keyBtn("换行");
        newline.setTextSize(15);
        newline.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                insert("\n");
            }
        });
        bar.addView(newline, new LinearLayout.LayoutParams(dp(64),
                ViewGroup.LayoutParams.MATCH_PARENT));

        Button send = keyBtn("发送");
        send.setTextColor(Color.WHITE);
        GradientDrawable sgd = new GradientDrawable();
        sgd.setColor(BLUE);
        sgd.setCornerRadius(dp(9));
        send.setBackground(sgd);
        send.setTypeface(Typeface.DEFAULT_BOLD);
        send.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                sendInputTextToPc();
            }
        });
        send.setOnLongClickListener(new View.OnLongClickListener() {
            @Override
            public boolean onLongClick(View v) {
                insert("\n");
                return true;
            }
        });
        LinearLayout.LayoutParams sendLp = new LinearLayout.LayoutParams(dp(52),
                ViewGroup.LayoutParams.MATCH_PARENT);
        sendLp.setMargins(dp(4), 0, 0, 0);
        bar.addView(send, sendLp);

        content.addView(bar, lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)));
    }

    // ------------------------------------------------------------ 浮层菜单 (.kbPick)

    private void buildMenuOverlay() {
        menuOverlay = new FrameLayout(this);
        menuOverlay.setBackgroundColor(Color.parseColor("#66000000"));
        menuOverlay.setClickable(true);
        menuOverlay.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                closeMenu();
            }
        });
        menuOverlay.setVisibility(View.GONE);

        menuStack = new LinearLayout(this);
        menuStack.setOrientation(LinearLayout.VERTICAL);
        menuStack.setClickable(true);
        menuStack.setPadding(0, dp(6), 0, dp(6));
        menuStack.setBackground(roundBg(CARD, 14));
        FrameLayout.LayoutParams mlp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL);
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
        menuStack.addView(menuTitle("快捷操作 · v1.6 同步"));
        menuStack.addView(menuRow("⚙ 打开完整设置界面", new Runnable() {
            @Override public void run() { closeMenu(); openSettings(); }
        }));

        menuStack.addView(menuRow("⟳ 立即同步（" + syncItems.size() + " 条）", new Runnable() {
            @Override
            public void run() {
                pull(true);
                closeMenu();
            }
        }));
        menuStack.addView(menuRow("↑ 发送输入框文字到电脑", new Runnable() {
            @Override
            public void run() {
                sendInputTextToPc();
                closeMenu();
            }
        }));
        menuStack.addView(menuRow("📋 发送剪贴板文字到电脑", new Runnable() {
            @Override
            public void run() {
                sendClipboardTextToPc();
                closeMenu();
            }
        }));
        menuStack.addView(menuRow("🖼 发送剪贴板图片到电脑", new Runnable() {
            @Override
            public void run() {
                sendClipboardImageToPc();
                closeMenu();
            }
        }));
        menuStack.addView(menuRow("⚙ 打开同步设置（地址 / 配对码）", new Runnable() {
            @Override
            public void run() {
                openSettings();
                closeMenu();
            }
        }));
        menuStack.addView(menuRow("自动同步（每 3 秒）：" + (prefs.syncAuto() ? "开" : "关"), new Runnable() {
            @Override
            public void run() {
                prefs.setSyncAuto(!prefs.syncAuto());
                if (prefs.syncAuto()) startPolling();
                else stopPolling();
                refreshHead();
                openMenu();
            }
        }));
        menuStack.addView(menuRow("列数：" + prefs.columns() + " 列", new Runnable() {
            @Override
            public void run() {
                prefs.setColumns(prefs.columns() == 1 ? 2 : 1);
                refreshList();
                openMenu();
            }
        }));
        menuStack.addView(menuRow("键盘高度：" + prefs.heightDp() + " dp", new Runnable() {
            @Override
            public void run() {
                prefs.setHeightDp(prefs.heightDp() >= 340 ? 220 : prefs.heightDp() + 20);
                applyHeight();
                openMenu();
            }
        }));
        menuStack.addView(menuRow("空格滑动移光标：" + (prefs.spaceCursor() ? "开" : "关"), new Runnable() {
            @Override
            public void run() {
                prefs.setSpaceCursor(!prefs.spaceCursor());
                openMenu();
            }
        }));
        menuStack.addView(menuRow("切换系统键盘", new Runnable() {
            @Override
            public void run() {
                switchIme();
                closeMenu();
            }
        }));
        menuStack.addView(menuRow("关闭菜单", new Runnable() {
            @Override
            public void run() {
                closeMenu();
            }
        }));
    }

    private void openCardMenu(final SyncItem it, final String text, final String id) {
        if (menuOverlay == null) return;
        menuStack.removeAllViews();
        menuOverlay.setVisibility(View.VISIBLE);
        String preview = text.length() > 24 ? text.substring(0, 24) + "…" : text;
        menuStack.addView(menuTitle(preview));
        menuStack.addView(menuRow("插入到输入框", new Runnable() {
            @Override
            public void run() {
                if (it != null && it.isImage()) commitImageToInput(it);
                else insert(text);
                closeMenu();
            }
        }));
        if (it != null && it.isImage()) {
            menuStack.addView(menuRow("放大查看", new Runnable() {
                @Override
                public void run() {
                    closeMenu();
                    showImage(it);
                }
            }));
        }
        menuStack.addView(menuRow("复制到手机剪贴板", new Runnable() {
            @Override
            public void run() {
                if (it != null && it.isImage()) copyImageToClipboard(it);
                else copyTextToClipboard(text);
                closeMenu();
            }
        }));
        menuStack.addView(menuRow("↑ 发送到电脑", new Runnable() {
            @Override
            public void run() {
                if (it != null && it.isImage()) {
                    try {
                        pushImage(Base64.decode(it.image, Base64.DEFAULT), it.mime);
                    } catch (Exception ignored) {
                    }
                } else {
                    sendTextToPc(text);
                }
                closeMenu();
            }
        }));
        if (id != null && !id.isEmpty()) {
            menuStack.addView(menuRow("🗑 从电脑删除这条", new Runnable() {
                @Override
                public void run() {
                    deleteItem(id);
                    closeMenu();
                }
            }));
        }
        menuStack.addView(menuRow("关闭菜单", new Runnable() {
            @Override
            public void run() {
                closeMenu();
            }
        }));
    }

    private void openClearConfirm() {
        if (menuOverlay == null) return;
        menuStack.removeAllViews();
        menuOverlay.setVisibility(View.VISIBLE);
        menuStack.addView(menuTitle("清空电脑上的全部同步记录？"));
        menuStack.addView(menuRow("确认清空", new Runnable() {
            @Override
            public void run() {
                deleteItem(null);
                closeMenu();
            }
        }));
        menuStack.addView(menuRow("取消", new Runnable() {
            @Override
            public void run() {
                closeMenu();
            }
        }));
    }

    private void closeMenu() {
        if (menuOverlay != null) menuOverlay.setVisibility(View.GONE);
    }

    private TextView menuTitle(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(12);
        tv.setTextColor(SUB);
        tv.setGravity(Gravity.CENTER);
        tv.setPadding(0, dp(6), 0, dp(6));
        return tv;
    }

    private Button menuRow(String title, final Runnable action) {
        Button b = new Button(this);
        b.setText(title);
        b.setAllCaps(false);
        b.setTextSize(13);
        b.setTextColor(TEXT);
        b.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
        b.setBackgroundColor(Color.TRANSPARENT);
        b.setPadding(dp(16), 0, dp(16), 0);
        b.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                action.run();
            }
        });
        b.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(34)));
        return b;
    }

    // ------------------------------------------------------------ 图片预览 / 上屏

    private void buildImageOverlay() {
        imgOverlay = new FrameLayout(this);
        imgOverlay.setBackgroundColor(Color.parseColor("#E6000000"));
        imgOverlay.setClickable(true);
        imgOverlay.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                imgOverlay.setVisibility(View.GONE);
            }
        });
        imgOverlay.setVisibility(View.GONE);

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        box.setPadding(dp(16), dp(16), dp(16), dp(16));
        imgBig = new ImageView(this);
        imgBig.setAdjustViewBounds(true);
        imgBig.setScaleType(ImageView.ScaleType.FIT_CENTER);
        box.addView(imgBig, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(190)));

        LinearLayout btns = new LinearLayout(this);
        btns.setOrientation(LinearLayout.HORIZONTAL);
        btns.setGravity(Gravity.CENTER);
        Button insertBtn = new Button(this);
        insertBtn.setText("插入到输入框");
        insertBtn.setAllCaps(false);
        insertBtn.setTextSize(12);
        insertBtn.setTextColor(Color.WHITE);
        insertBtn.setBackground(roundBg(BLUE, 9));
        btns.addView(insertBtn, new LinearLayout.LayoutParams(dp(110), dp(38)));
        Button copyBtn = new Button(this);
        copyBtn.setText("复制");
        copyBtn.setAllCaps(false);
        copyBtn.setTextSize(12);
        copyBtn.setTextColor(TEXT);
        copyBtn.setBackground(roundBg(CARD, 9));
        btns.addView(copyBtn, new LinearLayout.LayoutParams(dp(70), dp(38)));
        box.addView(btns, lp(ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        final SyncItem[] current = new SyncItem[1];
        insertBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (current[0] != null) commitImageToInput(current[0]);
                imgOverlay.setVisibility(View.GONE);
            }
        });
        copyBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (current[0] != null) copyImageToClipboard(current[0]);
                imgOverlay.setVisibility(View.GONE);
            }
        });
        imgOverlay.setTag(current);

        imgOverlay.addView(box, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        container.addView(imgOverlay, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
    }

    @SuppressWarnings("unchecked")
    private void showImage(SyncItem it) {
        try {
            Bitmap b = decodeImage(it, 900);
            if (b == null) {
                toast("图片解码失败");
                return;
            }
            imgBig.setImageBitmap(b);
            Object tag = imgOverlay.getTag();
            if (tag instanceof SyncItem[]) ((SyncItem[]) tag)[0] = it;
            imgOverlay.setVisibility(View.VISIBLE);
        } catch (Exception e) {
            toast("图片解码失败");
        }
    }

    /** 把图片落到本 App 私有目录，并通过 QpImageProvider 暴露 content:// URI。 */
    private Uri writeShareImage(SyncItem it) throws Exception {
        byte[] data = Base64.decode(it.image, Base64.DEFAULT);
        File f = new File(getFilesDir(), "qp_share.png");
        FileOutputStream fos = new FileOutputStream(f);
        fos.write(data);
        fos.flush();
        fos.close();
        Uri uri = Uri.parse("content://" + getPackageName() + ".images/qp_share.png");
        if (!hostPackage.isEmpty()) {
            try {
                grantUriPermission(hostPackage, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
            } catch (Exception ignored) {
            }
        }
        return uri;
    }

    private static String imageMime(SyncItem it) {
        return it.mime == null || it.mime.isEmpty() ? "image/png" : it.mime;
    }

    private void commitImageToInput(SyncItem it) {
        try {
            if (Build.VERSION.SDK_INT < 25) throw new IllegalStateException("系统版本过低");
            Uri uri = writeShareImage(it);
            ClipDescription desc = new ClipDescription("QuickPaste 图片",
                    new String[]{imageMime(it)});
            InputContentInfo info = new InputContentInfo(uri, desc, null);
            InputConnection ic = getCurrentInputConnection();
            if (ic == null || !ic.commitContent(info, 0, null)) {
                throw new IllegalStateException("当前输入框不接受图片");
            }
            toast("图片已插入输入框");
        } catch (Throwable t) {
            copyImageToClipboard(it);
        }
    }

    private void copyImageToClipboard(SyncItem it) {
        // ClipData.newBitmap 在 compileSdk 34 已被移除，改用 content:// URI。
        try {
            Uri uri = writeShareImage(it);
            ClipDescription desc = new ClipDescription("QuickPaste 图片",
                    new String[]{imageMime(it)});
            cm.setPrimaryClip(new ClipData(desc, new ClipData.Item(uri)));
            toast("已复制到剪贴板，长按输入框粘贴");
        } catch (Exception e) {
            toast("复制失败：" + e.getMessage());
        }
    }

    private void copyTextToClipboard(String text) {
        try {
            cm.setPrimaryClip(ClipData.newPlainText("QuickPaste", text));
            toast("已复制到手机剪贴板");
        } catch (Exception e) {
            toast("复制失败");
        }
    }

    // ------------------------------------------------------------ 输入操作

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

    private void openSettings() {
        try {
            Intent i = new Intent(this, MainActivity.class);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            startActivity(i);
        } catch (Exception e) {
            toast("请从桌面打开 QuickPaste 同步键盘");
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

    // ------------------------------------------------------------ UI 辅助

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }

    private LinearLayout.LayoutParams lp(int w, int h) {
        return new LinearLayout.LayoutParams(w, h);
    }

    private GradientDrawable roundBg(int color, int radiusDp) {
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(color);
        gd.setCornerRadius(dp(radiusDp));
        return gd;
    }

    /** 原型 .kbTool / .kbSym：#D4D6DE 灰底、圆角 10（符号为 8） */
    private Button toolBtn(String text) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextSize(17);
        b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setTextColor(TEXT);
        b.setPadding(0, 0, 0, 0);
        b.setBackground(roundBg(KEY_BG, 9));
        b.setMinWidth(dp(30));
        b.setMinimumWidth(dp(30));
        b.setLayoutParams(new LinearLayout.LayoutParams(dp(34), dp(34)));
        return b;
    }

    private Button tabBtn(String text) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextSize(12);
        b.setTextColor(SUB);
        b.setBackgroundColor(Color.TRANSPARENT);
        return b;
    }

    private Button keyBtn(String text) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextSize(15);
        b.setTextColor(TEXT);
        b.setPadding(0, 0, 0, 0);
        b.setBackground(roundBg(KEY_BG, 9));
        return b;
    }

    private void toast(String s) {
        if (!prefs.savedTip() && (s.contains("已保存") || s.contains("已收录"))) return;
        Toast.makeText(this, s, Toast.LENGTH_SHORT).show();
    }

    // ------------------------------------------------------------ v1.6 设置界面

    private void openSettings() {
        if (settings != null) settings.open();
    }

    /** 设置变更后把所有开关即时作用到键盘 */
    private void applySettings() {
        if (clearRowView != null) {
            clearRowView.setVisibility(prefs.clearBtn() ? View.VISIBLE : View.GONE);
        }
        applyHeight();
        refreshHead();
        refreshTabBar();
        refreshSymbols();
        refreshList();
        if (prefs.syncAuto()) startPolling();
        else stopPolling();
    }

    private final ImeSettings.Host hostCallbacks = new ImeSettings.Host() {
        @Override public void onSettingsChanged() { applySettings(); }
        @Override public void onSyncNow() { pull(true); }
        @Override public void onSendInputText() { sendInputTextToPc(); }
        @Override public void onSendClipboardText() { sendClipboardTextToPc(); }
        @Override public void onSendClipboardImage() { sendClipboardImageToPc(); }
        @Override public boolean onAdoptUrl() {
            // 从系统剪贴板采用形如 http://…:8787 的地址
            if (cm == null) return false;
            android.content.ClipData d = cm.getPrimaryClip();
            if (d == null || d.getItemCount() == 0) return false;
            CharSequence cs = d.getItemAt(0).getText();
            if (cs == null) return false;
            String s = cs.toString().trim();
            if (!s.startsWith("http://") && !s.startsWith("https://")) return false;
            if (!s.contains(":8787") && !s.contains(":8")) return false;
            prefs.setSyncUrl(s);
            refreshHead();
            return true;
        }
        @Override public void onResetUrl() {
            prefs.setSyncUrl(Prefs.DEFAULT_URL);
            toast("已重置为默认地址");
            refreshHead();
        }
        @Override public void onClearAll() { deleteItem(null); }
        @Override public void onSwitchKeyboard() { switchIme(); }
        @Override public void onInsertText(String text) {
            insert(text);
            toast("已插入到输入框");
        }
        @Override public void onToast(String text) { toast(text); }
        @Override public String statusTitle() {
            if ("online".equals(syncState)) return "已连接";
            if ("connecting".equals(syncState)) return "连接中";
            if ("error".equals(syncState)) return "连接失败";
            return "未连接";
        }
        @Override public int statusCount() { return syncItems.size(); }
        @Override public String backend() { return backend == null ? "" : backend; }
    };
}
