import Foundation

public enum CLIPathDetector {
    /// Ordered list of directories to search for the `claude` binary.
    public static let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// Returns the first executable `claude` found in the standard search dirs, or nil.
    public static func detect(binaryName: String = "claude") -> String? {
        searchDirectories
            .map { "\($0)/\(binaryName)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns true if the path exists and is executable.
    public static func verify(path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
