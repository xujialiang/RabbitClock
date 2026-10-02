# App Store 提交资料（复制到 App Store Connect 表单）

> 生成于 2026-10-02 ｜ 兔时笺 v1.1.2 (12) ｜ Bundle ID：com.rabbitai-lab.floatclock（已定，Xcode 与 App Store Connect 保持一致）

## 基础信息

- **App 名称**：兔时笺
- **副标题**（30 字内）：精准悬浮时钟·秒表倒计时
- **主要语言**：简体中文
- **主要类别**：工具；次要类别：效率
- **价格**：免费（无内购、无广告）

## 关键词（100 字符内，逗号分隔）

```
时钟,悬浮时钟,秒表,倒计时,计时器,抢购,抢票,毫秒,北京时间,对时,画中画,番茄钟,提醒,正计时,ntp
```

## 描述（App Description）

```
兔子时钟 —— 看一眼就准的悬浮时钟。

【为什么准】
· 默认显示北京时间：通过 NTP 协议直连中国国家授时中心，毫秒级校准
· 抢购抢票前可切换到淘宝/大麦/京东/美团/拼多多/云闪付的服务器时间，与目标平台同频
· 显示延迟补偿：按屏幕刷新率与显示位置逐帧补偿，看到的时刻≈真实时刻
· 晶振漂移外推：两次校准之间依然保持精准，每 10 分钟自动补校

【悬浮显示】
· 画中画悬浮时钟，切到任意 App 都能看到时间
· 秒表 / 倒计时同步悬浮，到点本地通知必达
· 颜色、大小（0.7×–3.8×）、透明度、毫秒位数（1–3 位）自由定制

【更多特性】
· 秒表与倒计时为时间戳驱动，锁屏恢复零累计误差
· 倒计时支持自定义分钟数，到点通知+提醒音
· 手动微调 ±10 毫秒，适合刻意提前/延后的场景
· 无广告、不收集任何数据；除时间源校准外不联网

适用于：抢购秒杀对时、抢票、考试计时、烹饪、健身、实验记录等一切需要精准时间的场景。
```

## 推广文本（Promotional Text，可随时改）

```
支持画中画悬浮！NTP 直连国家授时中心，毫秒级精准对时，抢购抢票必备。
```

## 新版本说明（What's New）

```
首个 App Store 版本：北京时间 NTP 校准、8 大时间源、画中画悬浮时钟、秒表/倒计时、显示延迟补偿。
```

## 年龄分级问卷答案

- 暴力/色情/赌博等全部「无」；用户生成内容「无」；不加限制
- **分级结果：4+**

## 隐私（Privacy → App Privacy 表单）

- **不收集任何数据**（Data Types 全部不勾选）
- 隐私政策 URL：https://xujialiang.github.io/RabbitClock/privacy-policy.html（GitHub Pages，随 site/dist 自动部署）

## 出口合规

- 仅使用 HTTPS/标准 NTP，不含加密实现 → 「使用标准加密豁免」
- Info.plist 已声明 `ITSAppUsesNonExemptEncryption: false`

## 审核备注（App Review Information → Notes，重要！）

```
审核员您好：

1) 「悬浮显示」使用的是系统标准的画中画（Picture in Picture）能力：
   App 将当前时间渲染为视频画面，通过 AVPictureInPictureController 显示，
   供用户在其它应用上方查看时间（计时场景）。这是 iOS 上实现跨应用时间显示的
   唯一官方途径，同类时钟 App（如各种秒抢/悬浮时钟）均采用此方式上架。

2) 后台音频（UIBackgroundModes: audio）用于画中画的持续显示：
   App 需保持活跃的播放会话，画中画窗口才能持续刷新时间，
   我们不播放任何可听内容，不打扰用户。

3) 时间校准通过标准 NTP（UDP 123）与 HTTP Date 头实现，
   仅在用户打开「时间源」页或开启悬浮时访问所选时间服务器，
   不上传任何用户数据。

演示路径：打开 App → 首页即见大时钟与「⏱ 北京时间」校准状态；
点击该胶囊进入「时间源」页可看校准细节；开启「悬浮窗（画中画）」开关体验悬浮时钟。
```

## 需要的用户侧素材（已备好）

| 文件 | 用途 |
| --- | --- |
| `store/icon1024.png` | App 图标 1024×1024（App Store Connect 上传） |
| `store/screenshots/01-home.png` | 截图1·首页（大时钟+北京时间校准+秒表/倒计时/画中画开关） |
| `store/screenshots/02-style.png` | 截图2·样式（颜色/背景/大小/透明度/显示元素定制） |
| `store/screenshots/03-timesource.png` | 截图3·时间源（授时中心校准状态+8源列表+手动微调） |
| `store/screenshots/04-me.png` | 截图4·我的（设置与关于） |

四张均为 **1284×2778（6.5 英寸组竖屏，App Store Connect 接受的尺寸）**，直接逐张上传即可（最多可传 10 张）。
如需补拍：`env SIMCTL_CHILD_SHOT_PAGE=style xcrun simctl launch <UDID> com.rabbitai-lab.floatclock`（page 可为 timer/style/me/timesource），截图后 `sips -z 2778 1284` 缩放。
