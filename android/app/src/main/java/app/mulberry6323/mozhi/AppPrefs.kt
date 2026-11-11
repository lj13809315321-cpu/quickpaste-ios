package app.mulberry6323.mozhi

import android.content.Context
import android.content.SharedPreferences

object AppPrefs {
    private const val NAME = "mozhi_prefs"
    private lateinit var sp: SharedPreferences

    fun init(ctx: Context) {
        sp = ctx.getSharedPreferences(NAME, Context.MODE_PRIVATE)
    }

    var serverUrl: String
        get() = sp.getString("server_url", "") ?: ""
        set(v) = sp.edit().putString("server_url", v.trim()).apply()

    var pairCode: String
        get() = sp.getString("pair_code", "") ?: ""
        set(v) = sp.edit().putString("pair_code", v.trim()).apply()

    var bubbleX: Int
        get() = sp.getInt("bubble_x", 0)
        set(v) = sp.edit().putInt("bubble_x", v).apply()

    var bubbleY: Int
        get() = sp.getInt("bubble_y", 160)
        set(v) = sp.edit().putInt("bubble_y", v).apply()
}
