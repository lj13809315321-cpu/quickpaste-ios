package app.mulberry6323.mozhi

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/** 局域网同步电脑端（复用纯 Java 的 SyncClient）。 */
object SyncManager {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun pull(onResult: (ok: Boolean, count: Int) -> Unit) {
        val url = AppPrefs.serverUrl
        if (url.isEmpty()) {
            onResult(false, 0)
            return
        }
        scope.launch {
            try {
                val client = SyncClient(url, AppPrefs.pairCode)
                val r = client.fetch(100)
                if (r.ok) {
                    r.items.forEach { HistoryStore.addText(it.displayText(), "pc") }
                    withContext(Dispatchers.Main) { onResult(true, r.count) }
                } else {
                    withContext(Dispatchers.Main) { onResult(false, 0) }
                }
            } catch (_: Exception) {
                withContext(Dispatchers.Main) { onResult(false, 0) }
            }
        }
    }

    fun push(text: String) {
        val url = AppPrefs.serverUrl
        if (url.isEmpty() || text.isBlank()) return
        scope.launch {
            try {
                SyncClient(url, AppPrefs.pairCode).pushText(text)
            } catch (_: Exception) {
            }
        }
    }

    fun pushImage(ctx: Context, uri: Uri) {
        val url = AppPrefs.serverUrl
        if (url.isEmpty()) return
        scope.launch {
            try {
                val bytes = ctx.contentResolver.openInputStream(uri)?.use { readAll(it) } ?: return@launch
                val mime = ctx.contentResolver.getType(uri) ?: "image/png"
                SyncClient(url, AppPrefs.pairCode).pushImage(bytes, mime)
            } catch (_: Exception) {
            }
        }
    }

    fun delete(id: String) {
        val url = AppPrefs.serverUrl
        if (url.isEmpty() || id.isEmpty()) return
        scope.launch {
            try {
                SyncClient(url, AppPrefs.pairCode).delete(id)
            } catch (_: Exception) {
            }
        }
    }

    private fun readAll(input: java.io.InputStream): ByteArray {
        val bos = ByteArrayOutputStream()
        val buf = ByteArray(4096)
        var n: Int
        while (input.read(buf).also { n = it } > 0) bos.write(buf, 0, n)
        return bos.toByteArray()
    }
}
