import Testing

@testable import MeterApp

/// About and the update status write the version with one rule (review R4-U-05).
@Suite struct AppVersionTests {
    @Test func theTextNamesTheBuildOnlyWhenItAddsSomething() {
        #expect(AppVersion(version: "4.0.0", build: "400").text == "4.0.0 (400)")
        #expect(AppVersion(version: "4.0.0", build: nil).text == "4.0.0")
        #expect(AppVersion(version: "4.0.0", build: "").text == "4.0.0")
        #expect(AppVersion(version: "4.0.0", build: "4.0.0").text == "4.0.0")
    }

    @Test func aMissingOrEmptyVersionIsUnknown() {
        for version in [
            AppVersion(version: nil, build: "400"), AppVersion(version: "", build: "1"),
        ] {
            #expect(!version.isKnown)
            #expect(version.text == "—")
        }
        #expect(AppVersion(version: "4.0.0", build: nil).isKnown)
    }

    @Test func theUpdateStatusUsesTheSameText() {
        for version in [
            AppVersion(version: "4.0.0", build: "400"),
            AppVersion(version: "4.0.0", build: "4.0.0"),
        ] {
            #expect(
                UpdateCheckText.status(
                    version: version.version, build: version.build, isUpdateAvailable: false)
                    == "Installed v\(version.text)")
        }
        #expect(
            UpdateCheckText.status(version: "", build: "400", isUpdateAvailable: false)
                == "Installed version unknown")
    }
}
