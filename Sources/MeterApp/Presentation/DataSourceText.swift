import Foundation
import MeterDomain

/// Copy for Settings > Data: source subtitles and sign-in states.
public enum DataSourceText {
    /// One sign-in line: the text, and whether it reports a usable login.
    public struct Status: Equatable, Sendable {
        public let text: String
        public let isSignedIn: Bool
        /// The check failed or found a login that cannot be used.
        public let isProblem: Bool
    }

    public static let cursorSubtitle =
        "Read Cursor billing-period usage (unofficial API; may break)."
    public static let codexSubtitle = "Read subscription usage from your Codex sign-in."
    public static let grokSubtitle =
        "Read Grok Build weekly credit usage (unofficial API; may break)."

    /// A question before an action that loses something the user entered.
    public struct Confirmation: Equatable, Sendable {
        public let title: String
        public let message: String
        /// The destructive button.
        public let confirmTitle: String
    }

    /// Next to the manual token fields: where pasted tokens may come from. Claude Meter
    /// refreshes them, which rotates the refresh token, so a copy of Claude Code's own login
    /// would sign Claude Code out at its next renewal (`docs/providers/claude-oauth.md`).
    public static let manualTokensSource =
        "Use tokens from a separate Claude login, not Claude Code's own login. Claude Meter "
        + "refreshes these tokens, so a copy of Claude Code's login would sign Claude Code out."

    /// Asks first when Disconnect would delete tokens that the user entered, because they are
    /// hard to get again. Nil when nothing the user entered would be lost.
    public static func disconnectConfirmation(
        connection: ClaudeSettings.Connection, manualStatus: SignInStatus?
    ) -> Confirmation? {
        guard connection == .manual || manualStatus == .signedIn else { return nil }
        return Confirmation(
            title: "Delete the saved tokens?",
            message:
                "Disconnect deletes the tokens that you entered from Claude Meter's Keychain "
                + "item. To connect again, paste them again.",
            confirmTitle: "Disconnect and Delete Tokens")
    }

    /// Asks first before a config dir or Codex home leaves the list with its settings.
    public static func removeConfirmation(name: String) -> Confirmation {
        Confirmation(
            title: "Remove \(name)?",
            message:
                "Claude Meter forgets its name, plan badge, and card settings. "
                + "The folder stays on disk.",
            confirmTitle: "Remove")
    }

    /// The chip on a login that the user stopped tracking, so the row says it in words and
    /// keeps its text at full contrast.
    public static func trackingChip(isEnabled: Bool) -> String? {
        isEnabled ? nil : "Not tracked"
    }

    /// The avatar letter for an account row: the first letter or digit of its name.
    public static func initial(_ name: String) -> String {
        Formatting.initial(name)
    }

    /// The Claude card subtitle for the saved connection.
    public static func claudeSubtitle(
        connection: ClaudeSettings.Connection, isEnabled: Bool
    ) -> String {
        switch (connection, isEnabled) {
        case (.off, true): "Not connected. Choose a connection below."
        case (.off, false): "Not connected. Turn on this source to set it up."
        case (.automatic, true): "Connected. Reads Claude Code's login from the Keychain."
        case (.manual, true): "Connected with tokens that you entered."
        case (_, false): "Connected. This source is off."
        }
    }

    /// Claude Code's own login, which automatic mode reads.
    public static func claudeCode(_ status: SignInStatus?) -> Status {
        switch status {
        case nil:
            Status(text: "Checking Claude Code's login…", isSignedIn: false, isProblem: false)
        case .signedIn:
            Status(text: "Claude Code is signed in.", isSignedIn: true, isProblem: false)
        case .signedOut:
            Status(
                text: "Claude Code is not signed in. Sign in to Claude Code first.",
                isSignedIn: false, isProblem: true)
        case .unknown(let reason):
            Status(
                text: "Could not check Claude Code's login. \(reason.text)", isSignedIn: false,
                isProblem: true)
        }
    }

    /// The tokens that the user entered, which manual mode uses.
    public static func manualTokens(_ status: SignInStatus?) -> Status {
        switch status {
        case nil:
            Status(text: "Checking saved tokens…", isSignedIn: false, isProblem: false)
        case .signedIn:
            Status(text: "Tokens are saved in your Keychain.", isSignedIn: true, isProblem: false)
        case .signedOut:
            Status(text: "No tokens are saved.", isSignedIn: false, isProblem: false)
        case .unknown(let reason):
            Status(
                text: "Could not check the saved tokens. \(reason.text)", isSignedIn: false,
                isProblem: true)
        }
    }

    /// One Codex home's login.
    public static func codexHome(_ status: SignInStatus?) -> Status {
        switch status {
        case nil:
            Status(text: "Checking sign-in…", isSignedIn: false, isProblem: false)
        case .signedIn:
            Status(text: "Signed in with ChatGPT", isSignedIn: true, isProblem: false)
        case .signedOut:
            Status(
                text: "API-key sign-in has no subscription quota. Sign in with ChatGPT in Codex.",
                isSignedIn: false, isProblem: true)
        case .unknown(let reason):
            Status(text: reason.text, isSignedIn: false, isProblem: true)
        }
    }
}
