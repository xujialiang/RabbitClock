# 兔时笺 · iOS 版

Swift + SwiftUI（iOS 16+），与 Android/Harmony 端同规格。全局悬浮走 **PiP（画中画）通道**（iOS 无悬浮窗权限）：时钟逐帧渲染进 `AVSampleBufferDisplayLayer` → `AVPictureInPictureController`，后台音频循环静音保活（Info.plist 已声明 `UIIBackgroundModes: audio`）。

> ✅ 2026-10-02 已在本机 **Xcode 26.6 + iPhone 16 Pro 模拟器（iOS 18.3）编译并冒烟通过**：大时钟/时间源校准（北京时间 +0.0970s 实测）/秒表/倒计时/画中画开关/三 Tab 正常。PiP 行为需真机验证（模拟器不支持画中画）。

## 构建

```bash
cd ios
xcodegen generate          # 生成 FloatClock.xcodeproj（需 brew install xcodegen）
open FloatClock.xcodeproj  # Xcode 里选真机/模拟器 Run（真机需开发者账号签名）
# 命令行（本机 Xcode 的 destination 服务只识别 iOS 18.3 模拟器运行时，用 target 直构）：
xcodebuild -project FloatClock.xcodeproj -target FloatClock -sdk iphonesimulator \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO SYMROOT=build/products
```

iOS 自 v1.1.0 起内置 **12 语种**（zh-Hans/en/zh-Hant/ja/ko/es/pt-BR/fr/de/it/ru/ar，App 名称/界面/日期星期全本地化，阿语 RTL）（project.yml `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` + 我的页文案）。

## 已实现（对齐双端 v0.3.1）

- **计时引擎**：`engine/TimerCore.swift` —— ContinuousClock 单调时间戳差值驱动，秒表/倒计时状态机；到点本地通知兜底（进程被杀也触达）
- **时间源同步**：`timesync/` —— SNTP 直连授时中心（Network.framework UDP，被拦回落 HTTP 秒沿法）+ 淘宝/大麦 mtop 8 样本最优中位数 + 京东/美团/拼多多/云闪付预测秒沿突发轮询；晶振漂移外推；手动微调 ±10ms；10 分钟闸门 + 回前台/周期自动补校；8 源可切
- **显示延迟补偿**：`engine/DisplayTiming.swift` —— ProMotion `maximumFramesPerSecond` + 呈现深度（1/1.5/2 帧可调）+ 扫描位置；App 内大钟秒沿对齐（自定义 `ClockTick` TimelineSchedule）；**PiP 链路另加视频管线约 1 帧**
- **悬浮（PiP）**：`pip/PipClock.swift` —— CVPixelBuffer 逐帧绘制（胶囊背景 + 等宽数字），秒级 15fps/毫秒 30fps 自适应，PiP 系统控件负责关闭/恢复
- **界面**：计时（大钟点击切回时钟模式/秒表/倒计时自适应 chips + 自定义分钟）/样式/我的/时间源页，与双端同构

## ⚠️ 真机验收清单（PiP 为 Go/No-Go）

1. 首次开启悬浮：系统画中画弹窗授权 → PiP 窗口出现并走秒
2. 切到别的 App / 锁屏：PiP 是否持续（后台音频保活）——iOS 杀后台策略下约 10~30 分钟
3. PiP 内显示：北京时间偏差与 App 内一致；毫秒档位 30fps 流畅度
4. PiP ✕ 关闭后 App 内开关自动复位
5. 倒计时到点：锁屏通知触达

## 与双端的差异（平台特性）

| 能力 | Android/鸿蒙 | iOS |
| --- | --- | --- |
| 全局悬浮 | 系统悬浮窗权限 | PiP 画中画（近黑底，无透明） |
| 悬浮内交互 | 拖动/捏合/双击最小化 | PiP 系统控件（拖动/关闭/恢复） |
| vsync | Choreographer / 无 | ProMotion 最高 120Hz |
| 开机自启 | 支持 | 不允许（无此概念） |
