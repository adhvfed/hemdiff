import XCTest
@testable import DiskSift

@MainActor
final class SetupTests: XCTestCase {
    func testSetupProgressCompletionAndRerunPreserveLocations() throws {
        let suite = "DiskSiftSetupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/example/projects"], forKey: "scanRootPaths")
        let model = AppModel(defaults: defaults, startsAutomatically: false)
        model.showSetup()
        XCTAssertTrue(model.isShowingSetup)
        model.setupPage = 2
        let restored = AppModel(defaults: defaults, startsAutomatically: false)
        XCTAssertEqual(restored.setupPage, 2)
        // Avoid starting an unrelated filesystem scan when completing the fixture.
        model.isReviewingDeletion = true
        model.finishSetup()
        XCTAssertTrue(defaults.bool(forKey: "setupCompleted"))
        XCTAssertFalse(model.isShowingSetup)
        XCTAssertFalse(defaults.bool(forKey: "setupInProgress"))
        model.showSetup()
        XCTAssertTrue(model.isShowingSetup)
        XCTAssertEqual(model.setupPage, 0)
        XCTAssertTrue(defaults.bool(forKey: "setupInProgress"))
        XCTAssertEqual(model.scanRoots.map(\.path), ["/example/projects"])
    }
}
