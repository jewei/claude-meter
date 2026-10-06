import Darwin
import Foundation

/// Reads a generic password through `/usr/bin/security`, for items that another app wrote with
/// that tool.
///
/// Claude Code writes its login with `security`, so the item's access list trusts only that
/// tool. A read from this app asks for the login password, and "Always Allow" lasts only until
/// Claude Code writes the item again. A read through the same tool shows no dialog. The tool
/// can still ask to unlock a locked Keychain, so the caller checks the lock first
/// (``SystemKeychain/passwordThroughSecurityTool(service:account:)``).
enum SecurityTool {
    static let path = "/usr/bin/security"
    /// The longest wait for the tool. The caller's own deadline is usually shorter; then the
    /// abandoned read still ends here and stops the child.
    static let limit: TimeInterval = 5
    /// More output than any credential: the rest is dropped and the read fails.
    static let outputLimit = 64 * 1024

    static func password(service: String, account: String) throws(KeychainError) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let received = Locked(Data())
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            received.withLock { data in
                if data.count <= outputLimit { data.append(chunk) }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw .failure(status: errSecIO)
        }
        guard exited.wait(timeout: .now() + limit) == .success else {
            process.terminate()
            output.fileHandleForReading.readabilityHandler = nil
            throw .unavailable
        }
        output.fileHandleForReading.readabilityHandler = nil
        // Bytes that arrived after the last handler call.
        let rest = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        let data = received.withLock { data in
            data.append(rest)
            return data
        }
        if let error = error(exitStatus: process.terminationStatus) {
            if error == .notFound { return nil }
            throw error.keychainError
        }
        guard data.count <= outputLimit else { throw .failure(status: errSecDataTooLarge) }
        return secret(fromOutput: data)
    }

    enum ExitError: Equatable {
        case notFound
        case failure(KeychainError)

        var keychainError: KeychainError {
            switch self {
            case .notFound: .failure(status: errSecItemNotFound)
            case .failure(let error): error
            }
        }
    }

    /// The tool exits with the low byte of the `OSStatus`: 44 for `errSecItemNotFound`
    /// (-25300), 36 for `errSecInteractionNotAllowed` (-25308), 51 for `errSecAuthFailed`
    /// (-25293), and 128 for `errSecUserCanceled` (-128).
    static func error(exitStatus: Int32) -> ExitError? {
        switch exitStatus {
        case 0: nil
        case 44: .notFound
        case 36, 128: .failure(.unavailable)
        case 51: .failure(.denied)
        default: .failure(.failure(status: exitStatus))
        }
    }

    /// `-w` prints the secret and a newline. A secret that is not printable text comes out
    /// as hex digits. Claude Code's JSON starts with `{`, which is never a hex digit.
    static func secret(fromOutput output: Data) -> Data {
        var text = output
        if text.last == UInt8(ascii: "\n") { text.removeLast() }
        guard text.first != UInt8(ascii: "{"), !text.isEmpty, text.count.isMultiple(of: 2),
            let decoded = hexDecoded(text)
        else { return text }
        return decoded
    }

    private static func hexDecoded(_ digits: Data) -> Data? {
        var result = Data(capacity: digits.count / 2)
        var high: UInt8?
        for byte in digits {
            guard let value = hexValue(byte) else { return nil }
            if let first = high {
                result.append(first << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return result
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
