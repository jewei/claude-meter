import CommonCrypto
import CryptoKit
import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("BrowserCookieImporter crypto + parsing")
struct BrowserCookieImporterTests {

    // MARK: - PBKDF2 (RFC 6070 vector)

    @Test func pbkdf2MatchesKnownVector() {
        let key = BrowserCookieImporter.pbkdf2SHA1(
            password: "password", salt: "salt", rounds: 1, keyLength: 20)
        #expect(
            key.map { String(format: "%02x", $0) }.joined()
                == "0c60c80f961f0e71f3a9b524af6012062fe037a6")
    }

    // MARK: - Hex

    @Test func hexDecodes() {
        #expect(Data(hexString: "76313061")! == Data("v10a".utf8))
        #expect(Data(hexString: "abc") == nil)  // odd length
        #expect(Data(hexString: "zz") == nil)  // non-hex
    }

    // MARK: - sk-ant extraction

    @Test func extractsKeyAfterBinaryPrefix() {
        var blob = Data((0..<32).map { _ in UInt8.random(in: 0...255) })  // domain-hash style prefix
        blob.append(Data("sk-ant-sid02-AbC_123-xyz".utf8))
        blob.append(Data([0x04, 0x04, 0x04, 0x04]))  // PKCS7-style padding
        #expect(
            BrowserCookieImporter.extractSessionKey(fromDecrypted: blob)
                == "sk-ant-sid02-AbC_123-xyz")
    }

    @Test func returnsNilWhenNoMarker() {
        #expect(
            BrowserCookieImporter.extractSessionKey(fromDecrypted: Data("nothing here".utf8)) == nil
        )
    }

    // MARK: - v10 (AES-128-CBC) round-trip through decryptChromium

    @Test func decryptsChromiumV10() throws {
        let password = "fake-safe-storage-pw"
        let key = BrowserCookieImporter.pbkdf2SHA1(
            password: password, salt: "saltysalt", rounds: 1003, keyLength: 16)
        let iv = Data(repeating: 0x20, count: 16)
        let plaintext = Data(repeating: 0, count: 32) + Data("sk-ant-sid02-test-value".utf8)
        let blob = Data("v10".utf8) + aesCBCEncrypt(key: key, iv: iv, data: plaintext)

        let result = BrowserCookieImporter.decryptChromium(blob, password: password)
        #expect(try result.get() == "sk-ant-sid02-test-value")
    }

    // MARK: - v20 (AES-256-GCM) round-trip (validates our key/layout assumption)

    @Test func decryptsChromiumV20WithAssumedKeyDerivation() throws {
        let password = "fake-safe-storage-pw"
        let key = BrowserCookieImporter.pbkdf2SHA1(
            password: password, salt: "saltysalt", rounds: 1003, keyLength: 32)
        let plaintext = Data(repeating: 0, count: 32) + Data("sk-ant-sid02-gcm-value".utf8)
        let nonce = try AES.GCM.Nonce(data: Data((0..<12).map { _ in UInt8.random(in: 0...255) }))
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
        let blob = Data("v20".utf8) + Data(nonce) + sealed.ciphertext + sealed.tag

        let result = BrowserCookieImporter.decryptChromium(blob, password: password)
        #expect(try result.get() == "sk-ant-sid02-gcm-value")
    }

    // MARK: - Safari binarycookies parser

    @Test func parsesBinaryCookies() {
        let cookie = makeBinaryCookies(
            domain: ".claude.ai", name: "sessionKey", value: "sk-ant-sid02-safari")
        let parsed = BrowserCookieImporter.parseBinaryCookies(cookie)
        #expect(
            parsed.contains(
                BrowserCookieImporter.BinaryCookie(
                    domain: ".claude.ai", name: "sessionKey", value: "sk-ant-sid02-safari")))
    }

    @Test func rejectsNonCookieFile() {
        #expect(BrowserCookieImporter.parseBinaryCookies(Data("nope".utf8)).isEmpty)
    }

    @Test func isClaudeAiHostMatchesExactAndSubdomains() {
        #expect(BrowserCookieImporter.isClaudeAiHost("claude.ai"))
        #expect(BrowserCookieImporter.isClaudeAiHost(".claude.ai"))
        #expect(BrowserCookieImporter.isClaudeAiHost("api.claude.ai"))
        #expect(!BrowserCookieImporter.isClaudeAiHost("evilclaude.ai"))
        #expect(!BrowserCookieImporter.isClaudeAiHost("notclaude.ai"))
    }

    // MARK: - Live, on-device diagnostic (opt-in)

    /// Runs against the real browsers on this machine. Skipped unless
    /// `CLAUDEMETER_LIVE_IMPORT=1` because it touches the Keychain (prompts) and
    /// the user's actual cookie stores. Prints a sanitized report — no secrets.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUDEMETER_LIVE_IMPORT"] == "1"))
    func liveDiagnostic() {
        print("=== BrowserCookieImporter diagnostic ===")
        print(BrowserCookieImporter.diagnosticReport())
        switch BrowserCookieImporter.importClaudeSessionKey() {
        case .success(let cookie):
            print(
                "IMPORT OK from \(cookie.browser): plausible=\(BrowserCookieImporter.isPlausibleSessionKey(cookie.sessionKey)) length=\(cookie.sessionKey.count)"
            )
        case .failure(let error):
            print("IMPORT FAILED: \(error)")
        }
        print("=== end ===")
    }

    // MARK: - Helpers

    private func aesCBCEncrypt(key: Data, iv: Data, data: Data) -> Data {
        let input = [UInt8](data)
        var out = Data(count: input.count + kCCBlockSizeAES128)
        let outCount = out.count
        var moved = 0
        _ = out.withUnsafeMutableBytes { outPtr in
            key.withUnsafeBytes { k in
                iv.withUnsafeBytes { ivp in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, key.count, ivp.baseAddress, input, input.count,
                        outPtr.baseAddress, outCount, &moved)
                }
            }
        }
        out.removeSubrange(moved..<out.count)
        return out
    }

    /// Builds a one-page, one-cookie binarycookies blob matching the parser's layout.
    private func makeBinaryCookies(domain: String, name: String, value: String) -> Data {
        func le(_ v: UInt32) -> [UInt8] {
            [
                UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff),
                UInt8((v >> 24) & 0xff),
            ]
        }
        func be(_ v: UInt32) -> [UInt8] {
            [
                UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff),
                UInt8(v & 0xff),
            ]
        }

        // Cookie record: 56-byte header (offsets at +16/+20/+28) + C strings.
        var record = [UInt8](repeating: 0, count: 56)
        let domainOff = 56
        let nameOff = domainOff + domain.utf8.count + 1
        let valueOff = nameOff + name.utf8.count + 1
        record.replaceSubrange(16..<20, with: le(UInt32(domainOff)))
        record.replaceSubrange(20..<24, with: le(UInt32(nameOff)))
        record.replaceSubrange(28..<32, with: le(UInt32(valueOff)))
        record += Array(domain.utf8) + [0]
        record += Array(name.utf8) + [0]
        record += Array(value.utf8) + [0]

        // Page: header(4) + numCookies(4) + offsets(4) + record.
        let cookieOffsetInPage = 12
        var page = [UInt8]()
        page += [0x00, 0x00, 0x01, 0x00]  // page header
        page += le(1)  // num cookies
        page += le(UInt32(cookieOffsetInPage))  // cookie offset
        page += record

        // File: magic + pageCount(BE) + pageSizes(BE) + pages.
        var file = [UInt8]()
        file += Array("cook".utf8)
        file += be(1)
        file += be(UInt32(page.count))
        file += page
        return Data(file)
    }
}
