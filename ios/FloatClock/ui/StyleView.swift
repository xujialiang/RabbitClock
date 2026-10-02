import SwiftUI

struct StyleView: View {
    @EnvironmentObject var model: AppModel
    private let colors = ["#22D3EE", "#F4F7FF", "#FFB454", "#FF6B6B", "#34D399", "#A78BFA"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("tab.style")).font(.title2.bold()).padding(.bottom, 12)

                // 实时预览
                TimelineView(.animation(minimumInterval: 0.25)) { _ in
                    preview
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex8: "#111A30")))
                .padding(.bottom, 6)

                section(L("style.color")) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            ForEach(colors, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex8: hex))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(
                                        model.style.colorHex == hex ? Color.white : .white.opacity(0.2),
                                        lineWidth: model.style.colorHex == hex ? 2 : 1))
                                    .onTapGesture { model.style.colorHex = hex }
                            }
                        }
                        // 调色盘：任意自定义颜色（颜色=悬浮播放器整体背景色）
                        ColorPicker(L("style.colorpick"), selection: hexBinding, supportsOpacity: false)
                            .font(.subheadline)
                    }
                }

                section(LF("style.size", String(format: "%.2f", model.style.scale))) {
                    Slider(value: $model.style.scale, in: 0.7...3.8)
                    Text(L("style.sizehint"))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                section(LF("style.opacity", Int(model.style.opacity * 100))) {
                    Slider(value: $model.style.opacity, in: 0.3...1.0)
                }

                section(L("style.elements")) {
                    wrapChips([
                        (L("style.sec"), model.style.showSeconds, { model.style.showSeconds.toggle() }),
                        (L("style.ms"), model.style.showMillis, { model.style.showMillis.toggle() }),
                        (L("style.date"), model.style.showDate, { model.style.showDate.toggle() }),
                        (L("style.week"), model.style.showWeek, { model.style.showWeek.toggle() }),
                        (L("style.batt"), model.style.showBattery, { model.style.showBattery.toggle() }),
                    ])
                }

                section(L("style.msd")) {
                    HStack(spacing: 8) {
                        ForEach(1...3, id: \.self) { d in
                            Chip(text: LF("style.digits", d), selected: model.style.millisDigits == d) {
                                model.style.millisDigits = d
                            }
                        }
                    }
                }

                section(L("style.snap")) {
                    Chip(text: L("style.snap"), selected: model.style.snap) { model.style.snap.toggle() }
                }
            }
            .padding(.horizontal, 16)
        }
        .background(Color(hex8: "#0A0F1C"))
    }

    private var hexBinding: Binding<Color> {
        Binding(
            get: { Color(hex8: model.style.colorHex) },
            set: { model.style.colorHex = $0.toHex() ?? model.style.colorHex }
        )
    }

    /// 颜色即播放器背景：文字按背景亮度自适应黑/白
    private func adaptiveText(_ hex: String, opacity: Double) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex8: hex)).getRed(&r, green: &g, blue: &b, alpha: &a)
        let lum = opacity * (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b))
        return lum > 0.55 ? Color(hex8: "#0A0F1C") : .white
    }

    private var preview: some View {
        let s = model.style
        let displayNow = TimeSync.shared.now() + DisplayTiming.compMs(yFrac: 0.5)
        let p = Fmt.clock(h24: s.hour24, withSeconds: s.showSeconds,
                          millisDigits: s.showMillis ? s.millisDigits : 0, nowWall: displayNow)
        let text = p.main + p.sec + p.ms
        return Text(text)
            .font(.system(size: 24 * s.scale, weight: .bold, design: .monospaced))
            .foregroundColor(adaptiveText(s.colorHex, opacity: s.opacity))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex8: s.colorHex).opacity(s.opacity)))
    }

    @ViewBuilder
    private func wrapChips(_ items: [(String, Bool, () -> Void)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                Chip(text: items[i].0, selected: items[i].1, action: items[i].2)
            }
        }
    }
}

struct section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
        .padding(.top, 18)
    }
}

extension Color {
    /// SwiftUI Color → #RRGGBB（调色盘选择落到持久化的 hex 字符串）
    func toHex() -> String? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        guard a > 0.01 else { return nil }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
