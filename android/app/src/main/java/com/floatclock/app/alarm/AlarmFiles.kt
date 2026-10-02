package com.floatclock.app.alarm

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.core.app.NotificationCompat
import com.floatclock.app.AppState
import com.floatclock.app.R
import com.floatclock.app.service.TimerService

/** 倒计时到点兜底：精确闹钟（进程被杀也能响） */
object AlarmScheduler {

    private const val REQ = 2001

    private fun pending(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, REQ,
        Intent(context, AlarmReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    fun schedule(context: Context, triggerAtWallMs: Long) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(context)
        runCatching {
            if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
                // 无精确闹钟权限：降级为不精确但唤醒的闹钟
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtWallMs, pi)
            } else {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtWallMs, pi)
            }
        }
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pending(context))
    }
}

/** 闹钟触发：铃声 + 振动 + 高优先级通知（30s 未处理自动停） */
class AlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        AppState.init(context)
        AppState.onCountdownFinishedByAlarm()
        RingPlayer.start(context)
        showDoneNotification(context)
    }

    private fun showDoneNotification(context: Context) {
        val stopIntent = PendingIntent.getService(
            context, 0,
            Intent(context, TimerService::class.java).setAction(TimerService.ACTION_STOP_ALARM),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(context, TimerService.CHANNEL_ALARM)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(context.getString(R.string.alarm_done))
            .setContentText(context.getString(R.string.alarm_done_sub))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .addAction(0, context.getString(R.string.alarm_stop), stopIntent)
            .build()
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        nm.notify(ALARM_NOTIF_ID, n)
    }

    companion object { const val ALARM_NOTIF_ID = 3001 }
}

/** 默认闹钟铃声循环播放 + 振动，收到 STOP_ALARM 或 30s 超时后停止 */
object RingPlayer {
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var stopRunnable: Runnable? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    fun start(context: Context) {
        stop()
        val ctx = context.applicationContext
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        player = MediaPlayer().apply {
            setDataSource(ctx, uri)
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            isLooping = true
            runCatching { prepare(); start() }
        }
        vibrator = ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        val pattern = longArrayOf(0, 600, 400, 600, 400, 600, 1200)
        vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))

        val r = Runnable { stop() }
        stopRunnable = r
        handler.postDelayed(r, 30_000)
    }

    fun stop() {
        stopRunnable?.let { handler.removeCallbacks(it) }; stopRunnable = null
        player?.runCatching { stop(); release() }; player = null
        vibrator?.cancel(); vibrator = null
    }
}

/** 开机自启（默认关闭；Android 15 对 BOOT 启动 specialUse FGS 有限制，失败则静默等待用户打开 App） */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        AppState.init(context)
        if (!android.provider.Settings.canDrawOverlays(context)) return
        // 进程刚拉起，DataStore 尚未加载完成：仅尝试恢复，失败不崩
        runCatching {
            androidx.core.content.ContextCompat.startForegroundService(
                context,
                Intent(context, TimerService::class.java).setAction(TimerService.ACTION_START),
            )
        }
    }

    companion object {
        fun setEnabled(context: Context, on: Boolean) {
            val pm = context.packageManager
            val cn = ComponentName(context, BootReceiver::class.java)
            pm.setComponentEnabledSetting(
                cn,
                if (on) android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                android.content.pm.PackageManager.DONT_KILL_APP,
            )
        }
    }
}
