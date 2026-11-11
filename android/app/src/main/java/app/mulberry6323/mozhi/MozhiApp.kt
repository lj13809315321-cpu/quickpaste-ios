package app.mulberry6323.mozhi

import android.app.Application

class MozhiApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AppPrefs.init(this)
        HistoryStore.load(this)
        PhrasesStore.load(this)
    }
}
