import Foundation

enum EngineUpdatePolicyTests {
    static func run() {
        testNewerReleaseIsOffered()
        testSameOrOlderReleaseIsNotOffered()
        testEngineWithoutVersionIsOfferedARelease()
        testBadOrPrereleaseTagsAreIgnored()
    }

    private static func testNewerReleaseIsOffered() {
        TestSupport.expect(EngineUpdatePolicy.updateAvailable(installed: "v0.3.6", latest: "v0.3.7"), "A newer patch release should be offered")
        TestSupport.expect(EngineUpdatePolicy.updateAvailable(installed: "v0.3.9", latest: "v0.4.0"), "A newer minor release should be offered")
    }

    private static func testSameOrOlderReleaseIsNotOffered() {
        TestSupport.expect(!EngineUpdatePolicy.updateAvailable(installed: "v0.3.6", latest: "v0.3.6"), "The installed release should not be offered again")
        TestSupport.expect(!EngineUpdatePolicy.updateAvailable(installed: "v0.4.0", latest: "v0.3.9"), "An older release should not be offered")
        TestSupport.expect(!EngineUpdatePolicy.updateAvailable(installed: "0.3.6", latest: "v0.3.6"), "A missing v prefix should not matter")
    }

    private static func testEngineWithoutVersionIsOfferedARelease() {
        TestSupport.expect(EngineUpdatePolicy.updateAvailable(installed: nil, latest: "v0.3.6"), "Engines from before version reporting should be offered the latest release")
        TestSupport.expect(EngineUpdatePolicy.updateAvailable(installed: "dev", latest: "v0.3.6"), "An unparseable installed version should be treated as old")
    }

    private static func testBadOrPrereleaseTagsAreIgnored() {
        TestSupport.expect(!EngineUpdatePolicy.updateAvailable(installed: "v0.3.6", latest: "nightly"), "A non-version tag should never be offered")
        TestSupport.expect(!EngineUpdatePolicy.updateAvailable(installed: "v0.3.6", latest: "v0.4.0-beta.1"), "Prereleases should not be offered")
    }
}
