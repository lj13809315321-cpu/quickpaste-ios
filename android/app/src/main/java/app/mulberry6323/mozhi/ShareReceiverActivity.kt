package app.mulberry6323.mozhi

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.ComponentActivity

/** 接收系统“分享/发送”的内容，把文字或文件投进胶囊（对齐 iOS 的拖文件入口）。 */
class ShareReceiverActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent()
        finish()
    }

    private fun fileName(uri: Uri): String {
        val c = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null
        )
        c?.use {
            if (it.moveToFirst()) {
                return it.getString(0) ?: uri.lastPathSegment ?: "文件"
            }
        }
        return uri.lastPathSegment ?: "文件"
    }

    private fun isImage(uri: Uri): Boolean {
        val m = contentResolver.getType(uri) ?: ""
        return m.startsWith("image/")
    }

    @Suppress("DEPRECATION")
    private fun handleIntent() {
        val i = intent
        when (i.action) {
            Intent.ACTION_SEND -> {
                val text = i.getStringExtra(Intent.EXTRA_TEXT)
                val uri = i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (!text.isNullOrEmpty()) HistoryStore.addText(text, "phone")
                if (uri != null) {
                    HistoryStore.addFile(fileName(uri), uri.toString(), "phone")
                    if (AppPrefs.serverUrl.isNotEmpty()) {
                        if (!text.isNullOrEmpty()) SyncManager.push(text)
                        else if (isImage(uri)) SyncManager.pushImage(this, uri)
                    }
                } else if (!text.isNullOrEmpty() && AppPrefs.serverUrl.isNotEmpty()) {
                    SyncManager.push(text)
                }
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                val uris = i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                uris?.forEach { HistoryStore.addFile(fileName(it), it.toString(), "phone") }
            }
        }
        Toast.makeText(this, "已收入胶囊", Toast.LENGTH_SHORT).show()
    }
}
