package app.mulberry6323.mozhi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * 悬浮胶囊前台服务：在屏幕边缘常驻一个可拖拽的小球，点按弹出历史面板。
 * 同时监听剪贴板，复制文字即时收入历史。
 */
class FloatingService : Service() {

    private lateinit var wm: WindowManager
    private var bubble: TextView? = null
    private lateinit var params: WindowManager.LayoutParams
    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener { readClip() }

    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var moved = false

    override fun onCreate() {
        super.onCreate()
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notif = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                1,
                notif,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(1, notif)
        }
        showBubble()
        return START_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                "mozhi_floating",
                getString(R.string.floating_channel_name),
                NotificationManager.IMPORTANCE_LOW
            )
            ch.description = getString(R.string.floating_channel_desc)
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(ch)
        }
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, "mozhi_floating")
            .setContentTitle(getString(R.string.app_name))
            .setContentText(getString(R.string.floating_notification))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()

    private fun showBubble() {
        if (bubble != null) return
        val v = TextView(this)
        v.text = "墨"
        v.textSize = 22f
        v.setTextColor(ContextCompat.getColor(this, android.R.color.white))
        v.gravity = Gravity.CENTER
        v.setBackgroundResource(R.drawable.bubble_bg)
        val size = (56 * resources.displayMetrics.density).toInt()
        v.layoutParams = android.view.ViewGroup.LayoutParams(size, size)
        params = WindowManager.LayoutParams(
            size,
            size,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START
        params.x = AppPrefs.bubbleX
        params.y = AppPrefs.bubbleY
        if (params.x < 0) params.x = 0
        v.setOnTouchListener { _, event -> onTouch(v, event) }
        wm.addView(v, params)
        bubble = v
        val cm = getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager
        cm?.addPrimaryClipChangedListener(clipListener)
    }

    private fun onTouch(v: View, e: MotionEvent): Boolean {
        when (e.action) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.rawX
                downY = e.rawY
                moved = false
                startX = params.x
                startY = params.y
            }

            MotionEvent.ACTION_MOVE -> {
                val dx = e.rawX - downX
                val dy = e.rawY - downY
                if (kotlin.math.abs(dx) > 6 || kotlin.math.abs(dy) > 6) moved = true
                params.x = (startX + dx).toInt().coerceAtLeast(0)
                params.y = (startY + dy).toInt().coerceAtLeast(0)
                wm.updateViewLayout(v, params)
            }

            MotionEvent.ACTION_UP -> {
                AppPrefs.bubbleX = params.x
                AppPrefs.bubbleY = params.y
                if (!moved) openPanel()
            }
        }
        return true
    }

    private fun openPanel() {
        val i = Intent(this, PanelActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        i.putExtra("x", params.x)
        i.putExtra("y", params.y)
        startActivity(i)
    }

    private fun readClip() {
        try {
            val cm = getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager ?: return
            val clip = cm.primaryClip ?: return
            if (clip.itemCount <= 0) return
            val txt = clip.getItemAt(0)?.text?.toString() ?: return
            if (txt.isNotBlank()) HistoryStore.addText(txt, "local")
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        bubble?.let { wm.removeView(it) }
        bubble = null
        val cm = getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager
        cm?.removePrimaryClipChangedListener(clipListener)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
