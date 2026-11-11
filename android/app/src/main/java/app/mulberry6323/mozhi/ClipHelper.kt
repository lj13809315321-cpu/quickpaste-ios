package app.mulberry6323.mozhi

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context

object ClipHelper {
    fun copy(ctx: Context, text: String) {
        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        cm.setPrimaryClip(ClipData.newPlainText("mozhi", text))
    }

    fun currentText(ctx: Context): String {
        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return ""
        val clip = cm.primaryClip ?: return ""
        if (clip.itemCount <= 0) return ""
        return clip.getItemAt(0)?.text?.toString() ?: ""
    }
}
