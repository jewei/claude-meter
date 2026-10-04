import Foundation
import MeterTestSupport
import Testing

@testable import MeterPlatform

@Suite struct LogFileTests {
    @Test func createsPrivateFilesAndDeletesThemWhenDisabled() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = LogFile(directory: directory.path("Logs"))
        file.setEnabled(true)
        file.append("line one")
        file.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.current.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: file.directory.path)
        #expect(folder[.posixPermissions] as? Int == 0o700)
        #expect(try String(contentsOf: file.current, encoding: .utf8).contains("line one"))

        file.setEnabled(false)
        file.flush()
        #expect(!FileManager.default.fileExists(atPath: file.current.path))
    }

    @Test func rotatesOnce() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = LogFile(directory: directory.url, rotationBytes: 64)
        file.setEnabled(true)
        for index in 0..<10 { file.append("entry number \(index) with padding") }
        file.flush()
        #expect(FileManager.default.fileExists(atPath: file.previous.path))
        let current = try Data(contentsOf: file.current)
        #expect(current.count < 128)
    }

    @Test func turningOffDeletesFilesThatAnEarlierRunLeft() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = LogFile(directory: directory.url)
        try directory.write("old", to: "ClaudeMeter.log")
        try directory.write("older", to: "ClaudeMeter.previous.log")
        #expect(!file.isEnabled)
        file.setEnabled(false)
        file.flush()
        #expect(!FileManager.default.fileExists(atPath: file.current.path))
        #expect(!FileManager.default.fileExists(atPath: file.previous.path))
    }
}

@Suite struct LogTests {
    @Test func redactsBeforeTheFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = LogFile(directory: directory.url)
        file.setEnabled(true)
        let log = Log(.app, file: file)
        log.error("token sk-ant-oat01-secret for me@example.com")
        log.error("refresh failed", URLError(.badServerResponse))
        file.flush()
        let text = try String(contentsOf: file.current, encoding: .utf8)
        #expect(text.contains("[error] app: token [redacted] for [redacted]"))
        #expect(text.contains("[error] app: refresh failed: "))
        #expect(!text.contains("sk-ant"))
        #expect(!text.contains("example.com"))
    }

    @Test func writesNothingWhileTheFileIsOff() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = LogFile(directory: directory.url)
        Log(.history, file: file).notice("scan finished")
        file.flush()
        #expect(!FileManager.default.fileExists(atPath: file.current.path))
    }
}
