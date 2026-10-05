import Foundation

/// Detects test processes, so live system access fails closed during tests.
public enum TestProcess {
    public static let isRunning: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        {
            return true
        }
        // `swift test` runs a helper whose name and environment vary; the loaded test
        // frameworks do not.
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            if path.contains("/XCTest.framework/") || path.contains("/Testing.framework/")
                || path.hasSuffix("/libXCTestSwiftSupport.dylib")
            {
                return true
            }
        }
        return false
    }()

    public static var allowsLiveKeychain: Bool {
        ProcessInfo.processInfo.environment["CLAUDE_METER_LIVE_KEYCHAIN"] == "1"
    }
}
