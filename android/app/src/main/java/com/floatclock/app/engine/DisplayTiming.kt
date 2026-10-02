package com.floatclock.app.engine

import android.content.Context
import android.view.WindowManager
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * 显示时序：把「计算时刻的时间」换算成「像素点亮时刻的时间」。
 *
 * 一帧的可见延迟 = 呈现深度 × 刷新周期 + 扫描位置 × 刷新周期：
 * - 呈现深度：本 tick 绘制的帧在下 1 个 vsync 呈现（SurfaceFlinger 常规路径）；
 *   悬浮窗经合成器叠加的路径偶有 2 帧深度，开放为可调（1 / 1.5 / 2 帧）；
 * - 扫描位置：面板自上而下逐行刷新，屏幕顶部 ≈ 0、底部 ≈ 1 个周期，
 *   时钟悬浮在哪一行就补哪一行的比例（这正是 iOS 竞品“结合刷新率”的做法）。
 */
object DisplayTiming {

    /** 呈现深度（帧）：默认 1；真机若见整体滞后半秒级可调大（持久化于 DataStore） */
    val presentDepthVsyncs = MutableStateFlow(1f)

    fun refreshRateHz(ctx: Context): Float = runCatching {
        @Suppress("DEPRECATION")
        (ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
            .defaultDisplay?.refreshRate ?: 60f
    }.getOrDefault(60f)

    fun periodMs(hz: Float): Float = if (hz > 1f) 1000f / hz else 1000f / 60f

    /**
     * 位于屏幕高度占比 yFrac（0=顶 1=底）的像素，从「现在」到「真正点亮」的延迟。
     * 附带值 + 该延迟 = 应显示的时间。
     */
    fun compMs(hz: Float, yFrac: Float, depth: Float = presentDepthVsyncs.value): Float =
        periodMs(hz) * (depth + yFrac.coerceIn(0f, 1f))
}
