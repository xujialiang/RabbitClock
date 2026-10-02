package com.floatclock.app.overlay

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import com.floatclock.app.AppState

/** 负责悬浮窗 View 的 WindowManager 生命周期与位置 */
class FloatWindowController(private val context: Context) {

    private val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private var view: FloatClockView? = null

    val isShowing: Boolean get() = view != null

    fun show() {
        if (!Settings.canDrawOverlays(context)) return
        if (view != null) return
        val v = FloatClockView(context, this)
        wm.addView(v, buildParams(v.initialX(), v.initialY()))
        view = v
    }

    /** 调整悬浮窗尺寸（最小化/还原） */
    fun updateSize(w: Int, h: Int) {
        val v = view ?: return
        val p = v.layoutParams as? WindowManager.LayoutParams ?: return
        p.width = w; p.height = h
        runCatching { wm.updateViewLayout(v, p) }
    }

    fun hide() {
        view?.let { runCatching { wm.removeView(it) } }
        view = null
    }

    fun updatePosition(x: Int, y: Int) {
        val v = view ?: return
        val p = v.layoutParams as? WindowManager.LayoutParams ?: return
        p.x = x; p.y = y
        runCatching { wm.updateViewLayout(v, p) }
    }

    /** 尺寸/样式变化后由 View 主动调用，重建布局参数 */
    fun relayout() {
        val v = view ?: return
        val p = v.layoutParams as? WindowManager.LayoutParams ?: return
        runCatching { wm.updateViewLayout(v, p) }
    }

    private fun buildParams(x: Int, y: Int): WindowManager.LayoutParams =
        WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            this.x = x; this.y = y
        }
}
