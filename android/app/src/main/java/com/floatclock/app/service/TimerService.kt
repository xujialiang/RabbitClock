package com.floatclock.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.floatclock.app.AppState
import com.floatclock.app.MainActivity
import com.floatclock.app.R
import com.floatclock.app.engine.Mode
import com.floatclock.app.engine.RunState
import com.floatclock.app.overlay.FloatWindowController

/**
 * 前台服务：持有悬浮窗 View 与每秒刷新，保证后台运行。
 * API 34+ 使用 foregroundServiceType=specialUse（清单已声明 subtype）。
 */
class TimerService : Service() {

    private lateinit var controller: FloatWindowController

    override fun onCreate() {
        super.onCreate()
        controller = FloatWindowController(this)
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startAsForeground()
                if (AppState.floatVisible.value) controller.show()
                // 服务启动时补一次（新鲜度闸门 10 分钟）；长会话的周期补校由 TimeSync 内部定时任务驱动
                com.floatclock.app.timesync.TimeSync.ensureFresh()
            }
            ACTION_STOP -> {
                controller.hide()
                running = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_REFRESH -> {
                if (AppState.floatVisible.value && !controller.isShowing) controller.show()
                if (!AppState.floatVisible.value && controller.isShowing) controller.hide()
                updateNotification()
            }
            ACTION_PAUSE_RESUME -> {
                when (AppState.mode.value) {
                    Mode.STOPWATCH -> AppState.toggleStopwatch()
                    Mode.COUNTDOWN -> AppState.toggleCountdown()
                    Mode.CLOCK -> {}
                }
                updateNotification()
            }
            ACTION_ADD_MINUTE -> { AppState.addCountdownMinute(); updateNotification() }
            ACTION_STOP_ALARM -> { com.floatclock.app.alarm.RingPlayer.stop(); AppState.stopAlarm(); updateNotification() }
            else -> startAsForeground()
        }
        updateNotification()
        return START_STICKY
    }

    override fun onDestroy() {
        controller.hide()
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ───────── 通知 ─────────
    private fun startAsForeground() {
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun updateNotification() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification())
    }

    private fun buildNotification(): Notification {
        val mode = AppState.mode.value
        val cdRunning = AppState.countdown.state == RunState.RUNNING
        val swRunning = AppState.stopwatch.running

        val title = when {
            AppState.alarming.value -> getString(R.string.alarm_done)
            mode == Mode.COUNTDOWN && AppState.countdown.active ->
                "倒计时 ${com.floatclock.app.engine.Fmt.countdown(AppState.countdown.remain())}"
            mode == Mode.STOPWATCH && AppState.stopwatch.elapsed() > 0 ->
                "秒表 ${com.floatclock.app.engine.Fmt.stopwatch(AppState.stopwatch.elapsed()).first}"
            else -> getString(R.string.notif_title)
        }

        val pauseLabel = when {
            cdRunning || swRunning -> getString(R.string.notif_action_pause)
            else -> getString(R.string.notif_action_resume)
        }

        return NotificationCompat.Builder(this, CHANNEL_TIMER)
            .setSmallIcon(android.R.drawable.ic_menu_recent_history)
            .setContentTitle(title)
            .setContentText("兔时笺运行中 · 点击打开")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(activityIntent())
            .addAction(0, pauseLabel, serviceIntent(ACTION_PAUSE_RESUME))
            .addAction(0, getString(R.string.notif_action_add1), serviceIntent(ACTION_ADD_MINUTE))
            .addAction(0, getString(R.string.notif_action_close), serviceIntent(ACTION_STOP))
            .build()
    }

    private fun activityIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0, Intent(this, MainActivity::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun serviceIntent(action: String): PendingIntent = PendingIntent.getService(
        this, action.hashCode(), Intent(this, TimerService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        const val CHANNEL_TIMER = "timer"
        const val CHANNEL_ALARM = "alarm"
        const val NOTIF_ID = 1001

        const val ACTION_START = "com.floatclock.START"
        const val ACTION_STOP = "com.floatclock.STOP"
        const val ACTION_REFRESH = "com.floatclock.REFRESH"
        const val ACTION_PAUSE_RESUME = "com.floatclock.PAUSE_RESUME"
        const val ACTION_ADD_MINUTE = "com.floatclock.ADD_MINUTE"
        const val ACTION_STOP_ALARM = "com.floatclock.STOP_ALARM"

        @Volatile
        var running = false

        fun createChannels(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_TIMER, context.getString(R.string.notif_channel_timer), NotificationManager.IMPORTANCE_LOW).apply {
                    description = context.getString(R.string.notif_channel_timer_desc)
                }
            )
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ALARM, context.getString(R.string.notif_channel_alarm), NotificationManager.IMPORTANCE_HIGH).apply {
                    description = context.getString(R.string.notif_channel_alarm_desc)
                }
            )
        }

        fun start(context: Context) {
            running = true
            ContextCompat.startForegroundService(context, Intent(context, TimerService::class.java).setAction(ACTION_START))
        }

        fun stop(context: Context) {
            running = false
            context.startService(Intent(context, TimerService::class.java).setAction(ACTION_STOP))
        }

        fun refresh(context: Context) {
            if (running) context.startService(Intent(context, TimerService::class.java).setAction(ACTION_REFRESH))
        }
    }
}
