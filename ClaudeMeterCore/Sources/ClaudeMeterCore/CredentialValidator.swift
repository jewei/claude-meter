import Foundation

public enum CredentialValidator {
    private static let invalidSessionKeyCharacters = CharacterSet(charactersIn: ";\r\n")

    public static func isValidOrgId(_ orgId: String) -> Bool {
        UUID(uuidString: orgId.trimmingCharacters(in: .whitespaces)) != nil
    }

    public static func isValidSessionKey(_ sessionKey: String) -> Bool {
        let trimmed = sessionKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.rangeOfCharacter(from: invalidSessionKeyCharacters) == nil else { return false }
        return trimmed.hasPrefix("sk-ant-")
    }

    public static func normalizedOrgId(_ orgId: String) -> String? {
        let trimmed = orgId.trimmingCharacters(in: .whitespaces)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
