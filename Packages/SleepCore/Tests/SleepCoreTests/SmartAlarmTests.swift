import XCTest
@testable import SmartAlarm
@testable import SleepModels

final class SmartAlarmEngineTests: XCTestCase {
    let deadline = Date(timeIntervalSince1970: 1_700_030_000)
    var occurrence: AlarmOccurrence {
        AlarmOccurrence(key: "test", deadline: deadline, windowStart: deadline.addingTimeInterval(-30 * 60))
    }

    func estimate(awake: Double, light: Double, deep: Double, arousal: Bool, hasData: Bool = true) -> OnlineEstimate {
        OnlineEstimate(epochIndex: 0, probabilities: StageProbabilities(awake: awake, light: light, deep: deep), arousal: arousal, hasData: hasData, activity: arousal ? 1 : 0)
    }

    func testWaitsBeforeTheWindow() {
        var engine = SmartAlarmEngine()
        let decision = engine.evaluate(now: deadline.addingTimeInterval(-45 * 60), occurrence: occurrence, estimate: estimate(awake: 0.9, light: 0.1, deep: 0, arousal: true))
        XCTAssertEqual(decision, .wait)
    }

    func testWakesInLightSleepWithMovement() {
        var engine = SmartAlarmEngine()
        let decision = engine.evaluate(now: deadline.addingTimeInterval(-20 * 60), occurrence: occurrence, estimate: estimate(awake: 0.1, light: 0.7, deep: 0.2, arousal: true))
        XCTAssertEqual(decision, .wake(.lightSleep))
    }

    func testDoesNotWakeFromDeepSleep() {
        var engine = SmartAlarmEngine()
        let decision = engine.evaluate(now: deadline.addingTimeInterval(-20 * 60), occurrence: occurrence, estimate: estimate(awake: 0.02, light: 0.18, deep: 0.8, arousal: true))
        XCTAssertEqual(decision, .wait)
    }

    func testLightSleepWithoutMovementWaits() {
        var engine = SmartAlarmEngine()
        let decision = engine.evaluate(now: deadline.addingTimeInterval(-20 * 60), occurrence: occurrence, estimate: estimate(awake: 0.1, light: 0.8, deep: 0.1, arousal: false))
        XCTAssertEqual(decision, .wait)
    }

    func testAlreadyAwakeNeedsTwoEpochs() {
        var engine = SmartAlarmEngine()
        let awake = estimate(awake: 0.8, light: 0.15, deep: 0.05, arousal: false)
        XCTAssertEqual(engine.evaluate(now: deadline.addingTimeInterval(-25 * 60), occurrence: occurrence, estimate: awake), .wait)
        XCTAssertEqual(engine.evaluate(now: deadline.addingTimeInterval(-24.5 * 60), occurrence: occurrence, estimate: awake), .wake(.alreadyAwake))
    }

    func testDeadlineAlwaysWakes() {
        var engine = SmartAlarmEngine()
        let deep = estimate(awake: 0, light: 0.05, deep: 0.95, arousal: false)
        XCTAssertEqual(engine.evaluate(now: deadline, occurrence: occurrence, estimate: deep), .wake(.deadline))
        var late = SmartAlarmEngine()
        XCTAssertEqual(late.evaluate(now: deadline.addingTimeInterval(600), occurrence: occurrence, estimate: nil), .wake(.deadline))
    }

    func testNoDataInWindowWaitsForTheGuaranteedAlarm() {
        var engine = SmartAlarmEngine()
        XCTAssertEqual(engine.evaluate(now: deadline.addingTimeInterval(-10 * 60), occurrence: occurrence, estimate: nil), .wait)
        XCTAssertEqual(engine.evaluate(now: deadline.addingTimeInterval(-9 * 60), occurrence: occurrence, estimate: estimate(awake: 0.9, light: 0.1, deep: 0, arousal: true, hasData: false)), .wait)
    }

    func testFinalStretchWakesWhenNotDeep() {
        var engine = SmartAlarmEngine()
        let decision = engine.evaluate(now: deadline.addingTimeInterval(-2 * 60), occurrence: occurrence, estimate: estimate(awake: 0.1, light: 0.6, deep: 0.3, arousal: false))
        XCTAssertEqual(decision, .wake(.nearDeadline))
    }

    func testDecisionLatches() {
        var engine = SmartAlarmEngine()
        _ = engine.evaluate(now: deadline.addingTimeInterval(-15 * 60), occurrence: occurrence, estimate: estimate(awake: 0.2, light: 0.7, deep: 0.1, arousal: true))
        let later = engine.evaluate(now: deadline.addingTimeInterval(-14 * 60), occurrence: occurrence, estimate: estimate(awake: 0, light: 0, deep: 1, arousal: false))
        XCTAssertEqual(later, .wake(.lightSleep))
        engine.reset()
        XCTAssertNil(engine.decided)
    }

    func testZeroWindowBehavesLikeANormalAlarm() {
        var engine = SmartAlarmEngine()
        let plain = AlarmOccurrence(key: "plain", deadline: deadline, windowStart: deadline)
        XCTAssertEqual(engine.evaluate(now: deadline.addingTimeInterval(-60), occurrence: plain, estimate: estimate(awake: 0.9, light: 0.1, deep: 0, arousal: true)), .wait)
        XCTAssertEqual(engine.evaluate(now: deadline, occurrence: plain, estimate: nil), .wake(.deadline))
    }
}

final class AlarmPlannerTests: XCTestCase {
    func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let zone = TimeZone(identifier: identifier) {
            calendar.timeZone = zone
        }
        return calendar
    }

    func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testOneShotAlarmIsTodayOrTomorrow() {
        let cal = calendar("Europe/Copenhagen")
        let settings = AlarmSettings(hour: 7, minute: 30, weekdays: [])
        let evening = date(cal, 2026, 11, 18, 23, 0)
        let next = AlarmOccurrencePlanner.next(settings: settings, after: evening, calendar: cal)
        XCTAssertEqual(next?.deadline, date(cal, 2026, 11, 19, 7, 30))
        XCTAssertEqual(next?.windowStart, date(cal, 2026, 11, 19, 7, 0))
        XCTAssertEqual(next?.key, "2026-11-19 07:30")

        let earlyMorning = date(cal, 2026, 11, 19, 5, 0)
        XCTAssertEqual(AlarmOccurrencePlanner.next(settings: settings, after: earlyMorning, calendar: cal)?.deadline, date(cal, 2026, 11, 19, 7, 30))
        XCTAssertEqual(AlarmOccurrencePlanner.upcoming(settings: settings, after: evening, calendar: cal).count, 1)
    }

    func testWeekdaysOnly() {
        let cal = calendar("Europe/Copenhagen")
        // 2026-11-20 is a Friday.
        let friday = date(cal, 2026, 11, 20, 22, 0)
        let settings = AlarmSettings(hour: 6, minute: 45, weekdays: Weekday.weekdays)
        let upcoming = AlarmOccurrencePlanner.upcoming(settings: settings, after: friday, calendar: cal)
        XCTAssertEqual(upcoming.first?.deadline, date(cal, 2026, 11, 23, 6, 45), "Next alarm after Friday evening is Monday")
        XCTAssertTrue(upcoming.allSatisfy { Weekday(rawValue: cal.component(.weekday, from: $0.deadline)).map { Weekday.weekdays.contains($0) } ?? false })
        XCTAssertEqual(upcoming.count, 5)
    }

    func testDisabledAlarmHasNoOccurrences() {
        var settings = AlarmSettings()
        settings.isEnabled = false
        XCTAssertTrue(AlarmOccurrencePlanner.upcoming(settings: settings, after: Date(), calendar: calendar("Europe/Copenhagen")).isEmpty)
    }

    func testSmartWindowOffMeansNoWindow() {
        let cal = calendar("Europe/Copenhagen")
        var settings = AlarmSettings(hour: 7, minute: 0, weekdays: [])
        settings.isSmartEnabled = false
        let next = AlarmOccurrencePlanner.next(settings: settings, after: date(cal, 2026, 11, 18, 22, 0), calendar: cal)
        XCTAssertEqual(next?.windowStart, next?.deadline)
    }

    func testDaylightSavingKeepsWallClockTime() throws {
        let cal = calendar("Europe/Copenhagen")
        guard cal.timeZone.identifier == "Europe/Copenhagen" else { throw XCTSkip("Time zone database not available") }
        let settings = AlarmSettings(hour: 7, minute: 0, weekdays: Set(Weekday.allCases))
        // Spring forward: night of 28 → 29 March 2026 (02:00 → 03:00).
        let spring = AlarmOccurrencePlanner.upcoming(settings: settings, after: date(cal, 2026, 3, 28, 22, 0), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: spring[0].deadline), 7)
        XCTAssertEqual(spring[1].deadline.timeIntervalSince(spring[0].deadline), 24 * 3600, "Day after the change is a normal day")
        XCTAssertEqual(spring[0].deadline.timeIntervalSince(date(cal, 2026, 3, 28, 22, 0)), 8 * 3600, "The short night is one hour shorter")
        // Fall back: night of 24 → 25 October 2026 (03:00 → 02:00).
        let autumn = AlarmOccurrencePlanner.upcoming(settings: settings, after: date(cal, 2026, 10, 24, 22, 0), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: autumn[0].deadline), 7)
        XCTAssertEqual(autumn[0].deadline.timeIntervalSince(date(cal, 2026, 10, 24, 22, 0)), 10 * 3600, "The long night is one hour longer")
    }

    func testNonExistentTimeMovesForward() throws {
        let cal = calendar("Europe/Copenhagen")
        guard cal.timeZone.identifier == "Europe/Copenhagen" else { throw XCTSkip("Time zone database not available") }
        let day = date(cal, 2026, 3, 29, 12, 0)
        let result = AlarmOccurrencePlanner.wallClockDate(on: day, hour: 2, minute: 30, calendar: cal)
        XCTAssertNotNil(result)
        if let result {
            XCTAssertTrue(cal.isDate(result, inSameDayAs: day))
            XCTAssertGreaterThanOrEqual(cal.component(.hour, from: result), 3)
        }
    }

    func testTimeZoneChangeKeepsKeyButMovesInstant() throws {
        let copenhagen = calendar("Europe/Copenhagen")
        let newYork = calendar("America/New_York")
        guard newYork.timeZone.identifier == "America/New_York" else { throw XCTSkip("Time zone database not available") }
        let settings = AlarmSettings(hour: 7, minute: 0, weekdays: [])
        let now = date(copenhagen, 2026, 11, 18, 20, 0)
        let home = AlarmOccurrencePlanner.next(settings: settings, after: now, calendar: copenhagen)
        let away = AlarmOccurrencePlanner.next(settings: settings, after: now, calendar: newYork)
        XCTAssertNotNil(home)
        XCTAssertNotNil(away)
        XCTAssertNotEqual(home?.deadline, away?.deadline)
        XCTAssertEqual(newYork.component(.hour, from: away!.deadline), 7)
    }
}

final class AlarmReconcilerTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func occurrence(_ key: String, _ hours: Double) -> AlarmOccurrence {
        AlarmOccurrence(key: key, deadline: base.addingTimeInterval(hours * 3600), windowStart: base.addingTimeInterval(hours * 3600 - 1800))
    }

    func record(_ key: String, _ hours: Double, role: ScheduledAlarmRecord.Role = .deadline) -> ScheduledAlarmRecord {
        ScheduledAlarmRecord(occurrenceKey: key, alarmID: UUID().uuidString, fireDate: base.addingTimeInterval(hours * 3600), role: role, backend: "test")
    }

    func testSchedulesMissingAndKeepsExisting() {
        let desired = [occurrence("a", 10), occurrence("b", 34)]
        let result = AlarmReconciler.reconcile(desired: desired, scheduled: [record("a", 10)], now: base)
        XCTAssertEqual(result.toKeep.map(\.occurrenceKey), ["a"])
        XCTAssertEqual(result.toSchedule.map(\.key), ["b"])
        XCTAssertTrue(result.toCancel.isEmpty)
    }

    func testCancelsChangedAndRemoved() {
        let desired = [occurrence("a", 10.5)]
        let result = AlarmReconciler.reconcile(desired: desired, scheduled: [record("a", 10), record("old", 20)], now: base)
        XCTAssertEqual(Set(result.toCancel.map(\.occurrenceKey)), ["a", "old"])
        XCTAssertEqual(result.toSchedule.map(\.key), ["a"])
        XCTAssertTrue(result.toKeep.isEmpty)
    }

    func testSuppressedOccurrenceIsNotRescheduled() {
        let desired = [occurrence("a", 10), occurrence("b", 34)]
        let result = AlarmReconciler.reconcile(desired: desired, scheduled: [record("a", 10)], suppressedKeys: ["a"], now: base)
        XCTAssertEqual(result.toCancel.map(\.occurrenceKey), ["a"])
        XCTAssertEqual(result.toSchedule.map(\.key), ["b"])
    }

    func testSmartAndSnoozeRecordsAreIgnored() {
        let desired = [occurrence("a", 10)]
        let result = AlarmReconciler.reconcile(desired: desired, scheduled: [record("a", 10), record("a", 9.6, role: .smart)], now: base)
        XCTAssertEqual(result.toKeep.count, 1)
        XCTAssertTrue(result.toCancel.isEmpty)
        XCTAssertTrue(result.isEmpty)
    }

    func testDuplicateRecordsAreCancelled() {
        let desired = [occurrence("a", 10)]
        let result = AlarmReconciler.reconcile(desired: desired, scheduled: [record("a", 10), record("a", 10)], now: base)
        XCTAssertEqual(result.toKeep.count, 1)
        XCTAssertEqual(result.toCancel.count, 1)
    }
}
