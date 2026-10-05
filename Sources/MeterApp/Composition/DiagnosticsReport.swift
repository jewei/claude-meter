import Foundation
import MeterDomain

/// What the Diagnostics sheet shows and copies. Every value is already redacted.
public struct DiagnosticsReport: Equatable, Sendable {
    public struct Section: Equatable, Sendable, Identifiable {
        public let title: String
        public let facts: [DiagnosticFact]

        public var id: String { title }

        public init(title: String, facts: [DiagnosticFact]) {
            self.title = title
            self.facts = facts
        }
    }

    public let sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    /// Plain text for the clipboard: one heading per section, one `label: value` per fact.
    public var text: String {
        sections.map { section in
            ([section.title] + section.facts.map { "\($0.label): \($0.value)" })
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
