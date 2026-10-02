package com.floatclock.app

import android.content.Context
import android.os.SystemClock
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.floatclock.app.engine.BgKind
import com.floatclock.app.engine.Countdown
import com.floatclock.app.engine.Mode
import com.floatclock.app.engine.RunState
import com.floatclock.app.engine.Stopwatch
import com.floatclock.app.engine.Style
import com.floatclock.app.service.TimerService
import com.floatclock.app.timesync.Sources
import com.floatclock.app.timesync.SyncResult
import com.floatclock.app.timesync.TimeSync
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

private val Context.dataStore by preferencesDataStore(name = "float_clock")

/** 一条计时记录 */
data class Record(val kind: String, val label: String, val detail: String, val at: Long)

/**
 * 进程级单例状态：引擎实例 + 悬浮窗样式 + 服务控制。
 * UI 与悬浮窗 View / 前台服务 / 闹钟接收器都从这里读写（同进程主线程访问）。
 */
object AppState {
    val stopwatch = Stopwatch()
    val countdown = Countdown()

    val style = MutableStateFlow(Style())
    val mode = MutableStateFlow(Mode.CLOCK)          // 悬浮窗当前展示模式
    val floatVisible = MutableStateFlow(false)
    val cdState = MutableStateFlow(RunState.IDLE)
    val cdTotalMin = MutableStateFlow(5)
    val records = MutableStateFlow<List<Record>>(emptyList())
    val bootStart = MutableStateFlow(false)
    val alarming = MutableStateFlow(false)           // 到点响铃中

    /** 到点令牌：闹钟与 tick 双路径去重 */
    var countdownToken = 0

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var appContext: Context

    fun init(ctx: Context) {
        if (::appContext.isInitialized) return
        appContext = ctx.applicationContext
        TimeSync.persistHook = { scope.launch { persistTimeSync() } }
        TimeSync.startPeriodicSync() // 每 10 分钟过一次新鲜度闸门（新鲜不发请求）
        scope.launch { load() }
    }

    // ───────── 样式 ─────────
    fun updateStyle(transform: (Style) -> Style) {
        style.value = transform(style.value)
        scope.launch { persistStyle() }
    }

    // ───────── 秒表 ─────────
    fun toggleStopwatch() {
        stopwatch.startOrPause()
        if (stopwatch.running) {
            addRecord("秒表", "正计时", "开始")
        } else {
            val e = stopwatch.elapsed()
            addRecord("秒表", fmtSw(e), "暂停/结束")
        }
        TimerService.refresh(appContext)
    }

    fun resetStopwatch() {
        if (stopwatch.elapsed() > 0) addRecord("秒表", fmtSw(stopwatch.elapsed()), "手动重置")
        stopwatch.reset()
        TimerService.refresh(appContext)
    }

    // ───────── 倒计时 ─────────
    fun setCountdownMinutes(min: Int) {
        cdTotalMin.value = min
        countdown.setTotal(min * 60_000L)
        cdState.value = countdown.state
        cancelAlarm()
        TimerService.refresh(appContext)
    }

    fun toggleCountdown() {
        val now = SystemClock.elapsedRealtime()
        when (countdown.state) {
            RunState.IDLE -> {
                if (countdown.totalMs <= 0) countdown.setTotal(cdTotalMin.value * 60_000L)
                val endWall = countdown.start(now)
                cdState.value = RunState.RUNNING
                countdownToken++
                scheduleAlarm(endWall)
            }
            RunState.RUNNING -> { countdown.pause(now); cdState.value = RunState.PAUSED; cancelAlarm() }
            RunState.PAUSED -> {
                val endWall = countdown.start(now)
                cdState.value = RunState.RUNNING
                countdownToken++
                scheduleAlarm(endWall)
            }
            RunState.FINISHED -> { setCountdownMinutes(cdTotalMin.value) }
        }
        TimerService.refresh(appContext)
    }

    fun addCountdownMinute() {
        val endWall = countdown.addMinute()
        if (endWall > 0) { countdownToken++; scheduleAlarm(endWall) }
        cdState.value = countdown.state
        TimerService.refresh(appContext)
    }

    /** tick 路径到点（前台服务活着时） */
    fun onCountdownFinishedByTick() {
        cancelAlarm()
        cdState.value = RunState.FINISHED
        addRecord("倒计时", "倒计时", "${cdTotalMin.value} 分钟 · 已完成")
        alarming.value = true
        TimerService.refresh(appContext)
    }

    /** 闹钟兜底路径到点（进程可能被杀后由 receiver 调用） */
    fun onCountdownFinishedByAlarm() {
        if (countdown.state != RunState.FINISHED) {
            countdown.finishByAlarm()
            cdState.value = RunState.FINISHED
        }
        alarming.value = true
    }

    fun stopAlarm() { alarming.value = false; TimerService.refresh(appContext) }

    // ───────── 悬浮窗开关 ─────────
    fun showFloat() {
        floatVisible.value = true
        TimerService.start(appContext)
        scope.launch { persistMisc() }
    }

    fun hideFloat() {
        floatVisible.value = false
        TimerService.stop(appContext)
        scope.launch { persistMisc() }
    }

    fun setBootStart(on: Boolean) {
        bootStart.value = on
        com.floatclock.app.alarm.BootReceiver.setEnabled(appContext, on)
        scope.launch { persistMisc() }
    }

    private fun fmtSw(ms: Long) = com.floatclock.app.engine.Fmt.stopwatch(ms).first +
        com.floatclock.app.engine.Fmt.stopwatch(ms).third

    private fun addRecord(kind: String, label: String, detail: String) {
        records.value = (listOf(Record(kind, label, detail, System.currentTimeMillis())) + records.value).take(50)
        scope.launch { persistRecords() }
    }

    private fun scheduleAlarm(endWall: Long) = com.floatclock.app.alarm.AlarmScheduler.schedule(appContext, endWall)
    private fun cancelAlarm() = com.floatclock.app.alarm.AlarmScheduler.cancel(appContext)

    // ───────── 持久化 ─────────
    private val KEY_STYLE = stringPreferencesKey("style_json")
    private val KEY_RECORDS = stringPreferencesKey("records_json")
    private val KEY_FLOAT_VISIBLE = booleanPreferencesKey("float_visible")
    private val KEY_BOOT = booleanPreferencesKey("boot_start")
    private val KEY_POS_X = intPreferencesKey("pos_x")
    private val KEY_POS_Y = intPreferencesKey("pos_y")
    private val KEY_TS_SOURCE = stringPreferencesKey("ts_source")
    private val KEY_TS_MANUAL = doublePreferencesKey("ts_manual_ms")
    private val KEY_TS_RESULTS = stringPreferencesKey("ts_results_json")
    private val KEY_TS_DEPTH = doublePreferencesKey("ts_present_depth")

    private suspend fun persistStyle() {
        val s = style.value
        val json = JSONObject().apply {
            put("color", s.colorHex); put("bg", s.bg.name); put("scale", s.scale.toDouble())
            put("opacity", s.opacity.toDouble())
            put("sec", s.showSeconds); put("ms", s.showMillis); put("msDigits", s.millisDigits)
            put("date", s.showDate); put("week", s.showWeek); put("batt", s.showBattery); put("snap", s.snap)
            put("h24", s.hour24); put("x", s.x); put("y", s.y)
        }
        appContext.dataStore.edit { it[KEY_STYLE] = json.toString() }
    }

    private suspend fun persistRecords() {
        val arr = org.json.JSONArray()
        records.value.forEach { r -> arr.put(JSONObject().apply { put("k", r.kind); put("l", r.label); put("d", r.detail); put("at", r.at) }) }
        appContext.dataStore.edit { it[KEY_RECORDS] = arr.toString() }
    }

    private suspend fun persistMisc() {
        appContext.dataStore.edit {
            it[KEY_FLOAT_VISIBLE] = floatVisible.value
            it[KEY_BOOT] = bootStart.value
            it[KEY_POS_X] = style.value.x
            it[KEY_POS_Y] = style.value.y
        }
    }

    private suspend fun persistTimeSync() {
        appContext.dataStore.edit {
            it[KEY_TS_SOURCE] = TimeSync.selectedId.value
            it[KEY_TS_MANUAL] = TimeSync.manualOffsetMs.value
            it[KEY_TS_RESULTS] = encodeSyncResults(TimeSync.results.value)
            it[KEY_TS_DEPTH] = com.floatclock.app.engine.DisplayTiming.presentDepthVsyncs.value.toDouble()
        }
    }

    private fun encodeSyncResults(map: Map<String, SyncResult>): String {
        val arr = org.json.JSONArray()
        map.values.forEach { r ->
            arr.put(JSONObject().apply {
                put("id", r.sourceId); put("ok", r.ok); put("off", r.offsetMs)
                put("rtt", r.rttMs); put("at", r.atWall)
                put("off2", r.prevOffsetMs); put("at2", r.prevAtWall); put("ntp", r.ntp)
                if (r.error != null) put("err", r.error)
            })
        }
        return arr.toString()
    }

    private fun decodeSyncResults(raw: String?): Map<String, SyncResult> {
        if (raw.isNullOrEmpty()) return emptyMap()
        return runCatching {
            val arr = org.json.JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val j = arr.getJSONObject(i)
                val r = SyncResult(
                    sourceId = j.getString("id"), ok = j.getBoolean("ok"),
                    offsetMs = j.optDouble("off", 0.0), rttMs = j.optLong("rtt", 0),
                    atWall = j.optLong("at", 0), error = j.optString("err").ifEmpty { null },
                    prevOffsetMs = j.optDouble("off2", 0.0), prevAtWall = j.optLong("at2", 0),
                    ntp = j.optBoolean("ntp", false),
                )
                r.sourceId to r
            }.toMap()
        }.getOrDefault(emptyMap())
    }

    private suspend fun load() {
        appContext.dataStore.data.collect { p ->
            p[KEY_STYLE]?.let { raw ->
                runCatching {
                    val j = JSONObject(raw)
                    val saved = Style(
                        colorHex = j.optString("color", "#22D3EE"),
                        bg = runCatching { BgKind.valueOf(j.optString("bg", "CAPSULE")) }.getOrDefault(BgKind.CAPSULE),
                        scale = j.optDouble("scale", 1.15).toFloat().coerceIn(0.7f, 3.8f),
                        opacity = j.optDouble("opacity", 1.0).toFloat().coerceIn(0.3f, 1f),
                        showSeconds = j.optBoolean("sec", true),
                        showMillis = j.optBoolean("ms", false),
                        millisDigits = j.optInt("msDigits", 1).coerceIn(1, 3),
                        showDate = j.optBoolean("date", false),
                        showWeek = j.optBoolean("week", false),
                        showBattery = j.optBoolean("batt", false),
                        snap = j.optBoolean("snap", true),
                        hour24 = j.optBoolean("h24", true),
                        x = j.optInt("x", -1), y = j.optInt("y", -1),
                    )
                    style.value = saved
                }
            }
            p[KEY_RECORDS]?.let { raw ->
                runCatching {
                    val arr = org.json.JSONArray(raw)
                    records.value = (0 until arr.length()).map { i ->
                        val j = arr.getJSONObject(i)
                        Record(j.getString("k"), j.getString("l"), j.getString("d"), j.getLong("at"))
                    }
                }
            }
            bootStart.value = p[KEY_BOOT] ?: false
            // 时间源（默认北京时间；已存结果的源在过期阈值内无需立即联网）
            TimeSync.selectedId.value = p[KEY_TS_SOURCE] ?: Sources.BEIJING
            TimeSync.manualOffsetMs.value = (p[KEY_TS_MANUAL] ?: 0.0)
                .coerceIn(-TimeSync.MANUAL_MAX_MS, TimeSync.MANUAL_MAX_MS)
            TimeSync.results.value = decodeSyncResults(p[KEY_TS_RESULTS])
            com.floatclock.app.engine.DisplayTiming.presentDepthVsyncs.value =
                (p[KEY_TS_DEPTH] ?: 1.0).toFloat().coerceIn(1f, 2f)
        }
    }
}
