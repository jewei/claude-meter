import MeterApp
import MeterDomain
import SwiftUI

/// The status item content: the icon with its badge, then the compact number.
///
/// Colors are real colors, not a template, so the dot shows its severity. The whole label is
/// hidden from accessibility; the status button speaks ``MenuBarModel/accessibilityLabel``.
struct MenuBarLabel: View {
    let model: MenuBarModel
    /// The start of a running critical pulse. Nil keeps the dot still.
    var pulseStartedAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            icon
            if let text = model.text {
                Text(text)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .foregroundStyle(model.isDimmed ? .secondary : .primary)
        .opacity(model.isDimmed ? 0.55 : 1)
        .fixedSize()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var icon: some View {
        switch model.icon {
        case .loading:
            LoadingArrow(spins: !reduceMotion)
        case .error:
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
        case .bolt(let badge):
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold))
                .overlay(alignment: .topTrailing) {
                    BadgeView(badge: badge, pulseStartedAt: reduceMotion ? nil : pulseStartedAt)
                }
                // The "0" pill reaches past the bolt; keep it clear of the number.
                .padding(.trailing, badge == .exhausted ? 4 : 0)
        }
    }
}

/// The badge on the bolt: a severity dot, a gray stale dot, or a red "0" pill.
private struct BadgeView: View {
    let badge: MenuBarModel.Badge
    let pulseStartedAt: Date?

    var body: some View {
        switch badge {
        case .none:
            EmptyView()
        case .stale:
            Circle().fill(.secondary).frame(width: 6, height: 6).offset(x: 3, y: -3)
        case .exhausted:
            Text("0")
                .font(.system(size: 7, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .frame(minWidth: 10, minHeight: 10)
                .background(Capsule().fill(Palette.energyEmpty))
                .offset(x: 5, y: -4)
        case .dot(let severity):
            dot(severity)
        }
    }

    @ViewBuilder private func dot(_ severity: Severity) -> some View {
        let color: Color = severity == .unknown ? .secondary : severity.fill
        if let pulseStartedAt {
            // Redraws at most 12 times a second, and only while the pulse runs: the status
            // item renders again without a start when the pulse ends.
            TimelineView(.animation(minimumInterval: Motion.pulseFrameInterval)) { timeline in
                let phase = CriticalPulse.phase(
                    elapsed: timeline.date.timeIntervalSince(pulseStartedAt))
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .scaleEffect(CriticalPulse.scale(phase: phase))
                    .opacity(CriticalPulse.opacity(phase: phase))
                    .offset(x: 3, y: -3)
            }
        } else {
            Circle().fill(color).frame(width: 6, height: 6).offset(x: 3, y: -3)
        }
    }
}

/// The loading arrow. It turns once a second unless Reduce Motion is on.
private struct LoadingArrow: View {
    let spins: Bool

    var body: some View {
        if spins {
            TimelineView(.animation) { timeline in
                arrow.rotationEffect(.degrees(Self.angle(at: timeline.date)))
            }
        } else {
            arrow
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
    }

    static func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / Motion.spinPeriod
        return (turns - turns.rounded(.down)) * 360
    }
}
