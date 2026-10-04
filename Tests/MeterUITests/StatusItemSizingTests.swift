import AppKit
import Foundation
import MeterApp
import SwiftUI
import Testing

@testable import MeterUI

@MainActor @Suite struct StatusItemSizingTests {
    @Test func labelViewReportsItsWidthAsTheModelChanges() {
        let withNumber = AppModel.preview().menuBarModel(at: Date())
        let view = LabelHostingView(rootView: MenuBarLabel(model: withNumber))
        let wide = view.fittingSize
        #expect(wide.width > 40)
        #expect(wide.height > 10)
        view.rootView = MenuBarLabel(model: AppModel.preview(readings: []).menuBarModel(at: Date()))
        #expect(view.fittingSize.width < wide.width)
        #expect(view.fittingSize.width > 0)
    }

    @Test func labelViewLetsClicksThrough() {
        let view = LabelHostingView(
            rootView: MenuBarLabel(model: AppModel.preview().menuBarModel(at: Date())))
        view.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(!view.isAccessibilityElement())
    }
}
