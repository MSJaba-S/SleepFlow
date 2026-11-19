import Foundation
import SleepCore

/// Fills the separate demo store with simulated nights so every screen can be explored without
/// sleeping first. Demo nights are produced by SleepCore's night simulator and analysed by the real
/// pipeline; they are always flagged as simulated and never written to the real store.
@MainActor
enum DemoDataGenerator {
    static func populate(store: SleepStore, settings: AppSettings, nights: Int) async {
        store.deleteAll(demo: true)
        let calendar = Calendar.current
        var rng = SplitMix64(seed: 20_261_118)
        let today = calendar.startOfDay(for: Date())
        let factors = LifestyleFactor.allCases.map(\.rawValue)

        for offset in stride(from: nights, through: 1, by: -1) {
            guard let evening = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let bedMinutes = 22 * 60 + 45 + rng.gaussian(sd: 35)
            let bedtime = evening.addingTimeInterval(bedMinutes * 60)
            let scenario = NightScenario(
                method: rng.chance(0.75) ? .microphone : .motion,
                bedtime: bedtime,
                timeInBed: (7.2 + rng.gaussian(sd: 0.55)) * 3600,
                sleepLatency: max(3, 14 + rng.gaussian(sd: 9)) * 60,
                awakenings: Int(rng.unit() * 4),
                snoringPropensity: rng.uniform(0...0.35),
                restlessness: rng.uniform(0.1...0.7),
                talkingPropensity: 0.03,
                noise: rng.uniform(0...0.05)
            )
            let night = NightSimulator.simulate(scenario, seed: UInt64(offset) &* 7_919)
            let deadline = night.end
            let occurrence = AlarmOccurrence(key: "demo-\(offset)", deadline: deadline, windowStart: deadline.addingTimeInterval(-30 * 60))
            let header = SessionHeader(
                start: night.start,
                method: scenario.method,
                alarm: occurrence,
                smartAlarmEnabled: true,
                sleepGoal: settings.sleepGoal,
                isSimulated: true,
                appVersion: AppEnvironment.appVersion,
                timeZoneIdentifier: TimeZone.current.identifier
            )
            let early = rng.uniform(0...20) * 60
            let markers = [
                SessionMarker(time: night.start, kind: .batteryLevel, detail: "96 % charging"),
                SessionMarker(time: deadline.addingTimeInterval(-early), kind: early > 60 ? .smartAlarmTriggered : .alarmRang, detail: early > 60 ? WakeReason.lightSleep.rawValue : WakeReason.deadline.rawValue),
                SessionMarker(time: deadline, kind: .ended)
            ]
            let input = SessionAssemblyInput(
                header: header,
                end: deadline,
                epochs: night.epochs,
                soundEvents: night.soundEvents,
                movementEvents: night.movementEvents,
                markers: markers,
                history: store.history(before: night.start, demo: true),
                previousScore: store.previousScore(before: night.start, demo: true),
                weights: settings.scoreWeights
            )
            let completed = SessionAssembler.assemble(input)
            guard let record = try? store.save(completed, demo: true) else { continue }

            if rng.chance(0.7) {
                let night = StatisticsCalculator.nightDate(for: record.start, calendar: calendar)
                if let entry = store.journalEntry(forNight: night, demo: true, create: true) {
                    let quality = Double(completed.score.value) / 100
                    entry.feeling = min(5, max(1, Int((1 + quality * 4 + rng.gaussian(sd: 0.6)).rounded())))
                    entry.energy = min(5, max(1, Int((1 + quality * 4 + rng.gaussian(sd: 0.8)).rounded())))
                    entry.mood = min(5, max(1, Int((2 + quality * 3 + rng.gaussian(sd: 0.7)).rounded())))
                    entry.stress = min(5, max(1, Int((4 - quality * 2.5 + rng.gaussian(sd: 0.8)).rounded())))
                    entry.factors = factors.filter { _ in rng.chance(0.18) }
                    entry.updatedAt = Date()
                    store.saveJournal(demo: true)
                }
            }
            await Task.yield()
        }

        // A few naps, analysed exactly like a live "wake after sleep" session.
        let naps: [(daysAgo: Int, plan: NapPlan)] = [(9, .cycles(1)), (4, .powerNap(minutes: 20)), (1, .powerNap(minutes: 30))]
        for (daysAgo, plan) in naps where daysAgo < nights {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let start = day.addingTimeInterval((14 * 60 + 20 + rng.gaussian(sd: 20)) * 60)
            saveDemoNap(plan: plan, start: start, seed: UInt64(daysAgo) &* 104_729, store: store, settings: settings)
            await Task.yield()
        }
    }

    private static func saveDemoNap(plan: NapPlan, start: Date, seed: UInt64, store: SleepStore, settings: AppSettings) {
        let method: TrackingMethod = .microphone
        let length = plan.latestDeadline(start: start).timeIntervalSince(start) + 15 * 60
        let scenario = NightScenario(method: method, bedtime: start, timeInBed: length, sleepLatency: 9 * 60, awakenings: 0, snoringPropensity: 0.1, restlessness: 0.3)
        let night = NightSimulator.simulate(scenario, seed: seed)
        let key = NapPlan.key(start: start, calendar: .current)
        let estimator = OnlineSleepEstimator(method: method)
        var tracker = NapTracker(plan: plan, key: key, start: start)
        var engine = SmartAlarmEngine()
        var markers = [SessionMarker(time: start, kind: .batteryLevel, detail: "88 % charging")]
        var end = night.end
        var epochs: [EpochFeatures] = []
        for epoch in night.epochs {
            epochs.append(epoch)
            let estimate = estimator.update(with: epoch)
            let update = tracker.update(epochStart: epoch.start, estimate: estimate)
            if case .countingStarted(let at, let detected, _) = update {
                markers.append(SessionMarker(time: at, kind: .napCountingStarted, detail: detected ? "sleep" : "latest"))
            }
            var reason: WakeReason?
            if update == .wakeBeforeDeepSleep {
                reason = .beforeDeepSleep
            } else if case .wake(let decided) = engine.evaluate(now: epoch.end, occurrence: tracker.occurrence, estimate: estimate) {
                reason = decided
            }
            if let reason {
                markers.append(SessionMarker(time: epoch.end, kind: reason == .deadline ? .alarmRang : .smartAlarmTriggered, detail: reason.rawValue))
                end = epoch.end.addingTimeInterval(60)
                break
            }
        }
        markers.append(SessionMarker(time: end, kind: .ended))
        let header = SessionHeader(
            start: start,
            method: method,
            alarm: tracker.occurrence,
            smartAlarmEnabled: true,
            sleepGoal: plan.sleepDuration,
            isSimulated: true,
            appVersion: AppEnvironment.appVersion,
            timeZoneIdentifier: TimeZone.current.identifier,
            napPlan: plan
        )
        let input = SessionAssemblyInput(
            header: header,
            end: end,
            epochs: epochs,
            soundEvents: night.soundEvents.filter { $0.start < end },
            movementEvents: night.movementEvents.filter { $0.start < end },
            markers: markers,
            history: [],
            previousScore: store.previousScore(before: start, demo: true, nap: true),
            weights: settings.scoreWeights
        )
        _ = try? store.save(SessionAssembler.assemble(input), demo: true)
    }
}
