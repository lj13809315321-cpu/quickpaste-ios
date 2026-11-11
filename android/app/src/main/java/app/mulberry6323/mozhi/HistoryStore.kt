package app.mulberry6323.mozhi

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class ClipEntry(
    val id: String,
    val text: String,
    val ts: Long,
    val pinned: Boolean = false,
    val source: String = "local", // local / pc / phone
    val kind: String = "text",     // text / file
    val data: String = ""          // 文件 uri（kind=file 时）
) {
    fun display(): String {
        val t = text.replace(Regex("\\s+"), " ").trim()
        return if (t.isEmpty()) "（空白内容）" else t
    }
}

object HistoryStore {
    private val _items = MutableStateFlow<List<ClipEntry>>(emptyList())
    val items: StateFlow<List<ClipEntry>> = _items.asStateFlow()

    private var file: File? = null
    private const val MAX = 200

    fun load(ctx: Context) {
        file = File(ctx.filesDir, "history.json")
        val list = mutableListOf<ClipEntry>()
        try {
            if (file!!.exists()) {
                val arr = JSONArray(file!!.readText())
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    list.add(
                        ClipEntry(
                            id = o.optString("id", UUID.randomUUID().toString()),
                            text = o.optString("text", ""),
                            ts = o.optLong("ts", 0L),
                            pinned = o.optBoolean("pinned", false),
                            source = o.optString("source", "local"),
                            kind = o.optString("kind", "text"),
                            data = o.optString("data", "")
                        )
                    )
                }
            }
        } catch (_: Exception) {
        }
        _items.value = list
    }

    private fun save() {
        file ?: return
        try {
            val arr = JSONArray()
            for (e in _items.value) {
                val o = JSONObject()
                o.put("id", e.id)
                o.put("text", e.text)
                o.put("ts", e.ts)
                o.put("pinned", e.pinned)
                o.put("source", e.source)
                o.put("kind", e.kind)
                o.put("data", e.data)
                arr.put(o)
            }
            file!!.writeText(arr.toString())
        } catch (_: Exception) {
        }
    }

    fun addText(text: String, source: String = "local") {
        val t = text.trim()
        if (t.isEmpty()) return
        val cur = _items.value
        val last = cur.firstOrNull()
        val next = if (last != null && last.text == t && last.kind == "text") {
            cur.mapIndexed { i, e -> if (i == 0) e.copy(ts = System.currentTimeMillis()) else e }
        } else {
            listOf(
                ClipEntry(
                    id = UUID.randomUUID().toString(),
                    text = t,
                    ts = System.currentTimeMillis(),
                    source = source
                )
            ) + cur
        }
        _items.value = next.take(MAX)
        save()
    }

    fun addFile(name: String, uri: String, source: String = "phone") {
        val t = name.trim()
        if (t.isEmpty()) return
        val next =
            listOf(
                ClipEntry(
                    id = UUID.randomUUID().toString(),
                    text = t,
                    ts = System.currentTimeMillis(),
                    source = source,
                    kind = "file",
                    data = uri
                )
            ) + _items.value
        _items.value = next.take(MAX)
        save()
    }

    fun remove(id: String) {
        _items.value = _items.value.filter { it.id != id }
        save()
    }

    fun togglePin(id: String) {
        _items.value = _items.value.map { if (it.id == id) it.copy(pinned = !it.pinned) else it }
        save()
    }

    fun clear() {
        _items.value = emptyList()
        save()
    }

    fun exportAll(): String = _items.value.joinToString("\n") { it.display() }
}
