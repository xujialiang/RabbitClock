package com.floatclock.app.timesync

import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/** 源类型：本机 / SNTP(UDP123) / JSON 接口（毫秒级）/ HTTP Date 头（秒级，秒沿检测提精度） */
enum class SourceKind { DEVICE, SNTP, JSON, DATE }

/**
 * 内置时间源。接口均于 2026-10 实测可用（SNTP 主备、HEAD Date、mtop JSON）。
 * beijing：首选 SNTP 直连授时中心，UDP 被拦时自动回落 HTTP 秒沿法。
 */
data class TimeSource(
    val id: String,
    val name: String,
    val sub: String,
    val kind: SourceKind,
    val url: String,
    val ntpHosts: List<String> = emptyList(),
)

object Sources {
    const val DEVICE = "device"
    const val BEIJING = "beijing"

    val ALL = listOf(
        TimeSource(DEVICE, "设备时间", "本机系统时间 · 不联网", SourceKind.DEVICE, ""),
        TimeSource(
            BEIJING, "北京时间", "中国国家授时中心 · NTP 直连（被拦时回落 HTTP）", SourceKind.SNTP,
            "https://www.ntsc.ac.cn/",
            listOf("ntp.ntsc.ac.cn", "ntp.aliyun.com"), // ntp2/3.ntsc.ac.cn 无 DNS 记录，备选阿里公共 NTP
        ),
        TimeSource("taobao", "淘宝", "acs.m.taobao.com · 毫秒级接口", SourceKind.JSON, "https://acs.m.taobao.com/gw/mtop.common.getTimestamp/"),
        TimeSource("damai", "大麦", "mtop.damai.cn · 毫秒级接口", SourceKind.JSON, "https://mtop.damai.cn/gw/mtop.common.getTimestamp/"),
        TimeSource("jd", "京东", "www.jd.com", SourceKind.DATE, "https://www.jd.com/"),
        TimeSource("meituan", "美团", "www.meituan.com", SourceKind.DATE, "https://www.meituan.com/"),
        TimeSource("pdd", "拼多多", "mobile.yangkeduo.com", SourceKind.DATE, "https://mobile.yangkeduo.com/"),
        TimeSource("unionpay", "云闪付", "cn.unionpay.com", SourceKind.DATE, "https://cn.unionpay.com/"),
    )

    fun byId(id: String): TimeSource = ALL.firstOrNull { it.id == id } ?: ALL[1]
}

/**
 * 一次校准的结果（按源保留）。
 * rttMs 按源类型语义不同：SNTP/JSON = 最小时延；DATE = 秒沿翻转窗口（不确定度）。
 * prevOffsetMs/prevAtWall 为上一次成功校准，用于晶振漂移外推。
 */
data class SyncResult(
    val sourceId: String,
    val ok: Boolean,
    val offsetMs: Double = 0.0,
    val rttMs: Long = 0,
    val atWall: Long = 0,
    val error: String? = null,
    val prevOffsetMs: Double = 0.0,
    val prevAtWall: Long = 0,
    /** 本次结果使用的通道：true=NTP（SNTP 源直连成功），false=HTTP 回落或 HTTP 类源 */
    val ntp: Boolean = false,
)

/**
 * 时间源同步：SNTP / NTP 式 HTTP 校准。
 *
 * 显示时间 = System.currentTimeMillis() + offset(所选源, 含漂移外推) + 手动微调。
 * 仅 CLOCK 模式的显示走 now()；秒表/倒计时是时长语义，仍用单调时钟。
 */
object TimeSync {

    const val MANUAL_STEP_MS = 10.0          // 手动微调步进 10ms
    const val MANUAL_MAX_MS = 9_999.0
    private const val STALE_MS = 10 * 60_000L // 超过 10 分钟视为过期，触发点处自动补校准
    private const val PERIOD_MS = 10 * 60_000L // 进程存活期间的周期补校准间隔
    private const val TIMEOUT_MS = 3_500
    private const val UA = "Mozilla/5.0 (Linux; Android 14) Mobile Safari/537.36"
    private const val NTP_BACKOFF_MS = 10 * 60_000L // UDP 被拦后 10 分钟内不再尝试 NTP，直接走 HTTP
    private const val DRIFT_MIN_SPAN_MS = 120_000L  // 相邻两次校准至少隔 2 分钟才可信地估漂移
    private const val DRIFT_MAX_PPM = 50.0          // 晶振漂移上限，超出视为噪声

    val selectedId = MutableStateFlow(Sources.BEIJING)
    val manualOffsetMs = MutableStateFlow(0.0)
    val results = MutableStateFlow<Map<String, SyncResult>>(emptyMap())
    val syncing = MutableStateFlow<Set<String>>(emptySet())

    /** 由 AppState 注入的持久化钩子（写入 DataStore），避免双端状态层互相依赖 */
    var persistHook: (() -> Unit)? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inFlight = ConcurrentHashMap<String, Boolean>()

    @Volatile
    private var ntpBlockedUntil = 0L

    // ───────── 供显示链路调用 ─────────

    /** 当前应显示的「现在」：本机墙钟 + 所选源偏差(含漂移) + 手动微调 */
    fun now(): Long = System.currentTimeMillis() + Math.round(totalOffsetMs())

    /** 悬浮窗秒对齐用：显示时间距下一个整秒的剩余（offset 后边界可能偏离本机秒沿） */
    fun msToNextSecond(): Long {
        val m = now() % 1000
        return if (m == 0L) 1000L else 1000L - m
    }

    fun totalOffsetMs(): Double {
        val src = Sources.byId(selectedId.value)
        val syncOffset = if (src.kind != SourceKind.DEVICE) syncOffsetNow(src) else 0.0
        return syncOffset + manualOffsetMs.value
    }

    /** 所选源当前的校准偏移（含漂移外推） */
    private fun syncOffsetNow(src: TimeSource): Double {
        val r = results.value[src.id]?.takeIf { it.ok } ?: return 0.0
        return r.offsetMs + driftNowMs(r, src)
    }

    /** 晶振漂移外推：仅高精度源（SNTP/JSON）、间隔达标且斜率合理时启用 */
    private fun driftNowMs(r: SyncResult, src: TimeSource): Double {
        if (src.kind == SourceKind.DATE) return 0.0 // Date 源噪声(±百ms)远大于真实漂移信号
        if (r.prevAtWall <= 0) return 0.0
        val span = r.atWall - r.prevAtWall
        if (span < DRIFT_MIN_SPAN_MS) return 0.0
        val slope = (r.offsetMs - r.prevOffsetMs) / span
        if (kotlin.math.abs(slope) * 1_000_000 > DRIFT_MAX_PPM) return 0.0
        return slope * (System.currentTimeMillis() - r.atWall)
    }

    fun currentResult(): SyncResult? {
        val src = Sources.byId(selectedId.value)
        return if (src.kind == SourceKind.DEVICE) null else results.value[src.id]
    }

    // ───────── 用户操作 ─────────

    fun select(id: String) {
        if (selectedId.value == id) return
        selectedId.value = id
        persistHook?.invoke()
        ensureFresh()
    }

    fun nudgeManual(deltaMs: Double) {
        manualOffsetMs.value = (manualOffsetMs.value + deltaMs).coerceIn(-MANUAL_MAX_MS, MANUAL_MAX_MS)
        persistHook?.invoke()
    }

    fun resetManual() {
        manualOffsetMs.value = 0.0
        persistHook?.invoke()
    }

    /** 所选源过期则后台补校准（打开时间源页 / 显示悬浮窗 / 开服务时触发） */
    fun ensureFresh() {
        val src = Sources.byId(selectedId.value)
        if (src.kind == SourceKind.DEVICE) return
        val last = results.value[src.id]
        val fresh = last?.ok == true && System.currentTimeMillis() - last.atWall < STALE_MS
        if (!fresh) scope.launch { sync(src.id) }
    }

    /** 手动触发（UI 按钮 / 选中未校准的源）。已有同源请求在跑则忽略 */
    fun requestSync(id: String) {
        scope.launch { sync(id) }
    }

    /**
     * 周期补校准：进程存活期间每 10 分钟过一次新鲜度闸门（新鲜则不发请求）。
     * 由 AppState.init 启动；悬浮窗常显（前台服务）时进程常驻即持续生效，
     * 纯后台进程被系统冻结时协程暂停、不会偷偷联网。
     */
    fun startPeriodicSync() {
        if (periodicStarted) return
        periodicStarted = true
        scope.launch {
            while (true) {
                delay(PERIOD_MS)
                ensureFresh()
            }
        }
    }

    @Volatile
    private var periodicStarted = false

    // ───────── 校准入口 ─────────

    private suspend fun sync(id: String): SyncResult {
        val src = Sources.byId(id)
        if (src.kind == SourceKind.DEVICE || inFlight.putIfAbsent(id, true) != null) {
            return results.value[id] ?: SyncResult(src.id, false, error = "设备时间无需校准")
        }
        syncing.value = syncing.value + id
        try {
            val r = when (src.kind) {
                SourceKind.SNTP -> {
                    val n = syncNtp(src)
                    if (n.ok) n else syncDateRollover(src) // UDP 被拦 → 回落 HTTP 秒沿法
                }
                SourceKind.JSON -> syncJson(src)
                else -> syncDateRollover(src)
            }
            val withPrev = carryPrev(id, r)
            results.value = results.value + (id to withPrev)
            persistHook?.invoke()
            return withPrev
        } finally {
            inFlight.remove(id)
            syncing.value = syncing.value - id
        }
    }

    private fun carryPrev(id: String, r: SyncResult): SyncResult {
        val old = results.value[id]?.takeIf { it.ok } ?: return r
        if (!r.ok) return r
        return r.copy(prevOffsetMs = old.offsetMs, prevAtWall = old.atWall)
    }

    // ───────── SNTP 通道 ─────────

    private suspend fun syncNtp(src: TimeSource): SyncResult {
        if (System.currentTimeMillis() < ntpBlockedUntil) {
            return SyncResult(src.id, false, error = "NTP 通道近期不可用")
        }
        val samples = mutableListOf<Sntp.Sample>()
        for (round in 1..2) {
            for (h in src.ntpHosts) {
                Sntp.probe(h)?.let { samples += it }
                if (samples.size >= 4) break
                delay(60)
            }
            if (round == 1 && samples.isEmpty()) break // 网络明显拦截 UDP，快速放弃走 HTTP
        }
        if (samples.isEmpty()) {
            ntpBlockedUntil = System.currentTimeMillis() + NTP_BACKOFF_MS
            return SyncResult(src.id, false, error = "NTP 不可达（UDP 123 被拦截）")
        }
        val best3 = samples.sortedBy { it.delayMs }.take(3).map { it.offsetMs }
        return SyncResult(
            src.id, true, median(best3), samples.minOf { it.delayMs },
            System.currentTimeMillis(), ntp = true,
        )
    }

    // ───────── JSON 通道：8 样本（≤4s），最优 3 个 RTT 的偏移取中位数 ─────────

    private suspend fun syncJson(src: TimeSource): SyncResult {
        val startAt = SystemClock.elapsedRealtime()
        val rtts = mutableListOf<Long>()
        val offsets = mutableListOf<Double>()
        var lastErr: String? = null
        var i = 0
        while (i < 8 && (offsets.isEmpty() || SystemClock.elapsedRealtime() - startAt < 4_000)) {
            try {
                val resp = httpGet(src.url, head = false)
                val serverMs = JSONObject(resp.body).getJSONObject("data").getString("t").toLong()
                rtts += resp.rttMs
                offsets += serverMs + resp.rttMs / 2.0 - resp.wallAtT1
            } catch (e: Exception) {
                lastErr = e.message ?: e.javaClass.simpleName
            }
            i++
            if (i < 8) delay(80)
        }
        if (offsets.isEmpty()) return SyncResult(src.id, false, error = lastErr ?: "请求失败")
        // 低 RTT 组的偏移取中位数：抗单次网络抖动
        val best = offsets.indices.sortedBy { rtts[it] }.take(minOf(3, offsets.size)).map { offsets[it] }
        return SyncResult(src.id, true, median(best), rtts.min(), System.currentTimeMillis())
    }

    // ───────── Date 头通道：预测秒沿 + 临近突发轮询（HEAD + 连接复用） ─────────

    /**
     * 两轮秒沿检测，保留窗口最小者：
     * 有历史偏差 → 预测下一整秒边界，边界前 450ms 起每 50ms 突发探测（连接复用后单次 ~30ms，
     * 窗口可压到 ~100ms）；无历史 → 先 250ms 间隔扫描定位。窗口 = 翻转前后两次响应的墙钟差。
     */
    private suspend fun syncDateRollover(src: TimeSource): SyncResult {
        var rough: Double? = results.value[src.id]?.takeIf { it.ok }?.offsetMs
        var bestOffset = 0.0
        var bestWindow = -1L
        var lastErr: String? = null
        var rounds = 0
        while (rounds < 2) {
            val r = try {
                if (rough == null) scanRollover(src) else burstRollover(src, rough)
            } catch (e: Exception) {
                lastErr = e.message ?: e.javaClass.simpleName
                null
            }
            if (r == null) {
                if (rough == null) return SyncResult(src.id, false, error = lastErr ?: "未捕获到秒沿")
                break // 预测轮失败：保留已获得的最好结果
            }
            if (bestWindow < 0 || r.windowMs < bestWindow) {
                bestOffset = r.offset
                bestWindow = r.windowMs
            }
            rough = r.offset
            rounds++
        }
        if (bestWindow < 0) return SyncResult(src.id, false, error = lastErr ?: "校准失败")
        return SyncResult(src.id, true, bestOffset, bestWindow, System.currentTimeMillis())
    }

    /** 一次秒沿检测结果：offset 与翻转窗口（前后两次响应的墙钟差，即不确定度） */
    private class Rollover(val offset: Double, val windowMs: Long)

    private suspend fun scanRollover(src: TimeSource): Rollover? {
        var prevMs = 0L
        var prevWall = 0.0
        val startAt = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - startAt < 3_500) {
            val resp = httpGet(src.url, head = true)
            val dateMs = parseGmt(resp.dateHeader)
            if (dateMs <= 0L) throw IllegalStateException("响应缺少 Date 头")
            if (prevMs in 1 until dateMs) {
                return Rollover(dateMs - (prevWall + resp.wallAtT1) / 2.0, (resp.wallAtT1 - prevWall).toLong())
            }
            if (dateMs != prevMs) {
                prevMs = dateMs
                prevWall = resp.wallAtT1.toDouble()
            }
            delay(250)
        }
        return null
    }

    private suspend fun burstRollover(src: TimeSource, rough: Double): Rollover? {
        // 预测下一整秒边界（服务器时间线）对应的本地墙钟
        val serverNow = System.currentTimeMillis() + rough
        val nextBoundary = (serverNow / 1000) * 1000 + 1000
        val boundaryLocal = nextBoundary - rough
        val sleepMs = (boundaryLocal - 450) - System.currentTimeMillis()
        if (sleepMs > 1_200) return null // 预测异常（偏差过大），交给外层换扫描
        if (sleepMs > 0) delay(sleepMs.toLong())

        var prevMs = 0L
        var prevWall = 0.0
        val startAt = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - startAt < 1_300) {
            val resp = httpGet(src.url, head = true)
            val dateMs = parseGmt(resp.dateHeader)
            if (dateMs <= 0L) throw IllegalStateException("响应缺少 Date 头")
            if (prevMs in 1 until dateMs) {
                return Rollover(dateMs - (prevWall + resp.wallAtT1) / 2.0, (resp.wallAtT1 - prevWall).toLong())
            }
            if (dateMs != prevMs) {
                prevMs = dateMs
                prevWall = resp.wallAtT1.toDouble()
            }
            delay(50)
        }
        return null
    }

    // ───────── HTTP（HEAD 探测 + 不 disconnect 以复用连接池） ─────────

    /** 一次 HTTP 采样的全部观测值。t1Wall 由「t0Wall + 单调差值」推出，不受同步期间改系统时间影响 */
    private class HttpSample(val body: String, val dateHeader: String?, val rttMs: Long, val wallAtT1: Long)

    private fun httpGet(url: String, head: Boolean): HttpSample {
        val t0Mono = SystemClock.elapsedRealtime()
        val t0Wall = System.currentTimeMillis()
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = TIMEOUT_MS.toInt()
        conn.readTimeout = TIMEOUT_MS.toInt()
        conn.instanceFollowRedirects = true
        conn.useCaches = false
        if (head) conn.requestMethod = "HEAD"
        conn.setRequestProperty("User-Agent", UA)
        conn.setRequestProperty("Cache-Control", "no-cache")
        try {
            if (conn.responseCode !in 200..399) throw IllegalStateException("HTTP ${conn.responseCode}")
            val date = conn.getHeaderField("Date")
            val body = if (head) "" else conn.inputStream.bufferedReader().use(BufferedReader::readText)
            val rtt = SystemClock.elapsedRealtime() - t0Mono
            return HttpSample(body, date, rtt, t0Wall + rtt)
        } finally {
            // 不 disconnect：交还连接池供同主机后续探测复用（实测 124ms → ~30ms），
            // 仅在出错流上显式断开
            conn.errorStream?.close()
        }
    }

    /** SimpleDateFormat 非线程安全，且调用频率低（每次校准个位数次），按次创建 */
    private fun parseGmt(s: String?): Long {
        val v = s?.trim() ?: return -1L
        if (v.isEmpty()) return -1L
        return runCatching {
            java.text.SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US)
                .apply { timeZone = java.util.TimeZone.getTimeZone("GMT") }
                .parse(v)?.time ?: -1L
        }.getOrDefault(-1L)
    }

    private fun median(v: List<Double>): Double {
        if (v.isEmpty()) return 0.0
        val s = v.sorted()
        val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    // ───────── 格式化 ─────────

    /** +0.0943s / −0.0312s（4 位小数秒，与竞品展示一致） */
    fun fmtOffset(ms: Double): String =
        String.format(Locale.US, "%s%.4fs", if (ms >= 0) "+" else "−", kotlin.math.abs(ms) / 1000.0)

    /** 手动微调显示：+0.0100s / ±0.0000s */
    fun fmtManual(ms: Double): String =
        if (ms == 0.0) "±0.0000s" else fmtOffset(ms)

    /** 同步距今：刚刚 / 5 秒前 / 3 分钟前 / 2 小时前 */
    fun fmtAgo(atWall: Long, nowWall: Long = System.currentTimeMillis()): String {
        val s = ((nowWall - atWall) / 1000).coerceAtLeast(0)
        return when {
            s < 3 -> "刚刚"
            s < 60 -> "$s 秒前"
            s < 3600 -> "${s / 60} 分钟前"
            else -> "${s / 3600} 小时前"
        }
    }
}
