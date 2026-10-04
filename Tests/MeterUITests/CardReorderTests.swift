import CoreGraphics
import Testing

@testable import MeterUI

@Suite struct CardReorderTests {
    private let order = ["a", "b", "c", "d"]
    /// Cards of unequal height, 10 pt apart.
    private let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 330, height: 100),
        "b": CGRect(x: 0, y: 110, width: 330, height: 60),
        "c": CGRect(x: 0, y: 180, width: 330, height: 140),
        "d": CGRect(x: 0, y: 330, width: 330, height: 60),
    ]

    private func target(_ card: String, y: CGFloat, x: CGFloat = 100) -> Int? {
        CardReorder.targetIndex(moving: card, to: CGPoint(x: x, y: y), in: order, frames: frames)
    }

    @Test func staysUntilTheNeighborMidpointIsCrossed() {
        // b's neighbor above is a, midpoint 50; below is c, midpoint 250.
        #expect(target("b", y: 140) == nil)
        #expect(target("b", y: 60) == nil)
        #expect(target("b", y: 240) == nil)
    }

    @Test func movesUpPastEachCrossedMidpoint() {
        #expect(target("b", y: 49) == 0)
        #expect(target("d", y: 240) == 2)
        #expect(target("d", y: 30) == 0)
    }

    @Test func movesDownPastEachCrossedMidpoint() {
        #expect(target("b", y: 251) == 2)
        #expect(target("a", y: 361) == 3)
        #expect(target("a", y: 151) == 1)
    }

    @Test func ignoresThePointerOutsideTheList() {
        #expect(target("b", y: 30, x: 400) == nil)
        #expect(target("b", y: 30, x: -1) == nil)
        #expect(target("b", y: -5) == nil)
        #expect(target("b", y: 395) == nil)
    }

    @Test func ignoresUnknownCardsAndMissingFrames() {
        #expect(target("z", y: 30) == nil)
        let partial = frames.filter { $0.key != "a" }
        #expect(
            CardReorder.targetIndex(
                moving: "c", to: CGPoint(x: 100, y: 120), in: order, frames: partial) == nil)
    }

    @Test func aMovedCardDoesNotSwingBack() {
        // c moves above b once the pointer passes b's midpoint (140)…
        #expect(target("c", y: 139) == 1)
        // …and after the list rearranges (c now 110…250, b 260…320), the same pointer leaves
        // it in place.
        let moved: [String: CGRect] = [
            "a": frames["a"] ?? .zero, "c": CGRect(x: 0, y: 110, width: 330, height: 140),
            "b": CGRect(x: 0, y: 260, width: 330, height: 60), "d": frames["d"] ?? .zero,
        ]
        #expect(
            CardReorder.targetIndex(
                moving: "c", to: CGPoint(x: 100, y: 139), in: ["a", "c", "b", "d"], frames: moved)
                == nil)
    }
}
