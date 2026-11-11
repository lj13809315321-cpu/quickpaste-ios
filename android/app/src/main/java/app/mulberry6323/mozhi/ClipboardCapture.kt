package app.mulberry6323.mozhi

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.os.SystemClock

/**
 * 无障碍服务：Android 10+ 限制后台读取剪贴板，开启本服务后可在复制时即时抓取。
 * 同时挂一个 PrimaryClipChangedListener，确保前台/面板打开时也能抓。
 */
class ClipboardCapture : AccessibilityService() {

    private var lastRead = 0L
    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener { readClip() }

    override fun onServiceConnected() {
        super.onServiceConnected()
        val cm = getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager
        cm?.addPrimaryClipChangedListener(clipListener)
        readClip()
    }

    override fun onAccessibilityEvent(event: android.view.accessibility.AccessibilityEvent?) {
        // 复制行为常伴随视图变化，趁机补抓；节流避免高频调用
        val now = SystemClock.elapsedRealtime()
        if (now - lastRead > 350) readClip()
    }

    override fun onInterrupt() {}

    private fun readClip() {
        try {
            val cm = getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager ?: return
            val clip = cm.primaryClip ?: return
            if (clip.itemCount <= 0) return
            val txt = clip.getItemAt(0)?.text?.toString() ?: return
            if (txt.isNotBlank()) {
                lastRead = SystemClock.elapsedRealtime()
                HistoryStore.addText(txt, "local")
            }
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        val cm = getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager
        cm?.removePrimaryClipChangedListener(clipListener)
        super.onDestroy()
    }
}
