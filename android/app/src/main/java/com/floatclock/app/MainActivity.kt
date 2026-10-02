package com.floatclock.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Style
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import com.floatclock.app.ui.HomeScreen
import com.floatclock.app.ui.MeScreen
import com.floatclock.app.ui.RecordsScreen
import com.floatclock.app.ui.StyleScreen
import com.floatclock.app.ui.TimeSourceScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermission()
        setContent {
            FloatClockTheme {
                AppRoot()
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // 回前台自动补校准（10 分钟新鲜度闸门，新鲜则不发请求）
        com.floatclock.app.timesync.TimeSync.ensureFresh()
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }
}

private val Accent = Color(0xFF22D3EE)
private val Accent2 = Color(0xFF5B8CFF)

@Composable
fun FloatClockTheme(content: @Composable () -> Unit) {
    // 产品以深色为主（悬浮场景夜间不刺眼）
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Accent,
            onPrimary = Color(0xFF04101C),
            secondary = Accent2,
            background = Color(0xFF0A0F1C),
            surface = Color(0xFF0A0F1C),
            onSurface = Color(0xFFE8EDF7),
            surfaceVariant = Color(0xFF141B2E),
            onSurfaceVariant = Color(0xFF92A0BA),
        ),
        content = content,
    )
}

private data class TabSpec(val label: String, val icon: ImageVector)

@Composable
fun AppRoot() {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var showTimeSource by rememberSaveable { mutableStateOf(false) }
    val openTimeSource = { showTimeSource = true }
    val tabs = listOf(
        TabSpec("计时", Icons.Filled.Timer),
        TabSpec("样式", Icons.Filled.Style),
        TabSpec("记录", Icons.Filled.List),
        TabSpec("我的", Icons.Filled.Person),
    )
    Box {
        // 时间源页打开时，系统返回键先关页面而不是退出 App
        BackHandler(enabled = showTimeSource) { showTimeSource = false }
        Scaffold(            bottomBar = {
                NavigationBar(containerColor = Color(0xFF0C1220)) {
                    tabs.forEachIndexed { i, spec ->
                        NavigationBarItem(
                            selected = tab == i,
                            onClick = { tab = i },
                            icon = { Icon(spec.icon, contentDescription = spec.label) },
                            label = { Text(spec.label) },
                        )
                    }
                }
            },
        ) { padding ->
            androidx.compose.foundation.layout.Box(Modifier.padding(padding)) {
                when (tab) {
                    0 -> HomeScreen(onOpenTimeSource = openTimeSource)
                    1 -> StyleScreen()
                    2 -> RecordsScreen()
                    else -> MeScreen(onOpenTimeSource = openTimeSource)
                }
            }
        }
        // 时间源页覆盖整屏（含底部导航），带返回键
        if (showTimeSource) {
            androidx.compose.foundation.layout.Box(Modifier.fillMaxSize()) {
                TimeSourceScreen(onBack = { showTimeSource = false })
            }
        }
    }
}
