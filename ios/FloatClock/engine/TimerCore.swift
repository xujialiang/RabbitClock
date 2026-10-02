import Foundation

// ───────── 计时引擎：时间戳差值驱动（与 Android/Harmony 端同构） ─────────

enum Mode { case clock, stopwatch, countdown }
enum RunState { case idle, running, paused, finished }
enum BgKind: String, Codable, CaseIterable { case capsule, card, outline }

struct Style: Codable, Equatable {
    var colorHex: String = "#22D3EE"
    var bg: BgKind = .capsule
    var scale: Double = 1.15            // 0.7 ~ 3.8
    var opacity: Double = 1.0           // 0.3 ~ 1.0
    var showSeconds = true
    var showMillis = false
    var millisDigits = 1                // 1~3
    var showDate = false
    var showWeek = false
    var showBattery = false
    var snap = true
    var hour24 = true
    var x: Double = -1
    var y: Double = -1
}

/// 单调时钟毫秒（ContinuousClock 含睡眠时间，等价 Android elapsedRealtime；
/// 不受用户改系统时间影响）。仅差值语义（进程内参考点起算）。
enum Mono {
    static let clock = ContinuousClock()
    private static let ref = clock.now

    static func nowMs() -> Double { durationMs(clock.now - ref) }

    static func durationMs(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

enum Wall {
    static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
}

/// 秒表：显示值永远由「单调时间戳差值」计算，进程冻结恢复后立即正确
final class Stopwatch {
    private(set) var running = false
    private var baseMs: Double = 0
    private var startStamp: Double = 0

    @discardableResult
    func startOrPause(nowMs: Double = Mono.nowMs()) -> Bool {
        if running {
            baseMs = elapsed(nowMs: nowMs)
            running = false
        } else {
            startStamp = nowMs
            running = true
        }
        return running
    }

    func reset() { running = false; baseMs = 0 }

    func elapsed(nowMs: Double = Mono.nowMs()) -> Double {
        baseMs + (running ? nowMs - startStamp : 0)
    }
}

/// 倒计时：目标时刻驱动（到点由本地通知兜底）
final class Countdown {
    private(set) var state: RunState = .idle
    private(set) var totalMs: Double = 5 * 60_000
    private var remainCached: Double = 5 * 60_000
    private var endStamp: Double = 0

    func setTotal(_ ms: Double) { totalMs = ms; remainCached = ms; state = .idle }

    /// 开始/继续，返回结束时刻的墙钟毫秒（用于调度本地通知兜底）
    @discardableResult
    func start(nowMs: Double = Mono.nowMs()) -> Double {
        endStamp = nowMs + remainCached
        state = .running
        return Wall.nowMs() + remainCached
    }

    func pause(nowMs: Double = Mono.nowMs()) { remainCached = remain(nowMs: nowMs); state = .paused }
    func reset() { remainCached = totalMs; state = .idle }

    func remain(nowMs: Double = Mono.nowMs()) -> Double {
        switch state {
        case .running: return max(0, endStamp - nowMs)
        case .finished: return 0
        default: return remainCached
        }
    }

    func finishIfDue(nowMs: Double = Mono.nowMs()) -> Bool {
        if state == .running && remain(nowMs: nowMs) <= 0 { state = .finished; return true }
        return false
    }
}

enum Fmt {
    static func clock(h24: Bool, withSeconds: Bool, millisDigits: Int, nowWall: Double) -> (main: String, sec: String, ms: String) {
        let d = Date(timeIntervalSince1970: nowWall / 1000)
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: d)
        var h = c.hour ?? 0
        if !h24 { h = h % 12; if h == 0 { h = 12 } }
        let main = String(format: "%02d:%02d", h, c.minute ?? 0)
        let sec = withSeconds ? String(format: ":%02d", c.second ?? 0) : ""
        let msVal = (c.nanosecond ?? 0) / 1_000_000
        let ms = millisDigits > 0 ? "." + String(format: "%03d", msVal).prefix(max(1, min(3, millisDigits))) : ""
        return (main, sec, String(ms))
    }

    static func stopwatch(_ ms: Double, millisDigits: Int = 3) -> (main: String, sec: String, ms: String) {
        let t = max(0, ms)
        let h = Int(t / 3_600_000), m = Int(t / 60_000) % 60, s = Int(t / 1000) % 60
        let main = (h > 0 ? String(format: "%02d:", h) : "") + String(format: "%02d:%02d", m, s)
        let msTxt = "." + String(format: "%03d", Int(t.truncatingRemainder(dividingBy: 1000))).prefix(max(1, min(3, millisDigits)))
        return (main, "", String(msTxt))
    }

    static func countdown(_ ms: Double) -> String {
        let t = Int((max(0, ms) + 999) / 1000)
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        return (h > 0 ? String(format: "%02d:", h) : "") + String(format: "%02d:%02d", m, s)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    static func dateLine(_ nowWall: Double) -> String {
        dateFmt.string(from: Date(timeIntervalSince1970: nowWall / 1000))
    }

    private static let weekFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("E")
        return f
    }()

    static func weekLine(_ nowWall: Double) -> String {
        weekFmt.string(from: Date(timeIntervalSince1970: nowWall / 1000))
    }
}
