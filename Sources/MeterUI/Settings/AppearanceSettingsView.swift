import MeterApp
import MeterDomain
import SwiftUI

/// Settings > Appearance: card style and order, the number shown, the menu-bar window, and
/// the severity thresholds.
struct AppearanceSettingsView: View {
    let model: AppModel

    var body: some View {
        @Bindable var store = model.settings
        let appearance = $store.settings.appearance
        SettingsPage(title: "Appearance", subtitle: "Make your meter feel like yours.") {
            SettingsCard(spacing: 12) {
                SettingsRow(
                    symbol: "chart.bar.xaxis", tint: Palette.Tile.violet, title: "Account cards",
                    subtitle: "How each account's usage is drawn.")
                HStack(spacing: 10) {
                    ForEach(AppearanceSettings.CardStyle.allCases, id: \.self) { style in
                        CardStyleOption(
                            style: style, isSelected: appearance.wrappedValue.cardStyle == style
                        ) {
                            appearance.wrappedValue.cardStyle = style
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Account card style")
                orderLine(CardOrderHint(store.settings))
            }
            SettingsCard(spacing: 12) {
                SettingsRow(
                    symbol: "arrow.left.arrow.right", tint: Palette.Tile.sky, title: "Show",
                    subtitle: "Energy remaining, or usage so far.")
                ChoiceRow(
                    label: "Usage display",
                    options: [(.energyLeft, "Energy left"), (.used, "Usage")],
                    selection: appearance.meterMode)
            }
            SettingsCard(spacing: 12) {
                SettingsRow(
                    symbol: "gauge.with.dots.needle.bottom.50percent", tint: Palette.Tile.green,
                    title: "Menu bar shows",
                    subtitle: "Choose which usage percentage appears in the menu bar.")
                ChoiceRow(
                    label: "Menu bar window",
                    options: [(.session, "5h"), (.weekly, "7d"), (.both, "Both")],
                    selection: appearance.menuBarWindow)
            }
            SettingsCard(spacing: 12) {
                SettingsRow(
                    symbol: "exclamationmark.circle", tint: Palette.energyLow,
                    title: "Severity thresholds",
                    subtitle: "Usage levels that change the menu bar and card colors.")
                ThresholdRow(
                    label: "Warning at", color: Palette.energyLow, ink: Palette.energyLowInk,
                    value: thresholdBinding(\.warning), range: Thresholds.warningRange,
                    step: Thresholds.step)
                CardDivider()
                ThresholdRow(
                    label: "Critical at", color: Palette.energyEmpty, ink: Palette.energyEmptyInk,
                    value: thresholdBinding(\.critical), range: Thresholds.criticalRange,
                    step: Thresholds.step)
            }
        }
    }

    private func orderLine(_ hint: CardOrderHint) -> some View {
        HStack(spacing: 10) {
            Text(hint.text)
                .font(MeterFont.body(11, .semibold))
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if hint.canReset {
                Button {
                    model.useAutomaticCardOrder()
                } label: {
                    Text("Use automatic order")
                        .font(MeterFont.display(12, .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .chunkyCard(radius: 10)
                }
                .buttonStyle(QuietButtonStyle(radius: 10))
                .help("Put the account nearest its limit first again")
            }
        }
    }

    /// Writes one threshold through ``Thresholds``, which clamps it and keeps critical above
    /// warning.
    private func thresholdBinding(_ keyPath: KeyPath<Thresholds, Double>) -> Binding<Double> {
        Binding {
            model.settings.settings.appearance.thresholds[keyPath: keyPath]
        } set: { value in
            model.settings.update { settings in
                let current = settings.appearance.thresholds
                settings.appearance.thresholds =
                    keyPath == \Thresholds.warning
                    ? Thresholds(warning: value, critical: current.critical)
                    : Thresholds(warning: current.warning, critical: value)
            }
        }
    }
}
