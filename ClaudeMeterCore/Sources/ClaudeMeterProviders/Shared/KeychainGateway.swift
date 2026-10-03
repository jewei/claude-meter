import ClaudeMeterCore
import Foundation

#if canImport(Security)
    import Darwin
    import LocalAuthentication
    import Security
#endif

/// The single boundary every live `SecItem*` call in the app passes through.
///
/// Two invariants it exists to hold:
///
/// 1. **No UI, ever.** Several of the items we read are owned by *other* apps
///    (Claude Code, Cursor), where a bare read can raise the legacy ACL
///    Allow/Deny dialog and block the calling thread until the user answers.
///    `applyNoUI` attaches a non-interactive policy so a forbidden item returns
///    `errSecInteractionNotAllowed` instead.
/// 2. **Fail closed under test.** A unit test must never read or mutate the
///    developer's real Keychain; test processes get `errSecInteractionNotAllowed`
///    unless `CLAUDE_METER_ALLOW_LIVE_KEYCHAIN_TESTS=1` is set explicitly.
enum KeychainGateway {

    #if canImport(Security)
        // Process-constant — cached so every SecItem call doesn't re-bridge the
        // whole environment dictionary (repo convention, like cached formatters).
        private static let allowsLiveAccess: Bool = {
            let environment = ProcessInfo.processInfo.environment
            if environment["CLAUDE_METER_ALLOW_LIVE_KEYCHAIN_TESTS"] == "1" { return true }
            // A loaded test framework is the one signal that survives every runner
            // shape. The heuristics below it are all launch-dependent and every one
            // of them misses `swift test`: swift-testing runs in a *shared* helper
            // (`swiftpm-testing-helper`) whose process name, `Bundle.main`, and
            // argv[0] all belong to the toolchain, not to a `.xctest` bundle — so
            // the gate silently opened and the suite read the real Keychain.
            if testFrameworkIsLoaded() { return false }
            if environment["XCTestConfigurationFilePath"] != nil { return false }
            if Bundle.main.bundleURL.pathExtension == "xctest" { return false }
            if CommandLine.arguments.first?.contains(".xctest/") == true { return false }
            return !ProcessInfo.processInfo.processName.lowercased().contains("xctest")
        }()

        /// Whether XCTest or swift-testing is loaded into this process.
        ///
        /// Checked against the dynamic loader rather than the environment because
        /// the image list reflects what is *actually* linked, independent of how
        /// the runner was invoked. Both frameworks ship as `…/XCTest.framework/…/XCTest`
        /// and `…/Testing.framework/…/Testing`, so an exact trailing component match
        /// is tight enough not to catch application code.
        // Also used by startup persistence to keep hosted app tests out of live defaults.
        static func testFrameworkIsLoaded() -> Bool {
            for index in 0..<_dyld_image_count() {
                guard let raw = _dyld_get_image_name(index) else { continue }
                let name = String(cString: raw)
                if name.hasSuffix("/XCTest") || name.hasSuffix("/Testing") { return true }
            }
            return false
        }

        static func copyMatching(query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>)
            -> OSStatus
        {
            guard allowsLiveAccess else { return errSecInteractionNotAllowed }
            return SecItemCopyMatching(query, result)
        }

        static func update(query: CFDictionary, attributes: CFDictionary) -> OSStatus {
            guard allowsLiveAccess else { return errSecInteractionNotAllowed }
            return SecItemUpdate(query, attributes)
        }

        static func add(query: CFDictionary) -> OSStatus {
            guard allowsLiveAccess else { return errSecInteractionNotAllowed }
            return SecItemAdd(query, nil)
        }

        static func delete(query: CFDictionary) -> OSStatus {
            guard allowsLiveAccess else { return errSecInteractionNotAllowed }
            return SecItemDelete(query)
        }

        /// Attaches a non-interactive policy so a Keychain read can never surface an
        /// Allow/Deny prompt. On macOS `interactionNotAllowed` alone can still show
        /// the legacy prompt; the UI-fail policy is what actually suppresses it.
        /// The (deprecated) constant is resolved at runtime to avoid a compile-time
        /// deprecation warning.
        static func applyNoUI(to query: inout [CFString: Any]) {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
            query[kSecUseAuthenticationUI] = noUIFailPolicy as CFString
        }

        private static let noUIFailPolicy: String = {
            let path = "/System/Library/Frameworks/Security.framework/Security"
            guard let handle = dlopen(path, RTLD_NOW) else { return "u_AuthUIF" }
            defer { dlclose(handle) }
            guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
                return "u_AuthUIF"
            }
            let ptr = symbol.assumingMemoryBound(to: CFString?.self)
            return (ptr.pointee as String?) ?? "u_AuthUIF"
        }()

        /// Reads a generic-password's secret under the no-UI policy.
        ///
        /// `account: nil` matches on service alone — the shape Cursor uses, where the
        /// item has no stable account attribute. Returns `nil` for a missing item,
        /// a locked Keychain, a denied ACL, or non-UTF8 data; callers that need to
        /// tell those apart should use `OAuthKeychain`'s typed
        /// `KeychainReadResult` path instead.
        static func readGenericPassword(service: String, account: String? = nil) -> String? {
            var query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ]
            if let account { query[kSecAttrAccount] = account }
            applyNoUI(to: &query)
            var result: AnyObject?
            guard copyMatching(query: query as CFDictionary, result: &result) == errSecSuccess,
                let data = result as? Data
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
    #else
        static func readGenericPassword(service: String, account: String? = nil) -> String? { nil }
    #endif
}
