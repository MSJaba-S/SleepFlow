import XCTest

/// End-to-end flows on the simulator. Every test runs with in-memory storage and simulated sensors,
/// so it never touches real data, the microphone or real alarms.
final class SleepFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-ResetState", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        return app
    }

    @MainActor
    func testOnboardingLeadsToToday() throws {
        let app = launch([])
        for step in 0..<5 {
            let next = app.buttons["onboarding.continue"]
            XCTAssertTrue(next.waitForExistence(timeout: 10), "Continue button missing on step \(step)")
            next.tap()
        }
        let finish = app.buttons["onboarding.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        finish.tap()
        XCTAssertTrue(app.buttons["dashboard.start"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPowerNapCountsFromSleepAndEndsWithAReport() throws {
        let app = launch(["-SkipOnboarding", "-SimulatedSensors"])
        let nap = app.buttons["dashboard.nap.powerNap20"]
        XCTAssertTrue(nap.waitForExistence(timeout: 15))
        nap.tap()
        let start = app.buttons["presleep.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let stop = app.buttons["wakeup.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 90), "The simulated nap should end on the wake-up screen")
        stop.tap()

        let done = app.buttons["report.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "The report should open after waking")
        XCTAssertTrue(app.staticTexts["Wake after sleep"].waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.buttons["dashboard.start"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSimulatedNightWithAlarm() throws {
        let app = launch(["-SkipOnboarding", "-SimulatedSensors"])
        let start = app.buttons["dashboard.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let go = app.buttons["presleep.start"]
        XCTAssertTrue(go.waitForExistence(timeout: 10))
        go.tap()

        let wake = app.buttons["wakeup.stop"]
        if wake.waitForExistence(timeout: 120) {
            wake.tap()
        } else {
            let hold = app.buttons["night.stop"]
            XCTAssertTrue(hold.exists, "Neither the wake-up screen nor the stop control appeared")
            hold.press(forDuration: 2)
        }
        XCTAssertTrue(app.buttons["report.done"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Sleep phases"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testDemoDataScreens() throws {
        let app = launch(["-SkipOnboarding", "-SeedDemoData"])
        let lastNight = app.buttons["dashboard.lastNight"]
        XCTAssertTrue(lastNight.waitForExistence(timeout: 60), "Demo nights should appear on Today")
        lastNight.tap()
        let done = app.buttons["report.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["How the score is made"].waitForExistence(timeout: 10))
        done.tap()

        app.tabBars.buttons["Statistics"].tap()
        XCTAssertTrue(app.staticTexts["Sleep duration"].waitForExistence(timeout: 15))

        app.tabBars.buttons["Journal"].tap()
        let write = app.buttons["journal.new"]
        XCTAssertTrue(write.waitForExistence(timeout: 10))
        write.tap()
        let factor = app.buttons["factor.caffeine"]
        XCTAssertTrue(factor.waitForExistence(timeout: 10))
        factor.tap()
        app.buttons["journal.save"].tap()
        XCTAssertTrue(app.buttons["journal.entry"].firstMatch.waitForExistence(timeout: 10))

        app.tabBars.buttons["Relax"].tap()
        let rain = app.buttons["soundscape.rain"]
        XCTAssertTrue(rain.waitForExistence(timeout: 10))
        rain.tap()
        let stopSound = app.buttons["relax.stop"]
        XCTAssertTrue(stopSound.waitForExistence(timeout: 10))
        stopSound.tap()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["settings.demo"].waitForExistence(timeout: 10))
    }
}
