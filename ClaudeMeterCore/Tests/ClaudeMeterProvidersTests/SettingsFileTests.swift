import Darwin
import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Settings file")
struct SettingsFileTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func missingFileReturnsEmptySettings() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(
            try SettingsFile.read(at: directory.appendingPathComponent("settings.json")).isEmpty)
    }

    @Test func followsRegularFileSymbolicLink() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("settings.json")
        try Data(#"{"statusLine":{"type":"command"}}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let settings = try SettingsFile.read(at: link)
        #expect((settings["statusLine"] as? [String: Any])?["type"] as? String == "command")
    }

    @Test func atomicWritePreservesSymbolicLinkAndUpdatesItsTarget() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("settings.json")
        try Data(#"{"old":true}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: target.lastPathComponent)

        try SettingsFile.write(["new": true], at: link)

        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "target.json")
        let targetSettings = try SettingsFile.read(at: target)
        #expect(targetSettings["new"] as? Bool == true)
        #expect(targetSettings["old"] == nil)
    }

    @Test func specialFileFailsWithoutBlocking() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        #expect(file.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)

        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: BoundedRegularFileReader.ReadError.notRegularFile) {
            try SettingsFile.read(at: file)
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func oversizedFileFailsBeforeAllocation() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(repeating: 0x20, count: 4 * 1_024 * 1_024 + 1).write(to: file)

        #expect(throws: BoundedRegularFileReader.ReadError.self) {
            try SettingsFile.read(at: file)
        }
    }
}
