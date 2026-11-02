import XCTest

/// The update rules (H-8, G-21, ported from Obscura's): once a day and only when allowed, Check for Updates… always
/// checks, Later clears the banner, a failed install says why and leaves the app as it was, and a build with no release
/// key or feed never checks. A stand-in updater; no network. roadmap: S-13
@MainActor
final class UpdateCoordinatorTests: XCTestCase {
    final class FakeDriver: UpdateDriver {
        var isAvailable = true
        var lastCheck: Date?
        var result: UpdateCheckResult = .upToDate(version: "1.0")
        var installResult: UpdateInstallResult = .relaunching
        var checks = 0
        func recordCheck(at date: Date) { lastCheck = date }
        func check() async -> UpdateCheckResult { checks += 1; return result }
        func install() async -> UpdateInstallResult { installResult }
    }

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "vt-updates-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func testScheduledChecksRunOnceADayAndOnlyWhenAllowed() async {
        let driver = FakeDriver()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = UpdateCoordinator(driver: driver, defaults: defaults, now: { clock })
        let ran = await coordinator.scheduledCheck()
        XCTAssertTrue(ran)
        let again = await coordinator.scheduledCheck()
        XCTAssertFalse(again, "not twice in a day")
        clock += UpdateCoordinator.checkInterval + 1
        let nextDay = await coordinator.scheduledCheck()
        XCTAssertTrue(nextDay)
        defaults.set(false, forKey: UpdateCoordinator.automaticKey)
        clock += UpdateCoordinator.checkInterval + 1
        let off = await coordinator.scheduledCheck()
        XCTAssertFalse(off, "automatic checks off")
        XCTAssertEqual(driver.checks, 2)
    }

    func testAnOfferShowsInstallsOrIsDismissed() async {
        let driver = FakeDriver()
        driver.result = .available(UpdateOffer(version: "1.1"))
        let coordinator = UpdateCoordinator(driver: driver, defaults: defaults)
        let result = await coordinator.checkForUpdates()
        XCTAssertEqual(result, .available(UpdateOffer(version: "1.1")))
        XCTAssertEqual(coordinator.offer?.version, "1.1")
        coordinator.dismiss()
        XCTAssertNil(coordinator.offer, "Later clears the banner")

        _ = await coordinator.checkForUpdates()
        driver.installResult = .failed(reason: "The download did not match the signed size.")
        await coordinator.install()
        XCTAssertEqual(coordinator.offer?.phase, .failed(reason: "The download did not match the signed size."))
    }

    func testABuildWithoutAReleaseKeyNeverChecks() async {
        let driver = FakeDriver()
        driver.isAvailable = false
        let coordinator = UpdateCoordinator(driver: driver, defaults: defaults)
        let scheduled = await coordinator.scheduledCheck()
        let manual = await coordinator.checkForUpdates()
        XCTAssertFalse(scheduled)
        XCTAssertNil(manual, "Check for Updates… says updates aren't set up")
        XCTAssertEqual(driver.checks, 0)
    }

    func testThisBuildHasNoUpdaterUntilTheReleaseStep() {
        // The project ships placeholders: no feed and no key, so nothing is ever fetched (S-13 sets them).
        XCTAssertNil(AppUpdater.trust)
    }
}
