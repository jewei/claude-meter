import Foundation

/// The Codex settings that the app owns and hands to ``CodexProvider`` at each refresh.
public struct CodexConfiguration: Sendable, Equatable {
    /// Codex homes that the user added. They follow the implicit home, in this order.
    public var extraHomes: [URL]

    public init(extraHomes: [URL] = []) {
        self.extraHomes = extraHomes
    }
}
