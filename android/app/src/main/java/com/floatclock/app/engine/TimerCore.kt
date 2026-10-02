package com.floatclock.app.engine

import android.os.SystemClock
import java.util.Calendar

/** 计时模式 */
enum class Mode { CLOCK, STOPWATCH, COUNTDOWN }

/** 引擎状态（CLOCK 无状态常显） */
enum class RunState { IDLE, RUNNING, PAUSED, FINISHED }

/** 悬浮窗背景样式 */
enum class BgKind { CAPSULE, CARD, OUTLINE }

/** 悬浮窗外观与显示元素（持久化） */
data class Style(
    val colorHex: String = "#22D3EE",
    val bg: BgKind = BgKind.CAPSULE,
    val scale: Float = 1.15f,          // 0.7 ~ 3.8，最大约屏 1/4
    val opacity: Float = 1f,           // 30% ~ 100%
    val showSeconds: Boolean = true,
    val showMillis: Boolean = false,   // 毫秒开关（默认关，省电）
    val millisDigits: Int = 1,         // 毫秒位数 1~3，默认 1（.s / .ss / .sss）
    val showDate: Boolean = false,
    val showWeek: Boolean = false,
    val showBattery: Boolean = false,
    val snap: Boolean = true,          // 贴边吸附
    val hour24: Boolean = true,
    val x: Int = -1,                   // 悬浮窗位置（px，-1 未初始化）
    val y: Int = -1,
    val minimized: Boolean = false,
)

/**
 * 秒表：正计时。显示值永远由「单调时钟时间戳差值」计算，
 * 不累加 tick —— 进程冻结/休眠恢复后立即正确（PRD 非功能需求）。
 */
class Stopwatch {
    var running = false
        private set
    private var baseMs = 0L
    private var startStamp = 0L

    /** @return 切换后的运行状态 */
    fun startOrPause(now: Long = SystemClock.elapsedRealtime()): Boolean {
        if (running) { baseMs = elapsed(now); running = false }
        else { startStamp = now; running = true }
        return running
    }

    fun reset() { running = false; baseMs = 0L }

    fun elapsed(now: Long = SystemClock.elapsedRealtime()): Long =
        baseMs + if (running) now - startStamp else 0L
}

/**
 * 倒计时：目标时刻驱动 + 精确闹钟兜底。
 * remainMs 在暂停时缓存，运行时实时计算。
 */
class Countdown {
    var state = RunState.IDLE
        private set
    var totalMs = 5 * 60_000L
        private set
    private var remainCached = 5 * 60_000L
    private var endStamp = 0L

    val active: Boolean get() = state == RunState.RUNNING || state == RunState.PAUSED

    fun setTotal(ms: Long) { totalMs = ms; remainCached = ms; state = RunState.IDLE }

    /** 开始/继续。@return 结束时刻的 wall-clock 毫秒（用于调度精确闹钟） */
    fun start(now: Long = SystemClock.elapsedRealtime()): Long {
        endStamp = now + remainCached
        state = RunState.RUNNING
        return System.currentTimeMillis() + remainCached
    }

    fun pause(now: Long = SystemClock.elapsedRealtime()) {
        remainCached = remain(now); state = RunState.PAUSED
    }

    fun reset() { remainCached = totalMs; state = RunState.IDLE }

    fun remain(now: Long = SystemClock.elapsedRealtime()): Long = when (state) {
        RunState.RUNNING -> maxOf(0L, endStamp - now)
        RunState.FINISHED -> 0L
        else -> remainCached
    }

    /** tick 检查到点（运行中由前台服务驱动）。@return true 表示刚刚到点 */
    fun finishIfDue(now: Long = SystemClock.elapsedRealtime()): Boolean {
        if (state == RunState.RUNNING && remain(now) <= 0L) { state = RunState.FINISHED; return true }
        return false
    }

    /** 闹钟兜底触发（进程被杀后由 AlarmReceiver 调用） */
    fun finishByAlarm() { state = RunState.FINISHED }

    /** +1 分钟（通知栏快捷） */
    fun addMinute(now: Long = SystemClock.elapsedRealtime()): Long {
        remainCached = remain(now) + 60_000L
        totalMs += 60_000L
        return if (state == RunState.RUNNING) start(now) else -1L
    }
}

    /** 格式化工具（悬浮窗与 App 内共用）。millisDigits: 0=不显示, 1~3=显示位数（小数点不计入） */
object Fmt {
    fun clock(h24: Boolean, withSeconds: Boolean, millisDigits: Int, nowWall: Long = System.currentTimeMillis()): Triple<String, String, String> {
        val cal = Calendar.getInstance().apply { timeInMillis = nowWall }
        var h = cal.get(Calendar.HOUR_OF_DAY)
        if (!h24) { val am = h < 12; h = h % 12; if (h == 0) h = 12; _ampm = if (am) "AM" else "PM" } else _ampm = ""
        val main = "%02d:%02d".format(h, cal.get(Calendar.MINUTE))
        val sec = if (withSeconds) ":%02d".format(cal.get(Calendar.SECOND)) else ""
        // 小数点拼在截取之外：substring 计数只对数字（含点截取会少一位，鸿蒙端同此实现）
        val ms = if (millisDigits > 0) "." + "%03d".format(cal.get(Calendar.MILLISECOND)).substring(0, millisDigits.coerceIn(1, 3)) else ""
        return Triple(main, sec, ms)
    }
    private var _ampm = ""
    val ampm get() = _ampm

    fun stopwatch(ms: Long, millisDigits: Int = 3): Triple<String, String, String> {
        val t = maxOf(0L, ms)
        val h = t / 3_600_000; val m = t / 60_000 % 60; val s = t / 1000 % 60
        val main = (if (h > 0) "%02d:".format(h) else "") + "%02d:%02d".format(m, s)
        val msTxt = if (millisDigits > 0) "." + "%03d".format(t % 1000).substring(0, millisDigits.coerceIn(1, 3)) else ""
        return Triple(main, "", msTxt)
    }

    fun countdown(ms: Long): String {
        val t = (maxOf(0L, ms) + 999) / 1000
        val h = t / 3600; val m = t / 60 % 60; val s = t % 60
        return (if (h > 0) "%02d:".format(h) else "") + "%02d:%02d".format(m, s)
    }

    fun dateLine(nowWall: Long = System.currentTimeMillis()): String {
        val cal = Calendar.getInstance().apply { timeInMillis = nowWall }
        return "%d月%d日".format(cal.get(Calendar.MONTH) + 1, cal.get(Calendar.DAY_OF_MONTH))
    }

    private val WEEK = arrayOf("周日", "周一", "周二", "周三", "周四", "周五", "周六")
    fun weekLine(nowWall: Long = System.currentTimeMillis()): String =
        WEEK[Calendar.getInstance().apply { timeInMillis = nowWall }.get(Calendar.DAY_OF_WEEK) - 1]
}
