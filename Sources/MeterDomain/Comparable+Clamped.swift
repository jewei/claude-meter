extension Comparable {
    /// The value, or the nearest bound of `range` when the value is outside it.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
