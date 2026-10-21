import MeterApp
import MeterDomain
import SwiftUI

/// The status item content: the icon with its badge, then the compact number.
///
/// The status item draws it in two layers (``MenuBarImage``): the ink (icon, number, and stale
/// dot) as a template, and the red "0" pill in its real colors. Each layer keeps the layout of the whole label,
/// so the layers line up. The whole label is hidden from accessibility; the status button
/// speaks ``MenuBarModel/accessibilityLabel``.
struct MenuBarLabel: View {
    /// The parts of the label that one drawing shows.
    enum Layer {
        case all
        /// Everything but the red "0" pill.
        case ink
        /// The red "0" pill only.
        case badge
    }

    let model: MenuBarModel
    var layer = Layer.all

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            icon
            if let text = model.text {
                Text(text)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .opacity(inkOpacity)
            }
        }
        // Dimmed is the system's secondary label color, which stays readable on every menu
        // bar; a second fade on top made a paused item almost invisible.
        .foregroundStyle(model.isDimmed ? .secondary : .primary)
        .fixedSize()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var icon: some View {
        switch model.icon {
        case .loading:
            LoadingArrow(spins: !reduceMotion).opacity(inkOpacity)
        case .error:
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .opacity(inkOpacity)
        case .bolt(let badge):
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold))
                .opacity(inkOpacity)
                .overlay(alignment: .topTrailing) {
                    BadgeView(badge: badge).opacity(badgeOpacity(badge))
                }
                // The "0" pill reaches past the bolt; keep it clear of the number.
                .padding(.trailing, badge == .exhausted ? 4 : 0)
        }
    }

    private var inkOpacity: Double { layer == .badge ? 0 : 1 }

    /// The red "0" pill is the badge layer. The gray stale dot is ink, so it dims with the
    /// bolt.
    private func badgeOpacity(_ badge: MenuBarModel.Badge) -> Double {
        switch layer {
        case .all: 1
        case .ink: badge == .exhausted ? 0 : 1
        case .badge: badge == .exhausted ? 1 : 0
        }
    }
}

/// The badge on the bolt: a gray stale dot, or a red "0" pill.
private struct BadgeView: View {
    let badge: MenuBarModel.Badge

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
        }
    }
}

/// The loading arrow. It turns once a second, redrawn at most 30 times a second, unless
/// Reduce Motion is on.
private struct LoadingArrow: View {
    let spins: Bool

    var body: some View {
        if spins {
            TimelineView(.animation(minimumInterval: Motion.spinFrameInterval)) { timeline in
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
