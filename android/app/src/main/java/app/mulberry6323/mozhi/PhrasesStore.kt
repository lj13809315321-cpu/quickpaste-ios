package app.mulberry6323.mozhi

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import java.io.File

object PhrasesStore {
    private val _phrases = MutableStateFlow<List<String>>(emptyList())
    val phrases: StateFlow<List<String>> = _phrases.asStateFlow()

    private var file: File? = null
    private const val MAX = 100

    fun load(ctx: Context) {
        file = File(ctx.filesDir, "phrases.json")
        val list = mutableListOf<String>()
        try {
            if (file!!.exists()) {
                val arr = JSONArray(file!!.readText())
                for (i in 0 until arr.length()) {
                    list.add(arr.optString(i, ""))
                }
            }
        } catch (_: Exception) {
        }
        _phrases.value = list
    }

    private fun save() {
        file ?: return
        try {
            val arr = JSONArray()
            _phrases.value.forEach { arr.put(it) }
            file!!.writeText(arr.toString())
        } catch (_: Exception) {
        }
    }

    fun add(text: String) {
        val t = text.trim()
        if (t.isEmpty() || _phrases.value.contains(t)) return
        _phrases.value = (_phrases.value + t).take(MAX)
        save()
    }

    fun remove(text: String) {
        _phrases.value = _phrases.value.filter { it != text }
        save()
    }
}
