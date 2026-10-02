@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.floatclock.app.ui

import android.content.ActivityNotFoundException
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.floatclock.app.AppState
import com.floatclock.app.engine.BgKind
import com.floatclock.app.engine.Fmt
import com.floatclock.app.engine.Mode
import com.floatclock.app.engine.RunState
import com.floatclock.app.perm.Permissions
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val Mono = FontFamily.Monospace

/**
 * 全局 tick：App 内时钟读数取 TimeSync.now() + 显示延迟补偿（按屏幕中位）。
 * 时钟秒级显示对齐到「整秒边界 − 补偿」，让秒翻转尽量落在真实边界上；
 * 毫秒/秒表模式保持快采样。引擎类读数仍用系统时钟。
 */
@Composable
fun NowTick(): Long {
    val ctx = LocalContext.current
    var now by remember { mutableLongStateOf(com.floatclock.app.timesync.TimeSync.now()) }
    LaunchedEffect(Unit) {
        val comp = com.floatclock.app.engine.DisplayTiming.compMs(
            com.floatclock.app.engine.DisplayTiming.refreshRateHz(ctx), 0.5f,
        ).toLong()
        while (true) {
            now = com.floatclock.app.timesync.TimeSync.now() + comp
            val clockSecondsOnly = AppState.mode.value == Mode.CLOCK && !AppState.style.value.showMillis
            val delayMs = if (clockSecondsOnly)
                (com.floatclock.app.timesync.TimeSync.msToNextSecond() - comp).coerceAtLeast(40L)
            else 60L
            delay(delayMs)
        }
    }
    return now
}

// ═══════════════ 首页 ═══════════════

@Composable
fun HomeScreen(onOpenTimeSource: () -> Unit = {}) {
    val ctx = LocalContext.current
    val style by AppState.style.collectAsState()
    val mode by AppState.mode.collectAsState()
    val floatVisible by AppState.floatVisible.collectAsState()
    val cdState by AppState.cdState.collectAsState()
    val cdTotalMin by AppState.cdTotalMin.collectAsState()
    val tsSelectedId by com.floatclock.app.timesync.TimeSync.selectedId.collectAsState()
    val tsResult = com.floatclock.app.timesync.TimeSync.currentResult()
    val now = NowTick()
    var showOnboarding by remember { mutableStateOf(!Permissions.overlayGranted(ctx)) }
    var showCustomCd by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
    ) {
        Spacer(Modifier.height(20.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("兔时笺", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text(Fmt.dateLine(now) + " " + Fmt.weekLine(now),
                    fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            PermPill(granted = Permissions.overlayGranted(ctx)) { showOnboarding = true }
        }

        // 大时钟（点击切回时钟模式 —— 秒表/倒计时模式下唯一的返回入口）
        val (hms, sec, _) = Fmt.clock(style.hour24, true, 0, now)
        Text(
            buildString { append(hms); append(sec) },
            fontSize = 54.sp, fontFamily = Mono, fontWeight = FontWeight.Bold,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 14.dp)
                .clickable {
                    if (AppState.mode.value != Mode.CLOCK) {
                        AppState.mode.value = Mode.CLOCK
                        com.floatclock.app.service.TimerService.refresh(ctx)
                    }
                },
            color = Color(0xFFE8EDF7),
        )

        // 时间源状态（点击进设置页）
        val selSrc = com.floatclock.app.timesync.Sources.byId(tsSelectedId)
        Box(
            Modifier
                .clip(RoundedCornerShape(99.dp))
                .background(Color(0x1422D3EE))
                .border(1.dp, Color(0x4022D3EE), RoundedCornerShape(99.dp))
                .clickable(onClick = onOpenTimeSource)
                .padding(horizontal = 12.dp, vertical = 5.dp),
        ) {
            Text(
                when {
                    selSrc.kind == com.floatclock.app.timesync.SourceKind.DEVICE -> "⏱ 设备时间"
                    tsResult?.ok == true -> "⏱ ${selSrc.name} · ${com.floatclock.app.timesync.TimeSync.fmtOffset(tsResult.offsetMs)}"
                    else -> "⏱ ${selSrc.name} · 待校准"
                },
                fontSize = 11.sp, color = Color(0xFF7EDCE8),
            )
        }

        // 非时钟模式提示：悬浮窗正显示秒表/倒计时，点大钟切回
        if (mode != Mode.CLOCK) {
            Text(
                "悬浮窗正在显示${if (mode == Mode.STOPWATCH) "秒表" else "倒计时"} · 点击大钟切回时钟",
                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )
        }

        // 秒表卡
        ModeCard(
            title = "秒表",
            color = Color(0xFF34D399),
            active = mode == Mode.STOPWATCH,
            onActivate = { AppState.mode.value = Mode.STOPWATCH },
        ) {
            val (main, _, msPart) = Fmt.stopwatch(AppState.stopwatch.elapsed(), style.millisDigits.coerceAtLeast(1))
            Text(main + msPart, fontFamily = Mono, fontSize = 34.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(vertical = 6.dp))
            Row {
                Button(onClick = { AppState.mode.value = Mode.STOPWATCH; ensureFloat(ctx); AppState.toggleStopwatch() }) {
                    Text(if (AppState.stopwatch.running) "暂停" else if (AppState.stopwatch.elapsed() > 0) "继续" else "启动")
                }
                Spacer(Modifier.width(10.dp))
                OutlinedButton(onClick = { AppState.resetStopwatch() }) { Text("重置") }
            }
        }

        // 倒计时卡
        ModeCard(
            title = "倒计时",
            color = Color(0xFFFFB454),
            active = mode == Mode.COUNTDOWN,
            onActivate = { AppState.mode.value = Mode.COUNTDOWN },
        ) {
            // FlowRow：窄屏自动换行，不再挤压变形
            val cdPresets = remember { listOf(1, 3, 5, 10, 25, 60) }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                cdPresets.forEach { m ->
                    FilterChip(
                        selected = cdTotalMin == m && cdState == RunState.IDLE,
                        onClick = { AppState.setCountdownMinutes(m) },
                        label = { Text("${m}′") },
                    )
                }
                val custom = cdTotalMin !in cdPresets
                FilterChip(
                    selected = custom && cdState == RunState.IDLE,
                    onClick = { showCustomCd = true },
                    label = { Text(if (custom) "自定义 ${cdTotalMin}′" else "自定义") },
                )
            }
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    Fmt.countdown(AppState.countdown.remain()),
                    fontFamily = Mono, fontSize = 30.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f),
                )
                Button(onClick = { AppState.mode.value = Mode.COUNTDOWN; ensureFloat(ctx); AppState.toggleCountdown() }) {
                    Text(
                        when (cdState) {
                            RunState.RUNNING -> "暂停"
                            RunState.PAUSED -> "继续"
                            RunState.FINISHED -> "重新开始"
                            RunState.IDLE -> "开始"
                        }
                    )
                }
            }
        }

        // 悬浮窗状态卡
        Card2 {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("悬浮窗", fontWeight = FontWeight.SemiBold)
                    Text(
                        if (Permissions.overlayGranted(ctx)) (if (floatVisible) "显示中 · 可切到其它应用查看" else "已授权 · 未开启")
                        else "未授权悬浮窗权限",
                        fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = floatVisible,
                    onCheckedChange = { on -> if (on) ensureFloat(ctx) else AppState.hideFloat() },
                )
            }
        }

        Spacer(Modifier.height(96.dp))
    }

    if (showOnboarding && !Permissions.overlayGranted(ctx)) {
        OnboardingSheet(onDone = { showOnboarding = false })
    }

    // 自定义倒计时长（分钟）
    if (showCustomCd) {
        var cdText by remember {
            mutableStateOf(if (cdTotalMin in listOf(1, 3, 5, 10, 25, 60)) "" else cdTotalMin.toString())
        }
        AlertDialog(
            onDismissRequest = { showCustomCd = false },
            title = { Text("自定义倒计时") },
            text = {
                OutlinedTextField(
                    value = cdText,
                    onValueChange = { cdText = it.filter { c -> c.isDigit() }.take(4) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    label = { Text("分钟（1 ~ 9999）") },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    cdText.toIntOrNull()?.let { m ->
                        if (m in 1..9999) {
                            AppState.setCountdownMinutes(m)
                            showCustomCd = false
                        }
                    }
                }) { Text("设置") }
            },
            dismissButton = { TextButton(onClick = { showCustomCd = false }) { Text("取消") } },
        )
    }
}

private fun ensureFloat(ctx: android.content.Context) {
    if (Permissions.overlayGranted(ctx)) AppState.showFloat()
}

@Composable
private fun PermPill(granted: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .clip(RoundedCornerShape(99.dp))
            .background(if (granted) Color(0x2234D399) else Color(0x2FFFB454))
            .border(1.dp, if (granted) Color(0x6634D399) else Color(0x66FFB454), RoundedCornerShape(99.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 5.dp),
    ) {
        Text(
            if (granted) "● 悬浮窗已开启" else "● 去开启悬浮窗",
            fontSize = 11.sp,
            color = if (granted) Color(0xFF7EF0C5) else Color(0xFFFFB454),
        )
    }
}

@Composable
private fun ModeCard(
    title: String,
    color: Color,
    active: Boolean,
    onActivate: () -> Unit,
    content: @Composable () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(if (active) color.copy(alpha = 0.08f) else Color(0x0DFFFFFF))
            .border(1.dp, if (active) color.copy(alpha = 0.45f) else Color(0x1FFFFFFF), RoundedCornerShape(18.dp))
            .clickable(onClick = onActivate)
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).clip(CircleShape).background(color))
            Spacer(Modifier.width(8.dp))
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        }
        Spacer(Modifier.height(6.dp))
        content()
    }
}

@Composable
private fun Card2(content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0x0DFFFFFF))
            .border(1.dp, Color(0x1FFFFFFF), RoundedCornerShape(18.dp))
            .padding(14.dp),
    ) { content() }
}

// ═══════════════ 权限引导 ═══════════════

@Composable
fun OnboardingSheet(onDone: () -> Unit) {
    val ctx = LocalContext.current
    Column(
        Modifier
            .fillMaxSize()
            .background(Color(0xEE070B16))
            .padding(24.dp),
    ) {
        Spacer(Modifier.height(48.dp))
        Text("开启兔时笺", fontSize = 26.sp, fontWeight = FontWeight.Bold)
        Text("3 步完成，之后可在任意界面悬浮显示", fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(24.dp))

        StepRow(1, "悬浮窗权限", Permissions.overlayGranted(ctx)) {
            runCatching { ctx.startActivity(Permissions.overlayIntent(ctx)) }
                .onFailure { runCatching { ctx.startActivity(Permissions.overlayIntent(ctx).setPackage(null)) } }
        }
        StepRow(2, "通知权限", Permissions.notificationsGranted(ctx)) {
            runCatching { ctx.startActivity(Permissions.notificationIntent(ctx)) }
        }
        val oem = remember { Permissions.oemSteps() }
        StepRow(3, oem.firstOrNull()?.label ?: "电池与后台", false) {
            oem.firstOrNull()?.let { step -> runCatching { ctx.startActivity(step.intent) } }
        }

        Spacer(Modifier.height(20.dp))
        Button(onClick = onDone, modifier = Modifier.fillMaxWidth()) { Text("先使用 App，稍后开启") }
    }
}

@Composable
private fun StepRow(no: Int, title: String, done: Boolean, onOpen: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0x0DFFFFFF))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(26.dp).clip(CircleShape)
                .background(if (done) Color(0xFF34D399) else Color(0x33FFFFFF)),
            contentAlignment = Alignment.Center,
        ) { Text(if (done) "✓" else "$no", fontSize = 13.sp, color = if (done) Color(0xFF04101C) else Color.White) }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) { Text(title, fontWeight = FontWeight.Medium) }
        if (!done) OutlinedButton(onClick = onOpen) { Text("去开启") } else Text("已开启", color = Color(0xFF7EF0C5), fontSize = 13.sp)
    }
}

// ═══════════════ 样式页 ═══════════════

private val COLORS = listOf("#22D3EE", "#F4F7FF", "#FFB454", "#FF6B6B", "#34D399", "#A78BFA")

@Composable
fun StyleScreen() {
    val style by AppState.style.collectAsState()
    val now = NowTick()
    val fc = Color(android.graphics.Color.parseColor(style.colorHex))

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
    ) {
        Text("样式", fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(12.dp))

        // 实时预览
        val (main, sec, ms) = Fmt.clock(style.hour24, style.showSeconds, if (style.showMillis) style.millisDigits else 0, now)
        val preview = buildString { append(main); append(sec); append(ms) }
        val bg = when (style.bg) {
            BgKind.CAPSULE -> Modifier
                .clip(RoundedCornerShape(99.dp))
                .background(fc.copy(alpha = 0.16f).compositeOverDark())
                .border(1.dp, fc.copy(alpha = 0.4f), RoundedCornerShape(99.dp))
            BgKind.CARD -> Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(fc.copy(alpha = 0.14f))
                .border(1.dp, fc.copy(alpha = 0.45f), RoundedCornerShape(16.dp))
            BgKind.OUTLINE -> Modifier
        }
        Box(
            Modifier
                .fillMaxWidth()
                .height(140.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color(0xFF111A30)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                preview,
                color = fc,
                fontFamily = Mono,
                fontWeight = FontWeight.Bold,
                fontSize = (24 * style.scale).sp,
                modifier = Modifier
                    .then(bg)
                    .alpha(style.opacity)
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            )
        }

        Section("主题色") {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                COLORS.forEach { hex ->
                    val c = Color(android.graphics.Color.parseColor(hex))
                    Box(
                        Modifier
                            .size(26.dp)
                            .clip(CircleShape)
                            .background(c)
                            .border(
                                if (style.colorHex == hex) 2.dp else 1.dp,
                                if (style.colorHex == hex) Color.White else Color(0x33FFFFFF),
                                CircleShape,
                            )
                            .clickable { AppState.updateStyle { it.copy(colorHex = hex) } },
                    )
                }
            }
        }

        Section("背景") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                BgKind.entries.forEach { kind ->
                    FilterChip(
                        selected = style.bg == kind,
                        onClick = { AppState.updateStyle { it.copy(bg = kind) } },
                        label = { Text(when (kind) { BgKind.CAPSULE -> "胶囊"; BgKind.CARD -> "方卡"; BgKind.OUTLINE -> "描边" }) },
                    )
                }
            }
        }

        Section("大小  ${"%.2f".format(style.scale).trimEnd('0').trimEnd('.')}×") {
            Slider(
                value = style.scale,
                onValueChange = { v -> AppState.updateStyle { it.copy(scale = v.coerceIn(0.7f, 3.8f)) } },
                valueRange = 0.7f..3.8f,
            )
            Text("拖动调节 · 最大约屏 1/4", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        Section("透明度 ${"%.0f".format(style.opacity * 100)}%") {
            Slider(
                value = style.opacity,
                onValueChange = { v -> AppState.updateStyle { it.copy(opacity = v.coerceIn(0.3f, 1f)) } },
                valueRange = 0.3f..1f,
            )
        }

        Section("显示元素") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("秒" to "showSeconds", "毫秒" to "showMillis", "日期" to "showDate", "星期" to "showWeek", "电量" to "showBattery").forEach { (label, key) ->
                    FilterChip(
                        selected = when (key) {
                            "showSeconds" -> style.showSeconds
                            "showMillis" -> style.showMillis
                            "showDate" -> style.showDate
                            "showWeek" -> style.showWeek
                            else -> style.showBattery
                        },
                        onClick = {
                            AppState.updateStyle {
                                when (key) {
                                    "showSeconds" -> it.copy(showSeconds = !it.showSeconds)
                                    "showMillis" -> it.copy(showMillis = !it.showMillis)
                                    "showDate" -> it.copy(showDate = !it.showDate)
                                    "showWeek" -> it.copy(showWeek = !it.showWeek)
                                    else -> it.copy(showBattery = !it.showBattery)
                                }
                            }
                        },
                        label = { Text(label) },
                    )
                }
            }
        }

        Section("毫秒位数（开启「毫秒」后生效）") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(1 to "1 位 .s", 2 to "2 位 .ss", 3 to "3 位 .sss").forEach { (digits, label) ->
                    FilterChip(
                        selected = style.millisDigits == digits,
                        onClick = { AppState.updateStyle { it.copy(millisDigits = digits) } },
                        label = { Text(label) },
                    )
                }
            }
        }

        Section("交互") {
            FilterChip(
                selected = style.snap,
                onClick = { AppState.updateStyle { it.copy(snap = !it.snap) } },
                label = { Text("贴边吸附") },
            )
        }

        Spacer(Modifier.height(96.dp))
    }
}

private fun Color.compositeOverDark(): Color = copy(alpha = alpha + (1f - alpha) * 0.7f)

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Text(title, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 18.dp, bottom = 6.dp))
    content()
}

// ═══════════════ 记录页 ═══════════════

@Composable
fun RecordsScreen() {
    val records by AppState.records.collectAsState()
    val fmt = remember { SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()) }
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("记录", fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        if (records.isEmpty()) {
            Text("暂无记录：秒表暂停/结束、倒计时完成后会出现在这里",
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        LazyColumn {
            items(records) { r ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val c = if (r.kind == "秒表") Color(0xFF34D399) else Color(0xFFFFB454)
                    Box(Modifier.size(34.dp).clip(RoundedCornerShape(11.dp)).background(c.copy(alpha = 0.18f)),
                        contentAlignment = Alignment.Center) {
                        Text(if (r.kind == "秒表") "▶" else "⏳", color = c)
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text("${r.kind} · ${r.label}", fontSize = 14.sp)
                        Text("${r.detail} · ${fmt.format(Date(r.at))}", fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

// ═══════════════ 我的页 ═══════════════

@Composable
fun MeScreen(onOpenTimeSource: () -> Unit = {}) {
    val ctx = LocalContext.current
    val style by AppState.style.collectAsState()
    val boot by AppState.bootStart.collectAsState()
    val floatVisible by AppState.floatVisible.collectAsState()
    val tsSelectedId by com.floatclock.app.timesync.TimeSync.selectedId.collectAsState()

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
        Text("我的", fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(12.dp))

        Card2 {
            Text("权限状态", fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(6.dp))
            PermRow("悬浮窗权限", Permissions.overlayGranted(ctx)) { runCatching { ctx.startActivity(Permissions.overlayIntent(ctx)) } }
            PermRow("通知权限", Permissions.notificationsGranted(ctx)) {
                runCatching { ctx.startActivity(Permissions.notificationIntent(ctx)) }
            }
            val oem = remember { Permissions.oemSteps() }
            PermRow(oem.firstOrNull()?.label ?: "电池优化", false) {
                oem.firstOrNull()?.let { runCatching { ctx.startActivity(it.intent) } }
            }
        }

        Card2 {
            Text("设置", fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(6.dp))
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .clickable(onClick = onOpenTimeSource)
                    .padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("时间源", Modifier.weight(1f), fontSize = 14.sp)
                Text(
                    com.floatclock.app.timesync.Sources.byId(tsSelectedId).name + " ›",
                    fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            SettingRow("24 小时制", style.hour24) { on -> AppState.updateStyle { it.copy(hour24 = on) } }
            SettingRow("开机自启动", boot) { on -> AppState.setBootStart(on) }
            SettingRow("悬浮窗常显", floatVisible) { on -> if (on) ensureFloat(ctx) else AppState.hideFloat() }
        }

        Card2 {
            Text("关于", fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Text("兔时笺 v0.3.3 · 无广告 · 不收集任何数据\n计时采用时间戳驱动，息屏/冻结恢复后零累计误差\n默认北京时间（授时中心 NTP 直连）；除时间源校准外不联网",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, lineHeight = 18.sp)
        }
        Spacer(Modifier.height(96.dp))
    }
}

@Composable
private fun PermRow(title: String, ok: Boolean, onOpen: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), fontSize = 14.sp)
        if (ok) Text("已开启", color = Color(0xFF7EF0C5), fontSize = 13.sp)
        else OutlinedButton(onClick = onOpen) { Text("去设置", fontSize = 12.sp) }
    }
}

@Composable
private fun SettingRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), fontSize = 14.sp)
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
