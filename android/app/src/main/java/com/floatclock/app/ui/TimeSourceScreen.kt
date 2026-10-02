package com.floatclock.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.floatclock.app.timesync.SourceKind
import com.floatclock.app.timesync.Sources
import com.floatclock.app.timesync.SyncResult
import com.floatclock.app.timesync.TimeSync
import kotlinx.coroutines.delay

private val Mono = FontFamily.Monospace
private val Accent = Color(0xFF22D3EE)

/**
 * 时间源页：状态卡 + 手动微调 + 源列表（覆盖在底部导航之上的整页层）。
 * 页面打开即触发所选源的过期补校准（TimeSync.ensureFresh）。
 */
@Composable
fun TimeSourceScreen(onBack: () -> Unit) {
    val selectedId by TimeSync.selectedId.collectAsState()
    val manual by TimeSync.manualOffsetMs.collectAsState()
    val results by TimeSync.results.collectAsState()
    val syncing by TimeSync.syncing.collectAsState()
    var showHelp by remember { mutableStateOf(false) }
    val now = rememberTick()
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val hz = remember { com.floatclock.app.engine.DisplayTiming.refreshRateHz(ctx) }
    val depth by com.floatclock.app.engine.DisplayTiming.presentDepthVsyncs.collectAsState()
    val compMid = com.floatclock.app.engine.DisplayTiming.compMs(hz, 0.5f, depth)

    LaunchedEffect(Unit) { TimeSync.ensureFresh() }

    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
    ) {
        Spacer(Modifier.height(18.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("‹", fontSize = 26.sp, color = Accent,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(onClick = onBack)
                    .padding(horizontal = 10.dp, vertical = 2.dp))
            Text("时间源", fontSize = 20.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f), color = Color(0xFFE8EDF7))
            Text("?", fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable { showHelp = true }
                    .padding(8.dp))
        }

        // ── 同步状态卡 ──
        val sel = Sources.byId(selectedId)
        val res = results[sel.id]
        Spacer(Modifier.height(10.dp))
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(Color(0x0DFFFFFF))
                .border(1.dp, Color(0x1FFFFFFF), RoundedCornerShape(18.dp))
                .padding(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(8.dp).clip(CircleShape).background(
                        when {
                            sel.kind == SourceKind.DEVICE -> Color(0xFF92A0BA)
                            sel.id in syncing -> Accent
                            res?.ok == true -> Color(0xFF34D399)
                            else -> Color(0xFFFFB454)
                        }
                    )
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    when {
                        sel.kind == SourceKind.DEVICE -> "使用设备时间 · 不联网"
                        sel.id in syncing -> "正在校准 ${sel.name}…"
                        res?.ok == true -> "已校准 ${sel.name} · ${TimeSync.fmtAgo(res.atWall, now)}"
                        else -> "${sel.name} · 未校准"
                    },
                    fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color(0xFFE8EDF7),
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(
                when {
                    sel.kind == SourceKind.DEVICE -> "兔时笺与系统时间保持一致"
                    res?.ok == true -> buildString {
                        append("偏差 ").append(TimeSync.fmtOffset(res.offsetMs))
                        if (manual != 0.0) append(" · 微调 ").append(TimeSync.fmtManual(manual))
                        append("\n显示时间 = 设备时间 + 以上偏移 · ")
                        when {
                            sel.kind == SourceKind.DATE -> append("秒沿窗口 ").append(res.rttMs).append("ms")
                            sel.kind == SourceKind.SNTP && res.ntp -> append("RTT ").append(res.rttMs).append("ms · NTP 直连")
                            sel.kind == SourceKind.SNTP -> append("RTT ").append(res.rttMs).append("ms · HTTP 回落")
                            else -> append("RTT ").append(res.rttMs).append("ms")
                        }
                    }
                    else -> "点击下方「立即校准」获取与 ${sel.name} 服务器的偏差"
                },
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, lineHeight = 18.sp,
            )
            if (sel.kind != SourceKind.DEVICE) {
                Spacer(Modifier.height(10.dp))
                Row {
                    Button(
                        onClick = { TimeSync.requestSync(sel.id) },
                        enabled = sel.id !in syncing,
                    ) { Text(if (sel.id in syncing) "校准中…" else "立即校准") }
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                "屏幕 ${kotlin.math.round(hz).toInt()}Hz · 显示延迟已补偿 ≈ ${"%.1f".format(compMid)}ms" +
                    "（悬浮窗按所在屏幕高度精确补偿，让「看到的时刻」与真实时刻对齐）",
                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // ── 手动调整时间 ──
        Text("手动调整时间", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 18.dp, bottom = 6.dp))
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(Color(0x0DFFFFFF))
                .border(1.dp, Color(0x1FFFFFFF), RoundedCornerShape(18.dp))
                .padding(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("手动微调", fontSize = 14.sp, color = Color(0xFFE8EDF7))
                    Text("每次 ±10 毫秒 · 在校准偏差上叠加", fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                NudgeBtn("−") { TimeSync.nudgeManual(-TimeSync.MANUAL_STEP_MS) }
                Text(
                    TimeSync.fmtManual(manual), fontFamily = Mono, fontSize = 14.sp,
                    color = if (manual == 0.0) MaterialTheme.colorScheme.onSurfaceVariant else Accent,
                    modifier = Modifier.padding(horizontal = 10.dp).width(84.dp),
                    textAlign = TextAlign.Center,
                )
                NudgeBtn("+") { TimeSync.nudgeManual(TimeSync.MANUAL_STEP_MS) }
            }
            if (manual != 0.0) {
                TextButton(onClick = { TimeSync.resetManual() }) { Text("重置微调", fontSize = 12.sp) }
            }
        }

        // ── 显示补偿深度 ──
        Column(
            Modifier
                .fillMaxWidth()
                .padding(vertical = 4.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(Color(0x0DFFFFFF))
                .border(1.dp, Color(0x1FFFFFFF), RoundedCornerShape(18.dp))
                .padding(14.dp),
        ) {
            Text("显示补偿深度", fontSize = 14.sp, color = Color(0xFFE8EDF7))
            Text(
                "悬浮窗经系统合成器叠加的路径偶有 2 帧深度。若真机上时钟整体偏快/偏慢约 1 帧，可在此调大；不确定就保持 1 帧",
                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp, bottom = 8.dp),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(1f to "1 帧", 1.5f to "1.5 帧", 2f to "2 帧").forEach { (d, label) ->
                    FilterChip(
                        selected = depth == d,
                        onClick = {
                            com.floatclock.app.engine.DisplayTiming.presentDepthVsyncs.value = d
                            TimeSync.persistHook?.invoke()
                        },
                        label = { Text(label) },
                    )
                }
            }
        }

        // ── 时间源列表 ──
        Text("时间源", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 18.dp, bottom = 6.dp))
        Sources.ALL.forEach { src ->
            val r = results[src.id]
            val active = src.id == selectedId
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(if (active) Accent.copy(alpha = 0.10f) else Color(0x0DFFFFFF))
                    .border(1.dp, if (active) Accent.copy(alpha = 0.45f) else Color(0x1FFFFFFF), RoundedCornerShape(16.dp))
                    .clickable { TimeSync.select(src.id) }
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(18.dp).clip(CircleShape)
                        .border(1.5.dp, if (active) Accent else Color(0x55FFFFFF), CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    if (active) Box(Modifier.size(9.dp).clip(CircleShape).background(Accent))
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(src.name, fontSize = 15.sp, color = Color(0xFFE8EDF7))
                        if (src.id == Sources.BEIJING) {
                            Spacer(Modifier.width(6.dp))
                            Text("默认", fontSize = 10.sp, color = Color(0xFF04101C),
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(Accent.copy(alpha = 0.85f))
                                    .padding(horizontal = 6.dp, vertical = 1.dp))
                        }
                    }
                    Text(src.sub, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(
                    sourceStatusText(src.kind, r, src.id in syncing),
                    fontSize = 12.sp, fontFamily = Mono,
                    color = when {
                        src.kind == SourceKind.DEVICE -> Color(0xFF7EF0C5)
                        src.id in syncing -> Accent
                        r?.ok == true -> Color(0xFF7EF0C5)
                        else -> MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
        }

        Text(
            "「北京时间」优先 NTP 直连国家授时中心（UDP 被网络拦截时自动回落 HTTP，精度降为 ±0.1s）；" +
                "接口类源（淘宝/大麦）约 ±0.02s；其余 Date 头源约 ±0.05~0.1s（预测秒沿 + 突发轮询）。" +
                "高精度源在两次校准之间还会按本机晶振漂移自动外推。",
            fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, lineHeight = 17.sp,
            modifier = Modifier.padding(top = 10.dp, bottom = 40.dp),
        )
    }

    if (showHelp) {
        AlertDialog(
            onDismissRequest = { showHelp = false },
            confirmButton = { TextButton(onClick = { showHelp = false }) { Text("知道了") } },
            title = { Text("关于时间源") },
            text = {
                Text(
                    "兔时笺默认显示北京时间（国家授时中心）。\n\n" +
                        "· 校准原理：向所选服务器发起请求，用往返时延的一半修正服务器时间，得到与本机的偏差；显示时间 = 设备时间 + 偏差。\n" +
                        "· 显示延迟补偿：每帧按屏幕刷新率与悬浮窗所在高度，把显示值前移「1 个呈现周期 + 面板扫描延迟」（60Hz 约 17~25ms、120Hz 减半），毫秒模式下逐帧自校正，使「看到的时刻」≈ 真实时刻。\n" +
                        "· 手动微调在校准偏差上叠加，适合「故意提前/延后」的场景。\n" +
                        "· 校准时机：打开本页、切换源、开启悬浮窗、回到前台时进行（10 分钟内不重复），应用存活期间每 10 分钟自动补一次；新鲜时不发任何请求。",
                    fontSize = 13.sp, lineHeight = 20.sp,
                )
            },
        )
    }
}

private fun sourceStatusText(kind: SourceKind, r: SyncResult?, syncingNow: Boolean): String = when {
    kind == SourceKind.DEVICE -> "跟随本机"
    syncingNow -> "校准中"
    r?.ok == true -> TimeSync.fmtOffset(r.offsetMs)
    r != null -> "失败·点击重试"
    else -> "未校准"
}

@Composable
private fun NudgeBtn(label: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(34.dp)
            .clip(CircleShape)
            .background(Color(0x1AFFFFFF))
            .border(1.dp, Color(0x33FFFFFF), CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(label, fontSize = 18.sp, color = Color(0xFFE8EDF7)) }
}

/** 每秒一跳，驱动「x 秒前」等相对文案刷新 */
@Composable
private fun rememberTick(): Long {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1000)
        }
    }
    return now
}
