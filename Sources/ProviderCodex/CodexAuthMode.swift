import Foundation

/// How a Codex login authenticates.
///
/// One rule reads both `auth.json` (`auth_mode`) and the app-server account (`type`):
/// the text is trimmed and compared without case.
enum CodexAuthMode: Sendable, Equatable {
    /// A ChatGPT sign-in. Only this mode has subscription quota.
    case chatGPT
    /// An OpenAI API key. It has no subscription quota.
    case apiKey
    /// Absent or not recognized.
    case unknown

    init(_ text: String?) {
        switch text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chatgpt", "chat_gpt", "chatgptauthtokens":
            self = .chatGPT
        case "api", "apikey", "api_key", "openai_api_key":
            self = .apiKey
        default:
            self = .unknown
        }
    }
}
