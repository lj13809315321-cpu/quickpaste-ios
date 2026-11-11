package app.mulberry6323.mozhi.ui.main

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import app.mulberry6323.mozhi.AppPrefs
import app.mulberry6323.mozhi.FloatingService
import app.mulberry6323.mozhi.PhrasesStore
import app.mulberry6323.mozhi.SyncManager

@Composable
fun MainScreen() {
    val context = LocalContext.current
    val phrases by PhrasesStore.phrases.collectAsState()
    var serverUrl by remember { mutableStateOf(AppPrefs.serverUrl) }
    var pairCode by remember { mutableStateOf(AppPrefs.pairCode) }
    var bubbleOn by remember { mutableStateOf(Settings.canDrawOverlays(context)) }
    var newPhrase by remember { mutableStateOf("") }
    var accOn by remember { mutableStateOf(isAccessibilityOn(context)) }

    val notifPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) {}

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("墨指") },
                actions = {
                    Text(
                        "悬浮胶囊版 v1.8.34",
                        style = MaterialTheme.typography.labelSmall,
                        modifier = Modifier.padding(end = 12.dp)
                    )
                }
            )
        }
    ) { padding ->
        Column(
            Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("把复制的内容收进悬浮胶囊", style = MaterialTheme.typography.titleLarge)
                    Text(
                        "点按屏幕边缘的「墨」球即可查看 / 粘贴历史；开启无障碍可后台连续抓取。",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }

            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("悬浮胶囊", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.size(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            if (bubbleOn) "胶囊运行中" else "胶囊未开启",
                            Modifier.weight(1f)
                        )
                        Switch(
                            checked = bubbleOn,
                            onCheckedChange = { want ->
                                if (want) {
                                    if (!Settings.canDrawOverlays(context)) {
                                        context.startActivity(
                                            Intent(
                                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                                android.net.Uri.fromParts(
                                                    "package",
                                                    context.packageName,
                                                    null
                                                )
                                            )
                                        )
                                    } else {
                                        startBubble(context)
                                        if (Build.VERSION.SDK_INT >= 33) {
                                            notifPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                        }
                                        bubbleOn = true
                                    }
                                } else {
                                    context.stopService(Intent(context, FloatingService::class.java))
                                    bubbleOn = false
                                }
                            }
                        )
                    }
                }
            }

            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("后台连续抓取（无障碍）", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.size(8.dp))
                    Text(
                        if (accOn) "已开启" else "未开启：复制后将即时收入历史（Android 10+ 限制后台读剪贴板）",
                        style = MaterialTheme.typography.bodySmall
                    )
                    Spacer(Modifier.size(8.dp))
                    Button(onClick = {
                        context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        accOn = isAccessibilityOn(context)
                    }) { Text("前往开启") }
                }
            }

            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("局域网同步电脑端", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.size(8.dp))
                    OutlinedTextField(
                        value = serverUrl,
                        onValueChange = { serverUrl = it },
                        placeholder = { Text("电脑端地址，如 http://192.168.1.2:8787") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(Modifier.size(6.dp))
                    OutlinedTextField(
                        value = pairCode,
                        onValueChange = { pairCode = it },
                        placeholder = { Text("配对码（电脑端设置，可空）") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(Modifier.size(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Button(
                            onClick = {
                                AppPrefs.serverUrl = serverUrl
                                AppPrefs.pairCode = pairCode
                                Toast.makeText(context, "已保存", Toast.LENGTH_SHORT).show()
                            },
                            modifier = Modifier.weight(1f)
                        ) { Text("保存", fontSize = 13.sp) }
                        Button(
                            onClick = {
                                AppPrefs.serverUrl = serverUrl
                                AppPrefs.pairCode = pairCode
                                SyncManager.pull { ok, c ->
                                    Toast.makeText(
                                        context,
                                        if (ok) "已从电脑拉取 $c 条" else "同步失败，检查地址/配对码",
                                        Toast.LENGTH_SHORT
                                    ).show()
                                }
                            },
                            modifier = Modifier.weight(1f)
                        ) { Text("立即同步", fontSize = 13.sp) }
                    }
                }
            }

            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("常用语", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.size(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        OutlinedTextField(
                            value = newPhrase,
                            onValueChange = { newPhrase = it },
                            placeholder = { Text("添加一条常用语") },
                            singleLine = true,
                            modifier = Modifier.weight(1f)
                        )
                        Button(onClick = {
                            PhrasesStore.add(newPhrase)
                            newPhrase = ""
                        }) { Text("添加") }
                    }
                    Spacer(Modifier.size(8.dp))
                    phrases.forEach { p ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                p,
                                Modifier.weight(1f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            IconButton(
                                onClick = { PhrasesStore.remove(p) },
                                modifier = Modifier.size(34.dp)
                            ) { Icon(Icons.Filled.Delete, "删除") }
                        }
                    }
                }
            }
        }
    }
}

private fun startBubble(context: Context) {
    val i = Intent(context, FloatingService::class.java)
    ContextCompat.startForegroundService(context, i)
}

private fun isAccessibilityOn(context: Context): Boolean {
    val s = Settings.Secure.getString(
        context.contentResolver,
        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
    ) ?: return false
    return s.split(":").any { it.contains("ClipboardCapture") }
}
