import SwiftUI

/// The questions and forms in Settings that cancel on Escape, in the order they appeared.
///
/// Only the newest one gets Escape, so one key never cancels two things: an inline question
/// that opens while the token form is open takes Escape from the form, and gives it back when
/// it closes. The newest one keeps Escape also while it does not want it (a token form with
/// pasted tokens), so Escape never reaches an older question by surprise.
@MainActor @Observable final class CancelShortcuts {
    private var claims: [UUID] = []

    /// `claim` appeared and wants to own Escape.
    func appear(_ claim: UUID) {
        guard !claims.contains(claim) else { return }
        claims.append(claim)
    }

    /// `claim` is gone.
    func disappear(_ claim: UUID) {
        claims.removeAll { $0 == claim }
    }

    /// Whether `claim` is the newest one.
    func owns(_ claim: UUID) -> Bool {
        claims.last == claim
    }
}

extension EnvironmentValues {
    /// The Escape owners of the Settings window. Without one, every cancel button keeps
    /// Escape.
    @Entry var cancelShortcuts: CancelShortcuts?
}

extension View {
    /// Gives this button `.cancelAction` while `isEnabled` and while it belongs to the newest
    /// question or form (``CancelShortcuts``).
    func cancelShortcut(isEnabled: Bool = true) -> some View {
        modifier(CancelShortcut(isEnabled: isEnabled))
    }
}

private struct CancelShortcut: ViewModifier {
    let isEnabled: Bool

    @Environment(\.cancelShortcuts) private var shortcuts
    @State private var claim = UUID()

    func body(content: Content) -> some View {
        content
            .keyboardShortcut(ownsEscape ? .cancelAction : nil)
            .onAppear { shortcuts?.appear(claim) }
            .onDisappear { shortcuts?.disappear(claim) }
    }

    private var ownsEscape: Bool {
        isEnabled && (shortcuts?.owns(claim) ?? true)
    }
}
