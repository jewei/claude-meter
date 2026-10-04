import Foundation
import SwiftUI

/// A timeline that ticks on every whole second while running, and once when paused.
///
/// The popover runs it only while it is on screen, so countdowns tick for the user and a
/// hidden panel does no work.
struct SecondClock: TimelineSchedule {
    let isPaused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        if isPaused || mode == .lowFrequency {
            return AnyIterator(CollectionOfOne(startDate).makeIterator())
        }
        var next = startDate
        return AnyIterator {
            defer { next = (next.timeIntervalSinceReferenceDate + 1).rounded(.down).date }
            return next
        }
    }
}

extension Double {
    fileprivate var date: Date { Date(timeIntervalSinceReferenceDate: self) }
}
