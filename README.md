# 兔时笺（悬浮时钟）· HarmonyOS / Android / iOS 版

> 2026-10-02 ｜ 立项材料已确认，进入开发（按《docs/04-开发计划》8 周节奏，当前完成三端代码，Android/iOS 已编译验证）

```
timer/
├── docs/                          立项文档
│   ├── 01-调研报告.md              平台可行性 / 竞品 / 风险
│   ├── 02-产品需求文档PRD.md        功能范围（P0/P1/P2）、验收标准
│   ├── 03-技术方案设计.md          双端架构、悬浮窗实现、保活策略
│   └── 04-开发计划.md             里程碑
├── prototype/                     高保真交互原型（浏览器直接打开）
├── android/                       ✅ Android 版（Kotlin + Compose，见 android/README.md）
├── harmony/                       ✅ 鸿蒙版（ArkTS + ArkUI，见 harmony/README.md）
└── ios/                           ✅ iOS 版（Swift + SwiftUI + PiP 悬浮，见 ios/README.md）
```

## 当前进度（Android/iOS 编译通过；鸿蒙待 DevEco 构建验证）

| 端 | 状态 |
| --- | --- |
| Android（`android/`） | ✅ **assembleDebug / assembleRelease 均编译通过**（本机 SDK 已装 `~/Library/Android/sdk`），待真机验收 |
| 鸿蒙（`harmony/`） | ✅ 代码完成（静态自查通过），待安装 DevEco Studio 构建验证 |
| iOS（`ios/`） | ✅ **Xcode 26.6 + iPhone 16 Pro 模拟器编译并冒烟通过**（时间源校准实测出偏差），PiP 待真机 |

| 模块 | Android | 鸿蒙 |
| --- | --- | --- |
| 计时引擎（时间戳驱动） | ✅ `engine/TimerCore.kt` | ✅ `ets/engine/TimerEngine.ets` |
| 时间源同步（默认北京时间·授时中心；8 源可切/手动微调 ±10ms） | ✅ `timesync/TimeSync.kt` + 时间源页 | ✅ `ets/timesync/TimeSync.ets` + `pages/TimeSourcePage.ets` |
| 悬浮窗（拖动/吸附/双击最小化/三位毫秒） | ✅ `overlay/` + specialUse FGS | ✅ `TYPE_FLOAT` 窗口 + PanGesture |
| 倒计时到点兜底 | ✅ 精确闹钟 + 铃声振动 | ✅ reminderAgentManager 代理提醒 |
| 权限引导 | ✅ 3 步 + 5 厂商直达 | ✅ 系统弹窗 + 状态检查 |
| 界面（首页/样式/记录/我的） | ✅ Compose 四页 | ✅ ArkUI 三页（记录页 P1） |
| 大小 0.7×–3.8×（滑杆 + 悬浮窗双指捏合）/ 透明度 / 主题色 / 显示元素 | ✅ | ✅ |

> 时间源说明：默认显示**北京时间**——优先 SNTP（UDP123）直连国家授时中心 ntp.ntsc.ac.cn（备选阿里公共 NTP；UDP 被网络拦截时自动回落授时中心官网 HTTP 秒沿法，±0.1s），NTP 通道可达 ±0.005~0.02s。接口类源（淘宝/大麦）8 样本最优中位数 ±0.02s；其余 Date 头源（京东/美团/拼多多/云闪付）预测秒沿 + 突发轮询 ±0.05~0.1s。高精度源在两次校准间按晶振漂移自动外推。校准时机：打开时间源页/切换源/开启悬浮窗/**回前台**（10 分钟新鲜度闸门，新鲜不发请求），应用存活期间**每 10 分钟自动补校**。

**下一步**（详见各端 README）：
1. Android Studio 打开 `android/` 构建 → 真机跑验收用例（android/README.md 末尾 4 条）
2. DevEco Studio 打开 `harmony/` 签名构建 → 真机跑 Spike 实测矩阵（harmony/README.md ⚠️ 节）——这是鸿蒙版 Go/No-Go 数据
