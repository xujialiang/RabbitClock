# 兔时笺 · HarmonyOS 版（HarmonyOS NEXT）

ArkTS + ArkUI（Stage 模型），API 12+（HarmonyOS NEXT 5.0 及以上），仅手机。

## 打开与运行

1. 安装 **DevEco Studio 5.0+**（本机当前未安装）。
2. 用 DevEco Studio 打开本目录（`harmony/`）——项目结构与官方模板一致，首次打开会自动安装 SDK 与 hvigor 依赖。
3. **File → Project Structure → Signing Configs**，勾选 "Automatically generate signature" 完成自动签名（需要华为开发者账号登录）。
4. 连接 HarmonyOS NEXT 真机（模拟器不支持悬浮窗权限的完整行为），点 Run。

## 权限（module.json5 已声明）

| 权限 | 类型 | 用途 |
| --- | --- | --- |
| `ohos.permission.FLOAT_WINDOW` | user_grant | 全局悬浮窗（首用时系统弹窗） |
| `ohos.permission.PUBLISH_AGENT_REMINDER` | system_grant | 倒计时到点的系统级代理提醒（进程被杀也必达） |
| `ohos.permission.INTERNET` | system_grant | 时间源校准（默认北京时间·国家授时中心；仅校准时访问所选服务器） |

> ⚠️ 不要换成 `ohos.permission.SYSTEM_FLOAT_WINDOW`（ACL 受限，三方申请直接报错，网上一批旧教程在传）。

## 已实现（对应 PRD P0）

- **计时引擎**：`ets/engine/TimerEngine.ets` —— 时间戳差值驱动，与 Android 端同构；秒表/倒计时状态机、三位毫秒 `.sss`
- **时间源同步**：`ets/timesync/TimeSync.ets` + `ets/pages/TimeSourcePage.ets` —— 默认**北京时间**（`@ohos.net.socket` UDP SNTP 直连授时中心，被拦时回落 HTTP 秒沿法，10 分钟退避），另内置 淘宝/大麦/京东/美团/拼多多/云闪付/设备时间；JSON 源 8 样本最优 3 RTT 中位数（±0.02s），Date 头源预测秒沿 + 突发轮询 + HEAD（±0.05~0.1s）；高精度源晶振漂移外推；手动微调 ±10ms（`router` 进 `pages/TimeSourcePage`），秒表/倒计时不受影响
- **显示延迟补偿**：按 `display.refreshRate` + 悬浮窗屏高位置补偿「渲染→点亮」延迟（呈现 1 周期 + 面板扫描位置）；秒级时钟在「整秒边界−补偿」时刻补渲染使秒翻转对齐真实边界（ArkUI 无公开 vsync，为近似补偿；Android 端用 Choreographer 逐帧自校正更精确）
- **悬浮窗**：`ets/float/FloatWindowController.ets` + `ets/pages/FloatPage.ets` —— `TYPE_FLOAT` 窗口，PanGesture 拖动（vp→px 换算）、贴边吸附、双击最小化（同步 resize 窗口）、**PinchGesture 双指捏合缩放 0.7×–3.8×**、单击呼出关闭按钮、到点红色脉冲
- **到点必达**：`ets/reminder/ReminderHelper.ets` —— `reminderAgentManager` 日历类代理提醒，倒计时启动时登记、暂停/重置撤销
- **界面**：首页（大时钟/秒表/倒计时快捷/悬浮窗开关/权限状态）、样式（颜色/背景/大小 0.7×–3.8×/透明度/显示元素，@State 镜像保证即时刷新）、我的
- **持久化**：`preferences` 逐字段存储样式与位置，无 JSON 解析（ArkTS 严格模式友好）

## ⚠️ 开发首周 Spike（技术方案 §3.4，Go/No-Go 数据）

真机实测以下矩阵，结论写入产品承诺：

1. 悬浮窗显示中，App 退后台：悬浮窗持续显示/每秒刷新多久后停止？
2. 被挂起后悬浮窗是"冻结画面"还是"消失"？（恢复前后台切换是否立即恢复走字）
3. `reminderAgentManager` 到点触达率：锁屏 30min / 杀进程 / 重启后
4. 若停更：尝试引导用户"最近任务下拉加锁 + 允许后台运行"后行为是否变化

## 后续迭代（P1）

服务卡片（2×2 时钟 / 4×2 秒表）、实况窗倒计时胶囊（Live View Kit，HarmonyOS 6 支持到 0 自动结束）、计时记录页、多悬浮窗并存。
