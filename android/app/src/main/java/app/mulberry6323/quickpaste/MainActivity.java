package app.mulberry6323.quickpaste;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.Menu;
import android.view.MenuItem;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebChromeClient.FileChooserParams;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.Toast;

/**
 * QuickPaste 同步版（安卓）：全屏 WebView 打开电脑上的同步服务页面。
 *
 * 功能（文字 / 图片 / 缩略图 / 来源图标 / 发送图片）全部由电脑端 v1.6 同步页提供，
 * App 只负责：记住电脑地址、允许 HTTP 局域网、支持 <input type=file> 选图发图。
 * 前提：电脑端 QuickPaste 同步服务已启动，且手机与电脑在同一 WiFi。
 */
public class MainActivity extends Activity {

    private static final String PREF = "quickpaste_sync";
    private static final String KEY_URL = "server_url";
    private static final int REQ_FILE = 1001;

    private WebView web;
    private ValueCallback<Uri[]> filePathCallback;
    private SharedPreferences prefs;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences(PREF, MODE_PRIVATE);

        web = new WebView(this);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setBuiltInZoomControls(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        s.setMediaPlaybackRequiresUserGesture(false);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onReceivedError(WebView view, int code, String description, String failingUrl) {
                String saved = prefs.getString(KEY_URL, "");
                if (failingUrl != null && saved.startsWith(failingUrl.substring(0, Math.min(failingUrl.length(), saved.length())))) {
                    Toast.makeText(MainActivity.this,
                            "连不上电脑（" + description + "）\n请确认电脑服务已启动、同一 WiFi，右上角菜单可改地址",
                            Toast.LENGTH_LONG).show();
                }
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams params) {
                if (filePathCallback != null) filePathCallback.onReceiveValue(null);
                filePathCallback = cb;
                try {
                    startActivityForResult(params.createIntent(), REQ_FILE);
                } catch (Exception e) {
                    filePathCallback = null;
                    Toast.makeText(MainActivity.this, "无法打开文件选择器", Toast.LENGTH_SHORT).show();
                    return false;
                }
                return true;
            }
        });

        String url = prefs.getString(KEY_URL, "");
        if (url.isEmpty()) showUrlDialog(true);
        else web.loadUrl(url + "/");
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != REQ_FILE || filePathCallback == null) return;
        Uri[] results = null;
        if (res == RESULT_OK && data != null) {
            if (data.getDataString() != null) {
                results = new Uri[]{Uri.parse(data.getDataString())};
            } else if (data.getClipData() != null) {
                int n = data.getClipData().getItemCount();
                results = new Uri[n];
                for (int i = 0; i < n; i++) results[i] = data.getClipData().getItemAt(i).getUri();
            }
        }
        filePathCallback.onReceiveValue(results);
        filePathCallback = null;
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        menu.add(0, 1, 0, "修改电脑地址");
        menu.add(0, 2, 1, "刷新");
        return true;
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        if (item.getItemId() == 1) showUrlDialog(false);
        else if (item.getItemId() == 2) web.reload();
        return true;
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK && web.canGoBack()) {
            web.goBack();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    private void showUrlDialog(final boolean first) {
        final EditText et = new EditText(this);
        et.setInputType(InputType.TYPE_TEXT_VARIATION_URI);
        et.setHint("http://192.168.1.2:8787");
        String old = prefs.getString(KEY_URL, "");
        et.setText(old.isEmpty() ? "http://192.168.1.2:8787" : old);
        et.setSelection(et.getText().length());

        AlertDialog.Builder b = new AlertDialog.Builder(this)
                .setTitle(first ? "连接电脑" : "修改电脑地址")
                .setMessage("请先在电脑上启动 QuickPaste 同步服务，并确保手机与电脑连同一 WiFi。\n\n"
                        + "填写电脑地址（端口默认 8787），保存后会自动记住。")
                .setView(et)
                .setCancelable(false)
                .setPositiveButton("连接", (d, w) -> {
                    String u = normalize(et.getText().toString());
                    prefs.edit().putString(KEY_URL, u).apply();
                    web.loadUrl(u + "/");
                });
        if (!first) b.setNegativeButton("取消", null);
        b.show();
    }

    private static String normalize(String raw) {
        String u = raw == null ? "" : raw.trim();
        if (u.isEmpty()) u = "http://192.168.1.2:8787";
        if (!u.startsWith("http://") && !u.startsWith("https://")) u = "http://" + u;
        while (u.endsWith("/")) u = u.substring(0, u.length() - 1);
        return u;
    }
}
