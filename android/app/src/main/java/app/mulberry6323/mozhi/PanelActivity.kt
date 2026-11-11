package app.mulberry6323.mozhi

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import app.mulberry6323.mozhi.ui.panel.PanelScreen
import app.mulberry6323.mozhi.ui.theme.MozhiTheme

class PanelActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val x = intent.getIntExtra("x", 0)
        val y = intent.getIntExtra("y", 0)
        setContent {
            MozhiTheme {
                PanelScreen(x = x, y = y, onClose = { finish() })
            }
        }
    }
}
