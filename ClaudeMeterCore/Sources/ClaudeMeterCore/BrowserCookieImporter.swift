import CommonCrypto
import CryptoKit
import Foundation

/// Imports the `sessionKey` cookie for `claude.ai` directly from a local browser,
/// so users don't have to copy it out of DevTools.
///
/// Supports Chromium browsers (Chrome and forks: v10 AES-128-CBC and v20 app-bound
/// AES-256-GCM — best-effort, see notes), Firefox (plaintext SQLite), and Safari
/// (binarycookies). All reads are read-only; nothing is ever written back.
///
/// Security: the returned value is a credential — never log it. Subprocess output
/// (sqlite3 / security) must be sanitized before diagnostics.
public enum BrowserCookieImporter {

    public struct ImportedCookie: Sendable, Equatable {
        public let sessionKey: String
        public let browser: String
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case notFound
        case unsupportedEncryption  // only Chrome v20 present and decryption failed
        case decryptionFailed

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return
                    "No claude.ai session found in your browsers. Sign in to claude.ai first, or paste the key manually."
            case .unsupportedEncryption:
                return
                    "Your browser's cookie is encrypted in a format Claude Meter can't read yet — paste the key manually."
            case .decryptionFailed:
                return "Found a claude.ai cookie but couldn't decrypt it — paste the key manually."
            }
        }
    }

    private static let sqlite3Path = "/usr/bin/sqlite3"
    private static let securityPath = "/usr/bin/security"
    private static let processTimeout: TimeInterval = 10

    // MARK: - Public entry point

    /// Tries each supported browser in turn and returns the first valid session key.
    /// Heavy (subprocess + file IO) — call off the main actor.
    public static func importClaudeSessionKey() -> Result<ImportedCookie, ImportError> {
        var sawUnsupported = false
        for browser in ChromiumBrowser.installed {
            switch importChromium(browser) {
            case .success(let key):
                return .success(ImportedCookie(sessionKey: key, browser: browser.displayName))
            case .failure(.unsupportedEncryption): sawUnsupported = true
            case .failure: break
            }
        }
        if let key = importFirefox() {
            return .success(ImportedCookie(sessionKey: key, browser: "Firefox"))
        }
        if let key = importSafari() {
            return .success(ImportedCookie(sessionKey: key, browser: "Safari"))
        }
        return .failure(sawUnsupported ? .unsupportedEncryption : .notFound)
    }

    // MARK: - Diagnostics (no secrets)

    /// Per-browser status with **no credential material** — safe to print/log.
    /// Used to iterate on decryption (esp. Chrome v20) without leaking the key.
    public static func diagnosticReport() -> String {
        var lines: [String] = []
        for browser in ChromiumBrowser.all {
            guard FileManager.default.fileExists(atPath: browser.supportRoot.path) else {
                lines.append("\(browser.displayName): not installed")
                continue
            }
            let pw = keychainPassword(
                service: browser.keychainService, account: browser.keychainAccount)
            var cookieFound = false
            var version = "—"
            var decrypted = false
            for db in chromiumProfiles(in: browser.supportRoot) {
                guard let hex = chromiumEncryptedSessionKeyHex(dbPath: db.path),
                    let enc = Data(hexString: hex), enc.count > 3
                else { continue }
                cookieFound = true
                version = String(decoding: enc.prefix(3), as: UTF8.self)
                if let pw, case .success = decryptChromium(enc, password: pw) { decrypted = true }
            }
            lines.append(
                "\(browser.displayName): keychainPW=\(pw != nil) cookie=\(cookieFound) version=\(version) decrypted=\(decrypted)"
            )
        }
        lines.append("Firefox: sessionKey=\(probeFirefoxSessionKey())")
        lines.append("Safari: sessionKey=\(probeSafariSessionKey())")
        return lines.joined(separator: "\n")
    }

    /// Probe-only: whether a plausible session key exists (no decryption).
    static func probeFirefoxSessionKey() -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
        guard
            let profiles = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else {
            return false
        }
        let sql = """
            SELECT 1 FROM moz_cookies
            WHERE name='sessionKey' AND (host = 'claude.ai' OR host LIKE '%.claude.ai')
            LIMIT 1;
            """
        for profile in profiles {
            let db = profile.appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: db.path) else { continue }
            if let row = runSQLite(dbPath: db.path, sql: sql)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                row == "1"
            {
                return true
            }
        }
        return false
    }

    /// Probe-only: whether a plausible session key exists (reads cookie file only).
    static func probeSafariSessionKey() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(
                "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
            home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
        ]
        for path in paths {
            guard let data = try? Data(contentsOf: path) else { continue }
            if parseBinaryCookies(data).contains(where: {
                isClaudeAiHost($0.domain) && $0.name == "sessionKey"
                    && isPlausibleSessionKey($0.value)
            }) {
                return true
            }
        }
        return false
    }

    // MARK: - Value validation

    /// A real claude.ai session key looks like `sk-ant-sid…`. We also accept the
    /// generic `sk-ant-` prefix to be forgiving of format tweaks.
    static func isPlausibleSessionKey(_ value: String) -> Bool {
        value.hasPrefix("sk-ant-")
    }

    /// Whether a cookie host/domain is exactly claude.ai or a subdomain thereof.
    static func isClaudeAiHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return h == "claude.ai" || h.hasSuffix(".claude.ai")
    }

    /// Chromium plaintext often carries a 32-byte domain-hash prefix and trailing
    /// padding bytes around the real value. Locate the `sk-ant-` token and return a
    /// clean, printable run from there.
    static func extractSessionKey(fromDecrypted data: Data) -> String? {
        guard
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii),
            let range = text.range(of: "sk-ant-")
        else {
            // Fall back: scan raw bytes for the ASCII marker, then read printable run.
            return extractFromRawBytes(data)
        }
        let tail = text[range.lowerBound...]
        let cleaned = String(tail.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return cleaned.count >= 12 ? cleaned : nil
    }

    private static func extractFromRawBytes(_ data: Data) -> String? {
        let marker = Array("sk-ant-".utf8)
        let bytes = [UInt8](data)
        guard let start = firstIndex(of: marker, in: bytes) else { return nil }
        var out: [UInt8] = []
        for b in bytes[start...] {
            let isToken =
                (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F
            if isToken { out.append(b) } else { break }
        }
        let value = String(decoding: out, as: UTF8.self)
        return value.count >= 12 ? value : nil
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count)
        where Array(haystack[i..<i + needle.count]) == needle {
            return i
        }
        return nil
    }

    // MARK: - Chromium

    struct ChromiumBrowser {
        let displayName: String
        let dataDir: String  // relative to ~/Library/Application Support
        let keychainService: String  // Keychain "<X> Safe Storage"
        let keychainAccount: String

        static let all: [ChromiumBrowser] = [
            .init(
                displayName: "Chrome", dataDir: "Google/Chrome",
                keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
            .init(
                displayName: "Brave", dataDir: "BraveSoftware/Brave-Browser",
                keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
            .init(
                displayName: "Microsoft Edge", dataDir: "Microsoft Edge",
                keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
            .init(
                displayName: "Arc", dataDir: "Arc/User Data", keychainService: "Arc Safe Storage",
                keychainAccount: "Arc"),
            .init(
                displayName: "Chromium", dataDir: "Chromium",
                keychainService: "Chromium Safe Storage", keychainAccount: "Chromium"),
        ]

        var supportRoot: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
                .appendingPathComponent(dataDir)
        }

        static var installed: [ChromiumBrowser] {
            all.filter { FileManager.default.fileExists(atPath: $0.supportRoot.path) }
        }
    }

    private static func importChromium(_ browser: ChromiumBrowser) -> Result<String, ImportError> {
        guard
            let password = keychainPassword(
                service: browser.keychainService, account: browser.keychainAccount)
        else {
            return .failure(.notFound)
        }
        // Look across the Default profile and any "Profile N".
        let profiles = chromiumProfiles(in: browser.supportRoot)
        var sawV20 = false
        for cookieDB in profiles {
            guard let hex = chromiumEncryptedSessionKeyHex(dbPath: cookieDB.path) else { continue }
            guard let encrypted = Data(hexString: hex), encrypted.count > 3 else { continue }
            switch decryptChromium(encrypted, password: password) {
            case .success(let value): return .success(value)
            case .failure(.unsupportedEncryption): sawV20 = true
            case .failure: break
            }
        }
        return .failure(sawV20 ? .unsupportedEncryption : .notFound)
    }

    private static func chromiumProfiles(in root: URL) -> [URL] {
        let fm = FileManager.default
        var dbs: [URL] = []
        let candidates =
            (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in candidates {
            let name = dir.lastPathComponent
            guard name == "Default" || name.hasPrefix("Profile ") else { continue }
            // Newer Chrome moves Cookies under Network/.
            for rel in ["Network/Cookies", "Cookies"] {
                let db = dir.appendingPathComponent(rel)
                if fm.fileExists(atPath: db.path) { dbs.append(db) }
            }
        }
        return dbs
    }

    private static func chromiumEncryptedSessionKeyHex(dbPath: String) -> String? {
        let sql = """
            SELECT hex(encrypted_value) FROM cookies
            WHERE name='sessionKey' AND (host_key = 'claude.ai' OR host_key LIKE '%.claude.ai')
            LIMIT 1;
            """
        let out = runSQLite(dbPath: dbPath, sql: sql)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    /// Reads a cookie DB, falling back to `immutable=1` when a plain read-only open
    /// fails — browsers keep the DB locked (WAL) while running, which blocks
    /// `-readonly` but not an immutable open.
    private static func runSQLite(dbPath: String, sql: String) -> String? {
        if let out = runProcess(sqlite3Path, ["-readonly", dbPath, sql]) { return out }
        let encodedPath = dbPath.replacingOccurrences(of: " ", with: "%20")
        return runProcess(sqlite3Path, ["file:\(encodedPath)?immutable=1", sql])
    }

    /// Dispatches on the version prefix. v10 = AES-128-CBC (PBKDF2 16-byte key,
    /// 1003 rounds, "saltysalt", IV of 16 spaces). v20 = app-bound AES-256-GCM —
    /// best-effort: tries a 32-byte PBKDF2 key over `nonce|ct|tag`. **Unverified on
    /// device; iterate from real output.**
    static func decryptChromium(_ data: Data, password: String) -> Result<String, ImportError> {
        let prefix = String(decoding: data.prefix(3), as: UTF8.self)
        if prefix == "v10" {
            let key = pbkdf2SHA1(password: password, salt: "saltysalt", rounds: 1003, keyLength: 16)
            let iv = Data(repeating: 0x20, count: 16)
            guard let plain = aesCBCDecrypt(key: key, iv: iv, data: data.dropFirst(3)),
                let value = extractSessionKey(fromDecrypted: plain), isPlausibleSessionKey(value)
            else { return .failure(.decryptionFailed) }
            return .success(value)
        }
        if prefix == "v20" {
            let key = pbkdf2SHA1(password: password, salt: "saltysalt", rounds: 1003, keyLength: 32)
            let body = data.dropFirst(3)
            guard body.count > 12 + 16 else { return .failure(.unsupportedEncryption) }
            let nonce = body.prefix(12)
            let cipherAndTag = body.dropFirst(12)
            let tag = cipherAndTag.suffix(16)
            let ciphertext = cipherAndTag.dropLast(16)
            guard
                let plain = aesGCMDecrypt(key: key, nonce: nonce, ciphertext: ciphertext, tag: tag),
                let value = extractSessionKey(fromDecrypted: plain), isPlausibleSessionKey(value)
            else { return .failure(.unsupportedEncryption) }
            return .success(value)
        }
        return .failure(.decryptionFailed)
    }

    // MARK: - Firefox (plaintext SQLite)

    private static func importFirefox() -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
        guard
            let profiles = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else {
            return nil
        }
        let sql = """
            SELECT value FROM moz_cookies
            WHERE name='sessionKey' AND (host = 'claude.ai' OR host LIKE '%.claude.ai')
            LIMIT 1;
            """
        for profile in profiles {
            let db = profile.appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: db.path) else { continue }
            if let value = runSQLite(dbPath: db.path, sql: sql)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                isPlausibleSessionKey(value)
            {
                return value
            }
        }
        return nil
    }

    // MARK: - Safari (binarycookies)

    private static func importSafari() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(
                "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
            home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
        ]
        for path in paths {
            guard let data = try? Data(contentsOf: path) else { continue }
            for cookie in parseBinaryCookies(data)
            where Self.isClaudeAiHost(cookie.domain) && cookie.name == "sessionKey" {
                if isPlausibleSessionKey(cookie.value) { return cookie.value }
            }
        }
        return nil
    }

    struct BinaryCookie: Equatable {
        let domain: String
        let name: String
        let value: String
    }

    /// Minimal Apple `Cookies.binarycookies` parser (magic `cook`, big-endian page
    /// table, little-endian page/cookie records).
    static func parseBinaryCookies(_ data: Data) -> [BinaryCookie] {
        let bytes = [UInt8](data)
        guard bytes.count > 8, Array(bytes[0..<4]) == Array("cook".utf8) else { return [] }
        let pageCount = Int(beUInt32(bytes, 4))
        var offset = 8
        var pageSizes: [Int] = []
        for _ in 0..<pageCount {
            guard offset + 4 <= bytes.count else { return [] }
            pageSizes.append(Int(beUInt32(bytes, offset)))
            offset += 4
        }
        var pageStart = offset
        var cookies: [BinaryCookie] = []
        for size in pageSizes {
            guard pageStart + size <= bytes.count else { break }
            cookies += parseCookiePage(Array(bytes[pageStart..<pageStart + size]))
            pageStart += size
        }
        return cookies
    }

    private static func parseCookiePage(_ page: [UInt8]) -> [BinaryCookie] {
        guard page.count > 8 else { return [] }
        let numCookies = Int(leUInt32(page, 4))
        var cookies: [BinaryCookie] = []
        var p = 8
        for _ in 0..<numCookies {
            guard p + 4 <= page.count else { break }
            let cookieOffset = Int(leUInt32(page, p))
            p += 4
            guard cookieOffset + 56 <= page.count else { continue }
            // Within a cookie record, string offsets are relative to the record start.
            let domainOff = Int(leUInt32(page, cookieOffset + 16))
            let nameOff = Int(leUInt32(page, cookieOffset + 20))
            let valueOff = Int(leUInt32(page, cookieOffset + 28))
            guard let domain = cString(page, cookieOffset + domainOff),
                let name = cString(page, cookieOffset + nameOff),
                let value = cString(page, cookieOffset + valueOff)
            else { continue }
            cookies.append(BinaryCookie(domain: domain, name: name, value: value))
        }
        return cookies
    }

    private static func cString(_ bytes: [UInt8], _ start: Int) -> String? {
        guard start >= 0, start < bytes.count else { return nil }
        var end = start
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func beUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }
    private static func leUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    // MARK: - Crypto primitives

    static func pbkdf2SHA1(password: String, salt: String, rounds: Int, keyLength: Int) -> Data {
        var derived = Data(count: keyLength)
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        _ = derived.withUnsafeMutableBytes { derivedPtr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, passwordBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                UInt32(rounds),
                derivedPtr.bindMemory(to: UInt8.self).baseAddress,
                keyLength
            )
        }
        return derived
    }

    static func aesCBCDecrypt(key: Data, iv: Data, data: Data) -> Data? {
        let dataBytes = [UInt8](data)
        guard !dataBytes.isEmpty, dataBytes.count % kCCBlockSizeAES128 == 0 else { return nil }
        var out = Data(count: dataBytes.count + kCCBlockSizeAES128)
        let outCount = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, key.count,
                        ivPtr.baseAddress,
                        dataBytes, dataBytes.count,
                        outPtr.baseAddress, outCount,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    static func aesGCMDecrypt(key: Data, nonce: Data, ciphertext: Data, tag: Data) -> Data? {
        guard let sealedNonce = try? AES.GCM.Nonce(data: nonce),
            let box = try? AES.GCM.SealedBox(nonce: sealedNonce, ciphertext: ciphertext, tag: tag)
        else {
            return nil
        }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    // MARK: - Subprocess helpers

    private static func keychainPassword(service: String, account: String) -> String? {
        runProcess(securityPath, ["find-generic-password", "-s", service, "-a", account, "-w"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runProcess(_ launchPath: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var status: Int32 = -1
            var output = Data()
        }
        let box = Box()
        DispatchQueue.global(qos: .utility).async {
            defer { semaphore.signal() }
            let outHandle = stdout.fileHandleForReading
            let drain = DispatchQueue(label: "BrowserCookieImporter.stdout")
            drain.async {
                box.output = outHandle.readDataToEndOfFile()
            }
            do { try process.run() } catch { return }
            process.waitUntilExit()
            drain.sync {}
            box.status = process.terminationStatus
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        if semaphore.wait(timeout: .now() + processTimeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard box.status == 0 else { return nil }
        return String(data: box.output, encoding: .utf8)
    }
}

// MARK: - Hex decoding

extension Data {
    /// Decodes a hex string (as emitted by sqlite `hex()`); returns `nil` on odd
    /// length or non-hex input.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else {
                return nil
            }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self.init(bytes)
    }
}
