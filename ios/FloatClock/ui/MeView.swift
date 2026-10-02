import SwiftUI
import UIKit

struct MeView: View {
    let onOpenTimeSource: () -> Void
    @EnvironmentObject var model: AppModel
    @ObservedObject var timeSync = TimeSync.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("tab.me")).font(.title2.bold()).padding(.top, 12)

                card {
                    Text(L("me.settings")).font(.subheadline.weight(.medium))
                    HStack {
                        Text(L("ts.title")).font(.subheadline)
                        Spacer()
                        Button {
                            onOpenTimeSource()
                        } label: {
                            Text("\(Sources.byId(timeSync.selectedId).name) ›")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                    Toggle(L("me.h24"), isOn: $model.style.hour24).padding(.top, 4)
                    Toggle(L("style.snap"), isOn: $model.style.snap).padding(.top, 4)
                }

                card {
                    Text(L("me.about")).font(.subheadline.weight(.medium)).padding(.bottom, 4)
                    Text(LF("me.body", "\(L("app.title")) v1.1.8"))
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 16)
        }
        .background(Color(hex8: "#0A0F1C"))
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
        .padding(.top, 12)
    }
}
