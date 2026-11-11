package app.mulberry6323.mozhi

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import app.mulberry6323.mozhi.ui.main.MainScreen
import app.mulberry6323.mozhi.ui.theme.MozhiTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MozhiTheme {
                MainScreen()
            }
        }
    }
}
