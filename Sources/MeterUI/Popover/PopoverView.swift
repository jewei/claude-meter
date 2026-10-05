import MeterApp
import SwiftUI

/// The popover: a fixed header over a body that scrolls when it is taller than the cap.
///
/// The view builds ``PopoverModel`` for the current second. While the panel is on screen a
/// clock renders it every second, so countdowns and "2m ago" tick; while it is hidden the
/// clock stops. It reports the header and content heights so the panel can size itself.
struct PopoverView: View {
    static let cornerRadius: CGFloat = 22

    let model: AppModel
    let presentation: PopoverPresentation
    var actions = PopoverActions()

    @Environment(\.rendersStatically) private var rendersStatically

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        TimelineView(SecondClock(isPaused: !presentation.isVisible)) { timeline in
            // A paused clock keeps the date of its last tick. A store change while hidden
            // renders for the current time, so staleness and the measured height are right
            // when the panel opens.
            let now = presentation.isVisible ? timeline.date : Date()
            let popover = model.popoverModel(at: now)
            VStack(spacing: 0) {
                PopoverHeader(popover: popover, model: model, actions: actions)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        actions.headerHeightChanged(height)
                    }
                scrollingBody(popover)
            }
        }
        .frame(width: PanelLayout.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.popover)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.popoverBorder, lineWidth: 2))
        .environment(\.popoverIsVisible, presentation.isVisible)
    }

    @ViewBuilder private func scrollingBody(_ popover: PopoverModel) -> some View {
        let content = PopoverBody(popover: popover, model: model, actions: actions)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                actions.contentHeightChanged(height)
            }
        if rendersStatically {
            content
        } else {
            ScrollView(.vertical) { content }
                .scrollDisabled(!presentation.scrolls)
                .scrollIndicators(presentation.scrolls ? .automatic : .never)
        }
    }
}
