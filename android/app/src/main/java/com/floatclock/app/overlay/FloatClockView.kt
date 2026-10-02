package com.floatclock.app.overlay

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.TypedValue
import android.view.Choreographer
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import com.floatclock.app.AppState
import com.floatclock.app.engine.BgKind
import com.floatclock.app.engine.DisplayTiming
import com.floatclock.app.engine.Fmt
import com.floatclock.app.engine.Mode
import com.floatclock.app.timesync.TimeSync

/**
 * 兔时笺悬浮窗本体：时钟/秒表/倒计时三模式渲染，拖拽 + 贴边吸附 + 双击最小化。
 * 位置由 WindowManager.LayoutParams(x,y) 管理（gravity = TOP|START），
 * 本 View 只负责内容渲染与手势，移动通过 [FloatWindowController.updatePosition]。
 */
@SuppressLint("ClickableViewAccessibility")
class FloatClockView(
    context: Context,
    private val controller: FloatWindowController,
) : FrameLayout(context) {

    private val density = resources.displayMetrics.density
    private val screenW = resources.displayMetrics.widthPixels
    private val screenH = resources.displayMetrics.heightPixels
    private fun dp(v: Float) = (v * density).toInt()

    // ── 内容 ──
    private val content = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
    }
    private val mainText = TextView(context).apply {
        typeface = Typeface.MONOSPACE
        includeFontPadding = false
    }
    private val subText = TextView(context).apply { includeFontPadding = false }
    // 关闭按钮：绝对定位在窗口右上角（悬浮于内容之上，不参与流式布局、不撑大窗口）
    private var closeShown = false
    private val btnHide = controlBtn("✕").apply { visibility = GONE }
    private val dot = View(context).apply { visibility = GONE }

    // ── 状态 ──
    private val handler = Handler(Looper.getMainLooper())
    private val refreshHz = DisplayTiming.refreshRateHz(context)
    private val choreographer by lazy { Choreographer.getInstance() }
    private var frameDriven = false
    private var minimized = false
    private var batteryPct = -1
    private var winX = 0      // 当前窗口位置（= LayoutParams.x/y）
    private var winY = 0

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
            if (level >= 0 && scale > 0) batteryPct = level * 100 / scale
        }
    }

    private val gesture = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
            if (minimized) return true
            closeShown = !closeShown
            btnHide.visibility = if (closeShown) VISIBLE else GONE
            return true
        }
        override fun onDoubleTap(e: MotionEvent): Boolean {
            minimized = !minimized
            applyMinimized()
            return true
        }
    })

    /**
     * 双指捏合缩放：捏合期间布局冻结在最大档，仅用 scaleX/scaleY 纯变换缩放
     * （GPU 合成，零重排、零窗口 resize —— 逐帧改字号会引发每帧 WRAP_CONTENT
     * 窗口重设尺寸，跨进程且表面重建，必然抖卡）。收手时一次性定稿真实档位。
     */
    private var pinchBaseScale = 1f
    private var pinching = false
    private var pinchLiveTarget = 0f
    private val scaleGesture = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
            if (minimized) return false
            val oldW = content.width
            val oldH = content.height
            pinching = true
            pinchBaseScale = AppState.style.value.scale
            pinchLiveTarget = pinchBaseScale
            render() // 布局跳到最大档 + 设初始变换（一次 resize）
            // 窗口随最大档变大后，视觉中心会偏移；补偿回原位
            content.post {
                winX -= (content.width - oldW) / 2
                winY -= (content.height - oldH) / 2
                controller.updatePosition(winX, winY)
            }
            return true
        }

        override fun onScale(detector: ScaleGestureDetector): Boolean {
            pinchLiveTarget = (pinchBaseScale * detector.scaleFactor).coerceIn(0.7f, 3.8f)
            val f = pinchLiveTarget / MAX_LAYOUT_SCALE
            content.scaleX = f
            content.scaleY = f
            return true
        }

        override fun onScaleEnd(detector: ScaleGestureDetector) {
            val target = pinchLiveTarget
            val wMax = content.width
            val hMax = content.height
            pinching = false
            AppState.updateStyle { it.copy(scale = target) } // 唯一一次持久化
            render() // 布局落到真实档位，变换归位（一次 resize）
            // 视觉中心保持不动：按新旧窗口尺寸差平移回去
            content.post {
                winX += (wMax - content.width) / 2
                winY += (hMax - content.height) / 2
                controller.updatePosition(winX, winY)
            }
        }
    })

    init {
        content.addView(mainText)
        content.addView(subText)
        addView(content)
        addView(btnHide, LayoutParams(WRAP, WRAP, Gravity.TOP or Gravity.END))
        addView(dot, LayoutParams(dp(22f), dp(22f)).apply { gravity = Gravity.CENTER })
        setOnTouchListener(::handleTouch)

        context.registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))

        btnHide.setOnClickListener { AppState.hideFloat() }

        winX = initialX(); winY = initialY()
        controller.updatePosition(winX, winY)
        render()
    }

    /**
     * 走秒循环在视图 attach 后启动（不能在 init 里启动：
     * tickRunnable 声明在 init 之后，那时字段尚未初始化，post 出去的是空任务）
     */
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        handler.removeCallbacks(tickRunnable)
        handler.postDelayed(tickRunnable, 50)
    }

    override fun onDetachedFromWindow() {
        handler.removeCallbacks(tickRunnable)
        stopFrames()
        super.onDetachedFromWindow()
    }

    fun initialX(): Int {
        val s = AppState.style.value
        return if (s.x >= 0) s.x else (screenW - dp(150f)) / 2
    }

    fun initialY(): Int {
        val s = AppState.style.value
        return if (s.y >= 0) s.y else dp(90f)
    }

    fun destroy() {
        handler.removeCallbacksAndMessages(null)
        stopFrames()
        runCatching { context.unregisterReceiver(batteryReceiver) }
    }

    // ───────── 显示延迟补偿 ─────────

    /** 时钟中心所在屏幕高度占比（面板自上而下扫描，底部比顶部晚约一个刷新周期点亮） */
    private fun yFrac(): Float {
        if (screenH <= 0) return 0.5f
        val h = if (width > 0 && height > 0) height else dp(40f)
        return ((winY + h / 2f) / screenH).coerceIn(0f, 1f)
    }

    /** 本窗口位置的像素「从现在到点亮」的延迟（呈现 1 个 vsync + 扫描位置） */
    private fun compMs(): Double = DisplayTiming.compMs(refreshHz, yFrac()).toDouble()

    /** 毫秒显示需要逐帧刷新（秒表任意时刻 / 时钟开毫秒）；最小化时降频 */
    private fun fastMode(): Boolean = !minimized && (
        AppState.mode.value == Mode.STOPWATCH ||
            (AppState.mode.value == Mode.CLOCK && AppState.style.value.showMillis)
        )

    // ───────── 刷新循环 ─────────

    /**
     * 快路径：Choreographer 逐帧驱动。doFrame 的 frameTimeNanos 是本帧目标 vsync，
     * 该帧在 frameTimeNanos + 补偿量（呈现深度+扫描位置）× 周期 时点亮 ——
     * 渲染值 = 现在的时间 + (点亮时刻 − 当前时刻)，每帧自校正，看到的即真实时刻。
     */
    private val frameCb = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!frameDriven) return
            // 渲染异常不能中断循环（否则悬浮窗会永久冻结）
            runCatching {
                val deltaMs = (frameTimeNanos + compMs() * 1_000_000.0 - System.nanoTime()) / 1e6
                render(deltaMs)
                if (AppState.countdown.finishIfDue()) AppState.onCountdownFinishedByTick()
            }
            if (fastMode()) choreographer.postFrameCallback(this)
            else { frameDriven = false; scheduleNext() }
        }
    }

    /** 慢路径：秒级刷新。提前一个补偿量提交，让秒翻转的帧恰好在真实整秒边界点亮 */
    private val tickRunnable: Runnable = object : Runnable {
        override fun run() {
            runCatching {
                render(compMs())
                if (AppState.countdown.finishIfDue()) AppState.onCountdownFinishedByTick()
            }
            scheduleNext()
        }
    }

    private fun scheduleNext() {
        if (fastMode()) {
            handler.removeCallbacks(tickRunnable)
            if (!frameDriven) {
                frameDriven = true
                choreographer.postFrameCallback(frameCb)
            }
        } else {
            stopFrames()
            val delay = (TimeSync.msToNextSecond() - compMs().toLong()).coerceAtLeast(5L)
            handler.postDelayed(tickRunnable, delay)
        }
    }

    private fun stopFrames() {
        frameDriven = false
        choreographer.removeFrameCallback(frameCb)
    }

    // ───────── 渲染 ─────────

    /**
     * @param displayDeltaMs 显示延迟补偿：渲染的值 = 当前时刻 + 该补偿，
     *   即「这一帧真正点亮时」的真实时间。引擎状态判定（到点等）不参与补偿。
     */
    private fun render(displayDeltaMs: Double = compMs()) {
        if (minimized) return
        val s = AppState.style.value
        val m = AppState.mode.value
        val alert = AppState.alarming.value && m == Mode.COUNTDOWN

        val main: String
        var sec: String
        var ms: String
        // CLOCK 的日期/星期与时间读数取同一「显示时间」（校准+补偿）；秒表/倒计时是时长语义，
        // 只加显示补偿、不受时间源影响
        var dateWallNow = System.currentTimeMillis()
        val monoNow = SystemClock.elapsedRealtime() + displayDeltaMs.toLong()
        when (m) {
            Mode.CLOCK -> {
                val displayNow = TimeSync.now() + Math.round(displayDeltaMs)
                val (a, b, c) = Fmt.clock(s.hour24, s.showSeconds, if (s.showMillis) s.millisDigits else 0, displayNow)
                main = a; sec = b; ms = c
                dateWallNow = displayNow
            }
            Mode.STOPWATCH -> {
                val (a, b, c) = Fmt.stopwatch(AppState.stopwatch.elapsed(monoNow), s.millisDigits.coerceAtLeast(1))
                main = a; sec = b; ms = c
            }
            Mode.COUNTDOWN -> {
                main = Fmt.countdown(AppState.countdown.remain(monoNow)); sec = ""; ms = ""
            }
        }
        mainText.text = buildString {
            append(main)
            if (sec.isNotEmpty()) append(sec)
            if (ms.isNotEmpty()) append(ms)
        }

        val bits = mutableListOf<String>()
        if (s.showDate) bits.add(Fmt.dateLine(dateWallNow))
        if (s.showWeek) bits.add(Fmt.weekLine(dateWallNow))
        if (s.showBattery && batteryPct >= 0) bits.add("$batteryPct%")
        if (bits.isEmpty()) subText.visibility = GONE else { subText.visibility = VISIBLE; subText.text = bits.joinToString(" · ") }

        applyStyle(alert)
    }

    // ───────── 样式 ─────────
    private fun applyStyle(alert: Boolean) {
        val s = AppState.style.value
        // 布局基准：平时=真实档位（无变换）；捏合中=最大档 + 纯变换（见 scaleGesture 注释）
        val layoutBase = if (pinching) MAX_LAYOUT_SCALE else s.scale
        val visualScale = if (pinching) pinchLiveTarget / MAX_LAYOUT_SCALE else 1f
        val baseColor = Color.parseColor(s.colorHex)
        val alertColor = Color.parseColor("#FF5252")
        val pulse = if (alert) {
            val t = (SystemClock.elapsedRealtime() % 800) / 800f
            if (t < 0.5f) t * 2 else (1f - t) * 2
        } else 0f
        val color = ColorUtils.blendARGB(baseColor, alertColor, if (alert) 0.4f + pulse * 0.6f else 0f)

        mainText.setTextSize(TypedValue.COMPLEX_UNIT_PX, dp(24f) * layoutBase)
        subText.setTextSize(TypedValue.COMPLEX_UNIT_PX, dp(9f) * layoutBase)
        content.scaleX = visualScale
        content.scaleY = visualScale
        mainText.setTextColor(color)
        subText.setTextColor(color)
        alpha = s.opacity.coerceIn(0.3f, 1f)

        val dark = Color.argb(200, 8, 12, 24)
        val pad = (dp(9f) * layoutBase).coerceAtLeast(dp(4f).toFloat()).toInt()
        content.setPadding(pad, (pad * 0.7f).toInt(), pad, (pad * 0.7f).toInt())

        when (s.bg) {
            BgKind.CAPSULE -> {
                content.background = GradientDrawable().apply {
                    cornerRadius = dp(999f).toFloat()
                    setColor(ColorUtils.blendARGB(dark, color, 0.14f))
                    setStroke(dp(1f), ColorUtils.setAlphaComponent(color, 86))
                }
                mainText.setShadowLayer(0f, 0f, 0f, Color.TRANSPARENT)
            }
            BgKind.CARD -> {
                content.background = GradientDrawable().apply {
                    cornerRadius = dp(14f).toFloat()
                    setColor(ColorUtils.blendARGB(dark, color, 0.12f))
                    setStroke(dp(1f), ColorUtils.setAlphaComponent(color, 102))
                }
                mainText.setShadowLayer(0f, 0f, 0f, Color.TRANSPARENT)
            }
            BgKind.OUTLINE -> {
                content.background = null
                mainText.setShadowLayer(dp(9f).toFloat(), 0f, 0f, ColorUtils.setAlphaComponent(color, 165))
            }
        }
    }

    private fun applyMinimized() {
        if (minimized) {
            content.visibility = GONE
            btnHide.visibility = GONE
            dot.visibility = VISIBLE
            dot.background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor(AppState.style.value.colorHex))
                setStroke(dp(2f), Color.argb(200, 255, 255, 255))
            }
            controller.updateSize(dp(22f), dp(22f))
        } else {
            content.visibility = VISIBLE
            dot.visibility = GONE
            btnHide.visibility = if (closeShown) VISIBLE else GONE
            controller.updateSize(WRAP, WRAP)
            render()
            scheduleNext() // 从最小化恢复：若毫秒模式需要立刻回到逐帧驱动
        }
    }

    // ───────── 拖拽 & 贴边吸附 & 捏合缩放 ─────────
    private var downRawX = 0f
    private var downRawY = 0f
    private var grabX = 0    // 按下时窗口坐标
    private var grabY = 0
    private var moved = false
    private var pinched = false

    private fun handleTouch(v: View, e: MotionEvent): Boolean {
        gesture.onTouchEvent(e)
        scaleGesture.onTouchEvent(e)
        if (scaleGesture.isInProgress) { moved = true; pinched = true; return true }
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downRawX = e.rawX; downRawY = e.rawY
                grabX = winX; grabY = winY
                moved = false
            }
            MotionEvent.ACTION_MOVE -> {
                // 第二根手指落下后进入捏合，忽略拖拽位移（避免窗口跟着跳）
                if (e.pointerCount >= 2 || pinched) return true
                val dx = (e.rawX - downRawX).toInt()
                val dy = (e.rawY - downRawY).toInt()
                if (kotlin.math.abs(dx) > 3 || kotlin.math.abs(dy) > 3) moved = true
                if (!moved) return true
                winX = (grabX + dx).coerceIn(-width * 2 / 3, screenW - width / 3)
                // 上界 0：悬浮窗允许贴到屏幕最顶端（含状态栏区域），由用户自行取舍
                winY = (grabY + dy).coerceIn(0, screenH - height / 2)
                controller.updatePosition(winX, winY)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                // 捏合过就不再触发贴边吸附（窗口没动）
                if (moved && !pinched) snapAndSave()
                if (e.actionMasked == MotionEvent.ACTION_UP || e.pointerCount <= 1) pinched = false
            }
        }
        return true
    }

    private fun snapAndSave() {
        val s = AppState.style.value
        if (s.snap) {
            val cx = winX + width / 2
            val targetX = if (cx < screenW / 2) dp(10f) else screenW - width - dp(10f)
            animateMoveTo(targetX, winY) { x, y -> AppState.updateStyle { it.copy(x = x, y = y) } }
        } else {
            AppState.updateStyle { it.copy(x = winX, y = winY) }
        }
    }

    private fun animateMoveTo(toX: Int, toY: Int, onEnd: (Int, Int) -> Unit) {
        val fromX = winX; val fromY = winY
        val startAt = SystemClock.uptimeMillis()
        val duration = 220L
        val step = object : Runnable {
            override fun run() {
                val t = ((SystemClock.uptimeMillis() - startAt).toFloat() / duration).coerceIn(0f, 1f)
                val eased = 1f - (1f - t) * (1f - t)
                winX = (fromX + (toX - fromX) * eased).toInt()
                winY = (fromY + (toY - fromY) * eased).toInt()
                controller.updatePosition(winX, winY)
                if (t < 1f) handler.postDelayed(this, 16) else onEnd(winX, winY)
            }
        }
        handler.post(step)
    }

    private fun controlBtn(label: String) = TextView(context).apply {
        text = label
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        gravity = Gravity.CENTER
        val pad = dp(5f)
        setPadding(pad * 2, pad, pad * 2, pad)
        background = GradientDrawable().apply {
            cornerRadius = dp(8f).toFloat()
            setColor(Color.argb(70, 255, 255, 255))
        }
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            marginEnd = dp(6f)
        }
    }

    companion object {
        private const val WRAP = android.view.WindowManager.LayoutParams.WRAP_CONTENT
        /** 捏合期间的布局基准档位（窗口一次性放大到最大，变换缩放永不越界裁剪） */
        private const val MAX_LAYOUT_SCALE = 3.8f
    }
}
