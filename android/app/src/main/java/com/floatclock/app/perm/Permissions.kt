package com.floatclock.app.perm

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

data class LabeledIntent(val label: String, val intent: Intent)

/** 权限检测与跳转（含分厂商 OEM 引导路径） */
object Permissions {

    fun overlayGranted(context: Context): Boolean = Settings.canDrawOverlays(context)

    /** 直达本应用的「显示在其他应用上层」设置页 */
    fun overlayIntent(context: Context): Intent =
        Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}"))

    fun batteryIntent(): Intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)

    fun notificationsGranted(context: Context): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    /** 直达本应用的通知设置页（运行时权限被拒后的兜底路径） */
    fun notificationIntent(context: Context): Intent =
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** 厂商额外的自启/后台设置页（跳转失败由调用方捕获降级为图文引导） */
    fun oemSteps(manufacturer: String = Build.MANUFACTURER.lowercase()): List<LabeledIntent> {
        fun comp(pkg: String, cls: String) = Intent().setComponent(ComponentName(pkg, cls))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        return when {
            manufacturer.contains("xiaomi") || manufacturer.contains("redmi") -> listOf(
                LabeledIntent("自启动（小米）", comp("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")),
                LabeledIntent("省电策略设为无限制（小米）", Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)),
            )
            manufacturer.contains("oppo") || manufacturer.contains("realme") || manufacturer.contains("oneplus") -> listOf(
                LabeledIntent("允许悬浮窗 & 后台运行（OPPO 系）", comp("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity")),
            )
            manufacturer.contains("vivo") || manufacturer.contains("iqoo") -> listOf(
                LabeledIntent("后台高耗电允许（vivo）", comp("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity")),
            )
            manufacturer.contains("huawei") || manufacturer.contains("honor") -> listOf(
                LabeledIntent("应用启动管理·手动管理（华为/荣耀）", comp("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity")),
            )
            manufacturer.contains("samsung") -> listOf(
                LabeledIntent("电池·不受限制（三星）", Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)),
            )
            else -> listOf(
                LabeledIntent("电池优化白名单", Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)),
            )
        }
    }
}
