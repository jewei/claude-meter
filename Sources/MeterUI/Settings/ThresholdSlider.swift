import MeterApp
import SwiftUI

/// A thick colored slider with a ringed thumb. It snaps to `step`, moves one step per arrow
/// key, shows a focus border, and is adjustable with VoiceOver.
///
/// The native `Slider` cannot draw the ringed thumb, so this one is drawn by hand.
struct ThresholdSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let color: Color
    let label: String

    @FocusState private var isFocused: Bool

    private let thumb: CGFloat = 26
    private let track: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let span = max(1, geometry.size.width - thumb)
            let x = CGFloat(Self.fraction(for: value, in: range)) * span
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track).frame(height: track)
                Capsule().fill(color).frame(width: x + thumb / 2, height: track)
                Circle()
                    .fill(Palette.card)
                    .overlay(Circle().strokeBorder(color, lineWidth: 4))
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .offset(x: x)
            }
            .frame(height: thumb)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let share = Double(min(1, max(0, (drag.location.x - thumb / 2) / span)))
                    let raw = range.lowerBound + share * (range.upperBound - range.lowerBound)
                    value = Self.snapped(raw, in: range, step: step)
                })
        }
        .frame(height: thumb)
        .padding(.vertical, 2)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isFocused ? Palette.accent : .clear, lineWidth: 2)
                .padding(-3)
        }
        .focusable()
        .focused($isFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: value = Self.stepped(value, up: false, in: range, step: step)
            case .right, .up: value = Self.stepped(value, up: true, in: range, step: step)
            @unknown default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(ThresholdText.spoken(value, in: range))
        .accessibilityAdjustableAction { direction in
            value = Self.stepped(value, up: direction == .increment, in: range, step: step)
        }
    }

    // MARK: - Pure math

    /// The value clamped to the range. A non-finite value becomes the lower bound.
    static func bounded(_ value: Double, in range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : range.lowerBound
    }

    /// The thumb position, 0...1.
    static func fraction(for value: Double, in range: ClosedRange<Double>) -> Double {
        let width = range.upperBound - range.lowerBound
        guard width.isFinite, width > 0 else { return 0 }
        return (bounded(value, in: range) - range.lowerBound) / width
    }

    /// The nearest step from the lower bound, inside the range.
    static func snapped(_ value: Double, in range: ClosedRange<Double>, step: Double) -> Double {
        let value = bounded(value, in: range)
        guard step.isFinite, step > 0 else { return value }
        let snapped = range.lowerBound + ((value - range.lowerBound) / step).rounded() * step
        return bounded(snapped, in: range)
    }

    /// One step up or down, inside the range.
    static func stepped(
        _ value: Double, up: Bool, in range: ClosedRange<Double>, step: Double
    ) -> Double {
        let value = bounded(value, in: range)
        guard step.isFinite, step > 0 else { return value }
        return bounded(value + (up ? step : -step), in: range)
    }
}
