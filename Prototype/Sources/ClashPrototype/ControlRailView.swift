import SwiftUI

/// 面板外侧的演示控制栏：重置与状态开关，明确标注不影响真实系统。
@MainActor
struct ControlRailView: View {
    @Bindable var model: PrototypeModel

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { model.trafficPaused },
            set: { model.setTrafficPaused($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Button {
                model.reset()
            } label: {
                Label("重置到「代理中」", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                model.resetPins()
            } label: {
                Label("重置 pin（只留主组）", systemImage: "pin.slash")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 10) {
                field("外观") {
                    Picker("外观", selection: $model.appearance) {
                        ForEach(DemoAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }

                field("壁纸") {
                    Picker("壁纸", selection: $model.wallpaper) {
                        ForEach(WallpaperTone.allCases) { tone in
                            Text(tone.title).tag(tone)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
            }

            HairlineView()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("显示错误 banner", isOn: $model.showsErrorBanner)
                Toggle("显示空态", isOn: $model.showsEmptyState)
                Toggle("模拟失败（1.5s 回滚）", isOn: $model.simulateFailure)
                Toggle("暂停曲线", isOn: pauseBinding)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textPrimary)

            Text("面板也可从状态栏图标打开")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(14)
        .frame(width: Metrics.railWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .fill(Theme.opaque)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Metrics.hairline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("原型控制")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Text("演示")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .frame(height: 14)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: Metrics.hairline)
                    }
            }

            Text("不影响真实系统，全部为本地假数据")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, alignment: .leading)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
