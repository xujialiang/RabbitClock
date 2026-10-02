import SwiftUI

@main
struct FloatClockApp: App {
    @StateObject private var model = AppModel.shared
    @StateObject private var timeSync = TimeSync.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        // 通知权限改为首次开始倒计时时情境化请求（不在启动时打断用户）
        TimeSync.shared.startPeriodicSync()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(timeSync)
                .preferredColorScheme(.dark)
                .tint(Color(hex8: "#22D3EE"))
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        TimeSync.shared.ensureFresh() // 回前台自动补（10 分钟闸门）
                    }
                }
        }
    }
}

extension Color {
    init(hex8: String) {
        var v: UInt64 = 0
        var s = hex8
        if s.hasPrefix("#") { s.removeFirst() }
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }
}
