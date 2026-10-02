# 兔时笺 · Android 版

Kotlin + Jetpack Compose，minSdk 26（Android 8.0+），targetSdk 35。

> ✅ **2026-10-02 已在本机编译通过**：`assembleDebug` 与 `assembleRelease`（R8）均 BUILD SUCCESSFUL。
> 本机 SDK 装在 `~/Library/Android/sdk`（标准位置，Android Studio 可直接复用）；`local.properties` 已配置。

## 构建命令

```bash
cd android
# 注意：当前 shell 的 JAVA_HOME 指向已卸载的旧 Android Studio 路径，需先覆盖：
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./gradlew assembleDebug          # 产物 app/build/outputs/apk/debug/app-debug.apk
./gradlew assembleRelease        # 未签名 release（R8 已启用），上架前需配置签名
```

用 Android Studio 打开本目录（`android/`）也可直接 Run 到真机。首启有 3 步权限引导：
**悬浮窗权限（必须）** → 通知权限 → 电池/厂商后台设置。

## 已实现（对应 PRD P0）

- **计时引擎**：`engine/TimerCore.kt` —— 时间戳差值驱动（单调时钟），冻结/息屏恢复零累计误差；秒表、倒计时状态机
- **时间源同步**：`timesync/TimeSync.kt` + `Sntp.kt` —— 默认**北京时间**（NTP 直连授时中心，UDP 被拦自动回落 HTTP 秒沿法，10 分钟退避），另内置 淘宝/大麦/京东/美团/拼多多/云闪付/设备时间；JSON 源 8 样本取最优 3 RTT 偏移中位数（±0.02s），Date 头源预测秒沿 + 边界前突发轮询 + HEAD/连接复用（±0.05~0.1s，实测探测 124ms→30ms）；高精度源带晶振漂移外推；手动微调 ±10ms；显示「秒沿窗口」实测值（不再是占位 RTT）
- **显示延迟补偿**：`engine/DisplayTiming.kt` —— 按屏幕刷新率 + 悬浮窗所在屏高（面板扫描位置）补偿「渲染→像素点亮」延迟；**呈现深度可调**（1/1.5/2 帧，时间源页设置）：毫秒/秒表模式 Choreographer 逐帧驱动，用 doFrame 的 vsync 时间戳每帧自校正；秒级模式提前补偿量提交使秒翻转落在真实边界。时间源页显示「屏幕 NHz · 已补偿 Xms」（对齐 iOS 竞品做法）
- **悬浮窗**：`overlay/FloatClockView.kt` + `FloatWindowController.kt` —— `TYPE_APPLICATION_OVERLAY`，三种模式渲染、拖动、贴边吸附、双击最小化、**双指捏合缩放 0.7×–3.8×**（实时调大小，收手持久化）、单击呼出关闭按钮（暂停/重置走 App 内或通知栏）、三位毫秒 `.sss`、到点红色脉冲
- **前台服务**：`service/TimerService.kt` —— specialUse 类型（API 34+）+ 常驻通知（暂停/+1 分钟/关闭）
- **到点兜底**：`alarm/AlarmFiles.kt` —— 精确闹钟（无权限自动降级）+ 闹钟铃声/振动 + 高优先级通知，进程被杀也能响
- **OEM 引导**：`perm/Permissions.kt` —— 小米/OPPO/vivo/华为荣耀/三星 的自启动/后台设置页直达
- **界面**：首页（大时钟/秒表卡/倒计时快捷/悬浮窗开关）、样式（颜色/背景/大小 0.7×–3.8×/透明度/显示元素）、记录、我的（权限体检/设置）
- 开机自启（默认关，Android 15 对 BOOT 启动 specialUse FGS 有限制，失败静默）

## 关键验证用例（真机）

1. 微信/抖音/浏览器/游戏下悬浮窗显示、拖动、走秒
2. 倒计时 5 分钟 → 锁屏 → 到点铃响振动 100% 触达；杀掉 App 进程同样触达（闹钟兜底）
3. 息屏 1 小时亮屏：时间立即正确
4. 小米/OPPO 等引导页能跳到对应设置页
5. 时间源：默认选中「北京时间」，进页面即自动校准（偏差 < 1s 量级）；切「淘宝」后显示毫秒级偏差；手动微调 ±10ms 立即反映在大钟/悬浮窗上；断网校准显示「失败·点击重试」且时钟继续用旧偏移
