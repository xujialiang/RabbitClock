import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var showTimeSource = false

    init() {
        // 截图钩子（App Store 素材自动化）：SIMCTL_CHILD_SHOT_PAGE=style/me/timesource
        let page = ProcessInfo.processInfo.environment["SHOT_PAGE"] ?? ""
        _tab = State(initialValue: page == "style" ? 1 : (page == "me" ? 2 : 0))
        _showTimeSource = State(initialValue: page == "timesource")
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView(onOpenTimeSource: { showTimeSource = true })
                .tabItem { Label(L("tab.timer"), systemImage: "timer") }.tag(0)
            StyleView()
                .tabItem { Label(L("tab.style"), systemImage: "paintbrush") }.tag(1)
            MeView(onOpenTimeSource: { showTimeSource = true })
                .tabItem { Label(L("tab.me"), systemImage: "person") }.tag(2)
        }
        .fullScreenCover(isPresented: $showTimeSource) { TimeSourceView(onBack: { showTimeSource = false }) }
    }
}

func keyWindowView() -> UIView? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }.first?
        .keyWindow?.rootViewController?.view
}

/// 时钟 tick 调度：毫秒模式逐帧（60fps）；秒级模式对齐到「显示时间的整秒边界 − 补偿」
struct ClockTick: TimelineSchedule {
    let fast: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        if fast {
            return AnySequence(Date.iterate(from: start, step: 1.0 / 60))
        }
        let displayNow = TimeSync.shared.now() + DisplayTiming.compMs(yFrac: 0.5)
        let remain = (1000 - displayNow.truncatingRemainder(dividingBy: 1000)) / 1000
        let first = Date().addingTimeInterval(max(0.03, remain))
        return AnySequence(Date.iterate(from: first, step: 1))
    }
}

extension Date {
    static func iterate(from start: Date, step: TimeInterval) -> UnfoldSequence<Date, Date> {
        sequence(state: start) { s in
            let cur = s
            s = s.addingTimeInterval(step)
            return cur
        }
    }
}

// ═══════════════ 首页 ═══════════════

struct HomeView: View {
    let onOpenTimeSource: () -> Void
    @EnvironmentObject var model: AppModel
    @ObservedObject var timeSync = TimeSync.shared
    @State private var showCustomCd = false
    @State private var cdText = ""

    private let cdPresets = [1, 3, 5, 10, 25, 60]

    var body: some View {
        VStack(spacing: 0) {
            ClockPanel(onOpenTimeSource: onOpenTimeSource, mode: model.mode)

            ModeCard(title: L("home.stopwatch"), color: .green, active: model.mode == .stopwatch) {
                Text(swText)
                    .font(.system(.title, design: .monospaced).bold())
                    .padding(.vertical, 4)
                HStack {
                    Button(model.stopwatch.running ? L("home.pause") : (model.stopwatch.elapsed() > 0 ? L("home.resume") : L("home.start"))) {
                        model.mode = .stopwatch
                        model.stopwatch.startOrPause()
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    Button(L("home.reset")) { model.stopwatch.reset() }
                        .buttonStyle(.bordered)
                }
            }

            ModeCard(title: L("home.countdown"), color: .orange, active: model.mode == .countdown) {
                // 自适应网格：窄屏自动换行
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], spacing: 6) {
                    ForEach(cdPresets, id: \.self) { m in
                        Chip(text: "\(m)′", selected: model.cdTotalMin == m && model.cdState == .idle) {
                            model.setCountdownMinutes(m)
                        }
                    }
                    Chip(
                        text: cdPresets.contains(model.cdTotalMin) ? L("home.custom") : LF("home.custom.v", String(model.cdTotalMin)),
                        selected: !cdPresets.contains(model.cdTotalMin) && model.cdState == .idle
                    ) { showCustomCd = true }
                }
                HStack {
                    TimelineText { _ in Fmt.countdown(model.countdown.remain()) }
                        .font(.system(.title2, design: .monospaced).bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(cdButtonLabel) {
                        model.mode = .countdown
                        model.toggleCountdown()
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                }.padding(.top, 8)
            }

            // 悬浮（PiP 画中画）开关
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("home.float")).font(.body.bold())
                        Text(model.floatVisible ? L("home.float.on") : L("home.float.off"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.floatVisible },
                        set: { on in
                            if let host = keyWindowView() { model.toggleFloat(host) }
                        }))
                        .labelsHidden()
                }
                if let hint = model.pipHint {
                    Text(hint).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
            .padding(.top, 6)

            Spacer(minLength: 90)
        }
        .padding(.horizontal, 16)
        .sheet(isPresented: $showCustomCd) { customCdSheet }
    }

    private var swText: String {
        let p = Fmt.stopwatch(model.stopwatch.elapsed(), millisDigits: max(1, model.style.millisDigits))
        return p.main + p.ms
    }

    private var cdButtonLabel: String {
        switch model.cdState {
        case .running: return L("home.pause")
        case .paused: return L("home.resume")
        case .finished: return L("home.cd.restart")
        case .idle: return L("home.cd.start")
        }
    }

    private var customCdSheet: some View {
        NavigationStack {
            Form {
                TextField(L("home.cd.field"), text: $cdText)
                    .keyboardType(.numberPad)
            }
            .navigationTitle(L("home.cd.sheet"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("home.cancel")) { showCustomCd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("home.set")) {
                        if let m = Int(cdText), (1...9999).contains(m) {
                            model.setCountdownMinutes(m)
                            showCustomCd = false
                        }
                    }
                }
            }
        }
        .presentationDetents([.height(180)])
    }
}

/// 大时钟面板：点击切回时钟模式；胶囊显示时间源状态
private struct ClockPanel: View {
    let onOpenTimeSource: () -> Void
    let mode: Mode
    @EnvironmentObject var model: AppModel
    @ObservedObject var timeSync = TimeSync.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("app.title")).font(.title3.bold())
                    Text(subLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            TimelineView(ClockTick(fast: model.style.showMillis && model.mode == .clock)) { _ in
                let displayNow = TimeSync.shared.now() + DisplayTiming.compMs(yFrac: 0.5)
                let p = Fmt.clock(h24: model.style.hour24, withSeconds: true, millisDigits: 0, nowWall: displayNow)
                Text(p.main + p.sec)
                    .font(.system(size: 54, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { model.mode = .clock } // 点击大钟切回时钟模式
            }
            Button(action: onOpenTimeSource) {
                Text(pillText)
                    .font(.caption2)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex8: "#22D3EE").opacity(0.14)))
                    .overlay(Capsule().stroke(Color(hex8: "#22D3EE").opacity(0.35)))
            }
            .foregroundStyle(Color(hex8: "#7EDCE8"))
            if mode != .clock {
                Text(LF("home.mode.hint", mode == .stopwatch ? L("home.stopwatch") : L("home.countdown")))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 18)
    }

    private var subLine: String {
        let displayNow = TimeSync.shared.now()
        var parts = [Fmt.dateLine(displayNow), Fmt.weekLine(displayNow)]
        if model.style.showBattery {
            let lv = UIDevice.current.batteryLevel
            if lv >= 0 { parts.append("🔋 \(Int(lv * 100))%") }
        }
        return parts.joined(separator: " ")
    }

    private var pillText: String {
        let src = Sources.byId(timeSync.selectedId)
        if src.kind == .device { return L("home.float.device") }
        if let r = timeSync.results[src.id], r.ok {
            return LF("home.float.ok", srcName(src), TimeSync.fmtOffset(r.offsetMs))
        }
        return LF("home.float.wait", srcName(src))
    }
}

/// 用 TimelineView 每帧重算的文本（秒表/倒计时读数）
struct TimelineText: View {
    let make: (Date) -> String
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { _ in
            Text(make(Date())).monospacedDigit()
        }
    }
}

struct ModeCard<Content: View>: View {
    let title: String
    let color: Color
    let active: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(active ? color.opacity(0.08) : .white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(active ? color.opacity(0.45) : .white.opacity(0.12)))
        .padding(.top, 8)
    }
}

struct Chip: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color(hex8: "#22D3EE") : .white.opacity(0.08)))
                .foregroundStyle(selected ? .black : .secondary)
        }
        .buttonStyle(.plain)
    }
}
