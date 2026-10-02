import SwiftUI
import UIKit

struct TimeSourceView: View {
    let onBack: () -> Void
    @ObservedObject var timeSync = TimeSync.shared
    @EnvironmentObject var model: AppModel
    @State private var showHelp = false

    private let hz = DisplayTiming.refreshRateHz()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 顶栏
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.title2)
                            .foregroundStyle(Color(hex8: "#22D3EE"))
                    }
                    Text(L("ts.title")).font(.title3.bold()).frame(maxWidth: .infinity)
                    Button(action: { showHelp = true }) {
                        Image(systemName: "questionmark")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 12)

                statusCard

                Text(L("ts.manual")).font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 18).padding(.bottom, 6)
                manualCard

                Text(L("ts.depthsec")).font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 18).padding(.bottom, 6)
                depthCard

                Text(L("ts.title")).font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 18).padding(.bottom, 6)
                ForEach(Sources.all) { src in
                    sourceRow(src)
                }

                Text(L("ts.footer"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 10).padding(.bottom, 40)
            }
            .padding(.horizontal, 16)
        }
        .background(Color(hex8: "#0A0F1C"))
        .onAppear { TimeSync.shared.ensureFresh() }
        .sheet(isPresented: $showHelp) { helpSheet }
    }

    // MARK: 状态卡

    private var statusCard: some View {
        let src = Sources.byId(timeSync.selectedId)
        let isSyncing = timeSync.syncing.contains(src.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusDot)
                    .frame(width: 8, height: 8)
                Text(statusTitle).font(.subheadline.weight(.medium))
            }
            Text(statusDetail).font(.caption).foregroundStyle(.secondary)
            if src.kind != .device {
                Button(isSyncing ? L("ts.syncingbtn") : L("ts.syncnow")) {
                    timeSync.requestSync(src.id)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex8: "#22D3EE"))
                .disabled(isSyncing)
            }
            Text(LF("ts.hz", Int(hz.rounded()), String(format: "%.1f", DisplayTiming.compMs(yFrac: 0.5))))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
        .padding(.top, 10)
    }

    private var statusDot: Color {
        let src = Sources.byId(timeSync.selectedId)
        let res = timeSync.results[src.id]
        if src.kind == .device { return .gray }
        if timeSync.syncing.contains(src.id) { return Color(hex8: "#22D3EE") }
        if res?.ok == true { return .green }
        return .orange
    }

    private var statusTitle: String {
        let src = Sources.byId(timeSync.selectedId)
        let res = timeSync.results[src.id]
        if src.kind == .device { return L("ts.device") }
        if timeSync.syncing.contains(src.id) { return LF("ts.syncing", srcName(src)) }
        if let r = res, r.ok { return LF("ts.synced", srcName(src), TimeSync.fmtAgo(r.atWall)) }
        return LF("ts.unsynced", srcName(src))
    }

    private var statusDetail: String {
        let src = Sources.byId(timeSync.selectedId)
        guard let r = timeSync.results[src.id], r.ok else {
            return LF("ts.tapsync", srcName(src))
        }
        var s = LF("ts.offset", TimeSync.fmtOffset(r.offsetMs))
        if timeSync.manualOffsetMs != 0 { s += " · " + LF("ts.fine", TimeSync.fmtManual(timeSync.manualOffsetMs)) }
        var tail: String
        switch src.kind {
        case .date: tail = LF("ts.win", String(Int(r.rttMs)))
        case .sntp: tail = LF("ts.rtt", String(Int(r.rttMs))) + " · " + (r.ntp ? L("ts.ntp") : L("ts.http"))
        default: tail = LF("ts.rtt", String(Int(r.rttMs)))
        }
        return s + "\n" + LF("ts.formula", tail)
    }

    // MARK: 手动微调

    private var manualCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("ts.finetune")).font(.subheadline)
                Text(L("ts.finehint")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            nudgeBtn("−") { timeSync.nudgeManual(-TimeSync.manualStepMs) }
            Text(TimeSync.fmtManual(timeSync.manualOffsetMs))
                .font(.system(.footnote, design: .monospaced))
                .frame(width: 86)
                .foregroundStyle(timeSync.manualOffsetMs == 0
                    ? Color.secondary : Color(hex8: "#22D3EE"))
            nudgeBtn("+") { timeSync.nudgeManual(TimeSync.manualStepMs) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
    }

    private func nudgeBtn(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.title3).frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
    }

    // MARK: 呈现深度

    private var depthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("ts.depth")).font(.subheadline)
            Text(L("ts.depthhint"))
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([1.0, 1.5, 2.0], id: \.self) { d in
                    Chip(text: LF("ts.frame", d == 1.0 ? "1" : (d == 1.5 ? "1.5" : "2")),
                         selected: DisplayTiming.presentDepth == d) {
                        DisplayTiming.presentDepth = d
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
    }

    // MARK: 源列表

    private func sourceRow(_ src: TimeSource) -> some View {
        let r = timeSync.results[src.id]
        let active = timeSync.selectedId == src.id
        return Button {
            timeSync.select(src.id)
        } label: {
            HStack {
                ZStack {
                    Circle().stroke(active ? Color(hex8: "#22D3EE") : .white.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if active {
                        Circle().fill(Color(hex8: "#22D3EE")).frame(width: 9, height: 9)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(srcName(src)).font(.subheadline)
                        if src.id == Sources.beijing {
                            Text(L("ts.default")).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex8: "#22D3EE").opacity(0.85)))
                                .foregroundStyle(.black)
                        }
                    }
                    Text(srcSubline(src)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(rowStatus(src, r))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(rowOk(src, r) ? Color(hex8: "#7EF0C5") : Color.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(active ? Color(hex8: "#22D3EE").opacity(0.1) : .white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(active ? Color(hex8: "#22D3EE").opacity(0.45) : .white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private func rowStatus(_ src: TimeSource, _ r: SyncResult?) -> String {
        if src.kind == .device { return L("ts.follow") }
        if timeSync.syncing.contains(src.id) { return L("ts.row.syncing") }
        if let r, r.ok { return TimeSync.fmtOffset(r.offsetMs) }
        return r != nil ? L("ts.retry") : L("ts.notsynced")
    }

    private func rowOk(_ src: TimeSource, _ r: SyncResult?) -> Bool {
        src.kind == .device || r?.ok == true
    }

    // MARK: 帮助

    private var helpSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("ts.help.title")).font(.headline)
            Text(L("ts.help.body"))

            .font(.subheadline)
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
    }
}
