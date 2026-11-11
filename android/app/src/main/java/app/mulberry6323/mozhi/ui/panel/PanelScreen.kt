package app.mulberry6323.mozhi.ui.panel

import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Button
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.mulberry6323.mozhi.ClipEntry
import app.mulberry6323.mozhi.ClipHelper
import app.mulberry6323.mozhi.HistoryStore
import app.mulberry6323.mozhi.PhrasesStore
import app.mulberry6323.mozhi.SyncManager
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun PanelScreen(x: Int, y: Int, onClose: () -> Unit) {
    val context = LocalContext.current
    val items by HistoryStore.items.collectAsState()
    val phrases by PhrasesStore.phrases.collectAsState()
    var query by remember { mutableStateOf("") }

    val shown = remember(items, query) {
        val sorted = items.sortedWith(
            compareByDescending<ClipEntry> { it.pinned }.thenByDescending { it.ts }
        )
        if (query.isBlank()) sorted
        else sorted.filter { it.display().contains(query, ignoreCase = true) }
    }

    LaunchedEffect(Unit) {
        val t = ClipHelper.currentText(context)
        if (t.isNotBlank()) HistoryStore.addText(t, "local")
    }

    // 全屏透明蒙层：点空白处关闭
    Surface(
        color = Color.Black.copy(alpha = 0.30f),
        modifier = Modifier
            .fillMaxSize()
            .clickable { onClose() }
    ) {
        Box(Modifier.fillMaxSize()) {
            // 玻璃面板：动态取色 + 半透明实体，体现玻璃拟态质感
            Surface(
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.86f),
                tonalElevation = 8.dp,
                shape = RoundedCornerShape(28.dp),
                modifier = Modifier
                    .align(Alignment.Center)
                    .fillMaxWidth(0.92f)
                    .fillMaxHeight(0.82f)
                    .clickable { }
            ) {
                Column(Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("墨指 · 剪贴板", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.weight(1f))
                        IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "关闭") }
                    }

                    SearchField(query) { query = it }

                    Spacer(Modifier.height(8.dp))

                    if (phrases.isNotEmpty()) {
                        Text("常用语", style = MaterialTheme.typography.labelMedium)
                        Row(Modifier.horizontalScroll(rememberScrollState())) {
                            phrases.forEach { p ->
                                AssistChip(
                                    onClick = {
                                        ClipHelper.copy(context, p)
                                        Toast.makeText(context, "已复制", Toast.LENGTH_SHORT).show()
                                        onClose()
                                    },
                                    label = { Text(p, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                    modifier = Modifier.padding(end = 6.dp)
                                )
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                    }

                    LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
                        items(shown, key = { it.id }) { e ->
                            ClipCard(
                                e = e,
                                onCopy = { copyItem(context, e, onClose) },
                                onPin = { HistoryStore.togglePin(e.id) },
                                onDelete = { HistoryStore.remove(e.id) },
                                onShare = { shareItem(context, e) }
                            )
                            Spacer(Modifier.height(8.dp))
                        }
                    }

                    Spacer(Modifier.height(8.dp))
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Button(
                            onClick = {
                                SyncManager.pull { ok, c ->
                                    Toast.makeText(
                                        context,
                                        if (ok) "已从电脑拉取 $c 条" else "同步失败，检查地址/配对码",
                                        Toast.LENGTH_SHORT
                                    ).show()
                                }
                            },
                            modifier = Modifier.weight(1f)
                        ) { Text("同步电脑", fontSize = 13.sp) }
                        Button(
                            onClick = { shareText(context, HistoryStore.exportAll()) },
                            modifier = Modifier.weight(1f)
                        ) { Text("导出全部", fontSize = 13.sp) }
                        TextButton(
                            onClick = {
                                HistoryStore.clear()
                                Toast.makeText(context, "已清空", Toast.LENGTH_SHORT).show()
                            },
                            modifier = Modifier.weight(1f)
                        ) { Text("清空", fontSize = 13.sp) }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SearchField(value: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        placeholder = { Text("搜索历史…") },
        singleLine = true,
        leadingIcon = { Icon(Icons.Filled.Search, null) },
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = {}),
        modifier = Modifier.fillMaxWidth()
    )
}

@Composable
private fun ClipCard(
    e: ClipEntry,
    onCopy: () -> Unit,
    onPin: () -> Unit,
    onDelete: () -> Unit,
    onShare: () -> Unit
) {
    Card(
        onClick = onCopy,
        shape = RoundedCornerShape(18.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(Modifier.padding(12.dp)) {
            Text(
                e.display(),
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyMedium
            )
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                val src = when (e.source) {
                    "pc" -> "💻"
                    "phone" -> "📱"
                    else -> "📋"
                }
                Text(
                    "$src ${fmtTime(e.ts)}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onPin, modifier = Modifier.size(34.dp)) {
                    Icon(
                        if (e.pinned) Icons.Filled.Star else Icons.Filled.StarBorder,
                        if (e.pinned) "取消置顶" else "置顶"
                    )
                }
                IconButton(onClick = onDelete, modifier = Modifier.size(34.dp)) {
                    Icon(Icons.Filled.Delete, "删除")
                }
                if (e.kind == "file") {
                    IconButton(onClick = onShare, modifier = Modifier.size(34.dp)) {
                        Icon(Icons.Filled.Share, "分享")
                    }
                }
            }
        }
    }
}

private fun copyItem(context: Context, e: ClipEntry, onClose: () -> Unit) {
    if (e.kind == "file" && e.data.isNotEmpty()) {
        shareItem(context, e)
    } else {
        ClipHelper.copy(context, e.text)
        Toast.makeText(context, "已复制", Toast.LENGTH_SHORT).show()
        onClose()
    }
}

private fun shareItem(context: Context, e: ClipEntry) {
    val intent = Intent(Intent.ACTION_SEND)
    if (e.kind == "file" && e.data.isNotEmpty()) {
        intent.type = "application/octet-stream"
        intent.putExtra(Intent.EXTRA_STREAM, android.net.Uri.parse(e.data))
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    } else {
        intent.type = "text/plain"
        intent.putExtra(Intent.EXTRA_TEXT, e.text)
    }
    context.startActivity(Intent.createChooser(intent, "分享到"))
}

private fun shareText(context: Context, text: String) {
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }
    context.startActivity(Intent.createChooser(intent, "导出全部"))
}

private fun fmtTime(ts: Long): String {
    if (ts == 0L) return ""
    return try {
        SimpleDateFormat("MM-dd HH:mm", Locale.CHINA).format(Date(ts))
    } catch (_: Exception) {
        ""
    }
}
