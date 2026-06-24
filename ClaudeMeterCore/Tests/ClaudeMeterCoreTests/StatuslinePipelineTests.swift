import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite("StatuslinePipeline.displayWindow")
struct StatuslinePipelineDisplayWindowTests {
  private let now = Date(timeIntervalSince1970: 1_782_269_456)  // Wed 24 Jun 2026, ~10:50 AM

  @Test func futureResetKeepsReportedUsage() {
    let window = StatuslineBridge.RateLimitWindow(
      usedPercentage: 42,
      resetsAt: now.addingTimeInterval(3600)
    )
    let display = StatuslinePipeline.displayWindow(for: window, now: now)
    #expect(display.percentUsed == 42)
    #expect(display.resetsAt == now.addingTimeInterval(3600))
  }

  @Test func expiredWindowResetsToZeroAndDropsCountdown() {
    // Open-but-idle session re-emitting a stale snapshot: reset already passed.
    let window = StatuslineBridge.RateLimitWindow(
      usedPercentage: 25,
      resetsAt: now.addingTimeInterval(-6 * 3600)
    )
    let display = StatuslinePipeline.displayWindow(for: window, now: now)
    #expect(display.percentUsed == 0)
    #expect(display.resetsAt == nil)
  }

  @Test func missingWindowProducesEmptyWindow() {
    let display = StatuslinePipeline.displayWindow(for: nil, now: now)
    #expect(display.percentUsed == nil)
    #expect(display.resetsAt == nil)
  }

  @Test func windowWithoutResetTimeKeepsUsage() {
    // No reset time means we can't prove expiry; show the reported usage as-is.
    let window = StatuslineBridge.RateLimitWindow(usedPercentage: 30, resetsAt: nil)
    let display = StatuslinePipeline.displayWindow(for: window, now: now)
    #expect(display.percentUsed == 30)
    #expect(display.resetsAt == nil)
  }
}
