import Security

/// Tells whether this copy of the app has the release signature: a Developer ID Application
/// certificate of the release team.
///
/// Only such a copy may update itself. A development build that installed a release over
/// itself would replace the code under test.
enum ReleaseSignature {
    /// The designated requirement of a Developer ID application from team 4L4SS26L9J.
    private static let requirement = """
        anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] \
        and certificate leaf[subject.OU] = "4L4SS26L9J"
        """

    static func isPresent() -> Bool {
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
