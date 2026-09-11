import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("MeterLog")
struct MeterLogTests {
    /// Collects what the seam emitted, in order.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(MeterLog.Level, MeterLog.Category, String)] = []

        var emit: @Sendable (MeterLog.Level, MeterLog.Category, String) -> Void {
            { level, category, message in
                self.lock.withLock { self.lines.append((level, category, message)) }
            }
        }

        var messages: [String] { lock.withLock { lines.map(\.2) } }
        var levels: [MeterLog.Level] { lock.withLock { lines.map(\.0) } }
    }

    @Test("The seam redacts secrets that a call site forgot to sanitize")
    func seamRedactsWithoutCallSiteHelp() {
        let capture = Capture()
        let logger = MeterLogger(category: .oauth, emit: capture.emit)

        // Every value below is passed raw, exactly as a careless call site would.
        logger.error("refresh failed for user@example.com")
        logger.warning("Bearer sk-ant-abc123DEF456 rejected")
        logger.info("scanned /Users/someone/.claude/projects")
        logger.debug("session 123e4567-e89b-12d3-a456-426614174000 ended")

        let joined = capture.messages.joined(separator: "\n")
        #expect(!joined.contains("user@example.com"))
        #expect(!joined.contains("sk-ant-abc123DEF456"))
        #expect(!joined.contains("/Users/someone"))
        #expect(!joined.contains("123e4567-e89b-12d3-a456-426614174000"))
        #expect(joined.contains("[redacted]"))
        #expect(capture.levels == [.error, .warning, .info, .debug])
    }

    @Test("A typed error reaches the log with its reason sanitized")
    func typedErrorIsSanitized() {
        struct Failure: LocalizedError {
            var errorDescription: String? { "token eyJhbG.ciOiJI.UzI1NiJ9 expired" }
        }
        let capture = Capture()
        let logger = MeterLogger(category: .poll, emit: capture.emit)

        logger.error("poll failed", error: Failure())

        let message = capture.messages.joined()
        #expect(message.contains("poll failed"))
        #expect(!message.contains("eyJhbG.ciOiJI.UzI1NiJ9"))
    }

    @Test("The file sink stays off until it is turned on")
    func fileSinkIsOffByDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = MeterLogFileSink(directoryURL: directory)

        #expect(!sink.isEnabled)
        sink.append(level: .error, category: .app, message: "ignored")
        #expect(!FileManager.default.fileExists(atPath: sink.fileURL.path))
    }

    @Test("An enabled sink writes owner-only lines and turning it off removes them")
    func fileSinkWritesAndClears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = MeterLogFileSink(directoryURL: directory)

        sink.setEnabled(true)
        sink.append(level: .warning, category: .cost, message: "scan timed out")
        try sink.drainForTesting()

        let contents = try String(contentsOf: sink.fileURL, encoding: .utf8)
        #expect(contents.contains("[warning] cost: scan timed out"))
        let attributes = try FileManager.default.attributesOfItem(atPath: sink.fileURL.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)

        sink.setEnabled(false)
        try sink.drainForTesting()
        #expect(!FileManager.default.fileExists(atPath: sink.fileURL.path))
    }

    @Test("One formatted line names its level and category")
    func lineFormatNamesLevelAndCategory() {
        let line = MeterLogFileSink.line(
            level: .error, category: .bridge, message: "install failed\nsecond line")
        #expect(line.contains("[error] bridge: install failed second line"))
        #expect(line.hasSuffix("\n"))
    }
}
