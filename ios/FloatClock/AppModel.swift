import Foundation
import SwiftUI
import UserNotifications

/// 进程级状态：样式持久化 + 引擎实例 + 悬浮(PiP)开关。
/// UI 通过 @EnvironmentObject 观测；引擎读数由视图内 TimelineView 逐帧拉取。
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var style = Style() {
        didSet { persistStyle() }
    }
    @Published var mode: Mode = .clock
    @Published var floatVisible = false
    @Published var pipHint: String?
    @Published var cdTotalMin = 5
    @Published var cdState: RunState = .idle
    @Published var alarming = false

    let stopwatch = Stopwatch()
    let countdown = Countdown()

    private init() {
        if let data = UserDefaults.standard.data(forKey: "style_json"),
           let s = try? JSONDecoder().decode(Style.self, from: data) {
            style = s
        }
        cdTotalMin = UserDefaults.standard.integer(forKey: "cd_total_min").nonZero ?? 5
    }

    private func persistStyle() {
        if let data = try? JSONEncoder().encode(style) {
            UserDefaults.standard.set(data, forKey: "style_json")
        }
    }

    func setCountdownMinutes(_ min: Int) {
        cdTotalMin = min
        UserDefaults.standard.set(min, forKey: "cd_total_min")
        countdown.setTotal(Double(min) * 60_000)
        cdState = .idle
        Notifier.cancel()
    }

    func toggleCountdown() {
        switch countdown.state {
        case .idle:
            if countdown.totalMs <= 0 { countdown.setTotal(Double(cdTotalMin) * 60_000) }
            let endWall = countdown.start()
            cdState = .running
            Notifier.requestPermission()
            Notifier.schedule(endWall: endWall)
        case .running:
            countdown.pause(); cdState = .paused; Notifier.cancel()
        case .paused:
            let endWall = countdown.start()
            cdState = .running
            Notifier.requestPermission()
            Notifier.schedule(endWall: endWall)
        case .finished:
            setCountdownMinutes(cdTotalMin)
        }
    }

    /// PiP 悬浮开关（iOS 全局悬浮通道）
    func toggleFloat(_ host: UIView) {
        PipClockController.shared.toggleFromApp(host)
    }
}

/// 倒计时到点兜底：本地通知（进程被杀也触达）
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func schedule(endWall: Double) {
        let content = UNMutableNotificationContent()
        content.title = L("app.title")
        content.body = L("notif.cd.done")
        content.sound = .defaultCritical
        let interval = max(1, endWall / 1000 - Date().timeIntervalSince1970)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let req = UNNotificationRequest(identifier: "cd_end", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["cd_end"])
    }
}

extension Int {
    var nonZero: Int? { self != 0 ? self : nil }
}
