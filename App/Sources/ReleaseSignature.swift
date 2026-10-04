import Foundation
import Security

/// Tells whether this copy of the app has the release signature: a Developer ID Application
/// certificate of the release team.
///
/// Only such a copy may update itself. A development build that installed a release over
/// itself would replace the code under test. The requirement text lives in Info.plist
/// (`ClaudeMeterUpdateRequirement`), so `scripts/release.sh` checks every release against the
/// same text before it ships.
enum ReleaseSignature {
    static func isPresent() -> Bool {
        guard
            let requirement = Bundle.main.object(
                forInfoDictionaryKey: "ClaudeMeterUpdateRequirement") as? String
        else { return false }
        var code: SecCode?
        var compiled: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(requirement as CFString, [], &compiled)
                == errSecSuccess,
            let compiled
        else { return false }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }
}
