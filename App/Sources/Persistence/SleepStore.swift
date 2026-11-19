import Foundation
import SwiftData
import SleepCore

/// Owns the two SwiftData stores.
///
/// Real nights and demonstration data never share a store: the demo store holds simulated nights
/// only and the UI marks it clearly. Switching demo mode swaps the container the views query.
@MainActor
final class SleepStore {
    let realContainer: ModelContainer
    let demoContainer: ModelContainer

    init(inMemory: Bool) {
        realContainer = SleepStore.makeContainer(name: "SleepFlow", inMemory: inMemory)
        demoContainer = SleepStore.makeContainer(name: "SleepFlowDemo", inMemory: inMemory)
    }

    static func makeContainer(name: String, inMemory: Bool) -> ModelContainer {
        let schema = Schema(versionedSchema: SleepFlowSchemaV1.self)
        let configuration = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, migrationPlan: SleepFlowMigrationPlan.self, configurations: [configuration])
        } catch {
            Log.storage.error("Could not open store \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Last resort so the app still launches; data of this run is not persisted.
            let fallback = ModelConfiguration(name + "-Recovery", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("SwiftData unavailable: \(error)")
            }
        }
    }

    func container(demo: Bool) -> ModelContainer { demo ? demoContainer : realContainer }
    func context(demo: Bool) -> ModelContext { container(demo: demo).mainContext }

    // MARK: - Sessions

    @discardableResult
    func save(_ session: CompletedSession, demo: Bool) throws -> SleepSessionRecord {
        let payload = try JSONEncoder().encode(session)
        let context = self.context(demo: demo)
        let record = SleepSessionRecord(session: session, payload: payload)
        context.insert(record)
        // Attach a journal entry that was written before the session was saved (same night).
        let night = StatisticsCalculator.nightDate(for: session.header.start, calendar: .current)
        if session.header.napPlan == nil, let entry = journalEntries(demo: demo).first(where: { $0.night == night && $0.session == nil }) {
            entry.session = record
        }
        try context.save()
        return record
    }

    func sessions(demo: Bool) -> [SleepSessionRecord] {
        let descriptor = FetchDescriptor<SleepSessionRecord>(sortBy: [SortDescriptor(\.start, order: .reverse)])
        return (try? context(demo: demo).fetch(descriptor)) ?? []
    }

    func session(id: UUID, demo: Bool) -> SleepSessionRecord? {
        var descriptor = FetchDescriptor<SleepSessionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context(demo: demo).fetch(descriptor).first
    }

    func latest(demo: Bool) -> SleepSessionRecord? {
        var descriptor = FetchDescriptor<SleepSessionRecord>(sortBy: [SortDescriptor(\.start, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context(demo: demo).fetch(descriptor).first
    }

    /// Bed and wake times of nights (not naps) before `date`, newest first, for the consistency factor.
    func history(before date: Date, demo: Bool, limit: Int = 14) -> [HistoricalNight] {
        sessions(demo: demo)
            .filter { $0.start < date && !$0.isNap }
            .prefix(limit)
            .map { HistoricalNight(bedtime: $0.sleepOnset ?? $0.start, wakeTime: $0.finalAwakening ?? $0.end) }
    }

    /// Score of the previous session of the same kind (night or nap).
    func previousScore(before date: Date, demo: Bool, nap: Bool = false) -> Int? {
        sessions(demo: demo).first { $0.start < date && $0.isNap == nap }?.score
    }

    /// Nights only – naps are shown separately and kept out of statistics.
    func nights(demo: Bool) -> [SleepSessionRecord] {
        sessions(demo: demo).filter { !$0.isNap }
    }

    func delete(_ record: SleepSessionRecord, demo: Bool) {
        // Remove sound clips that belong to this night.
        if let session = record.decoded() {
            for name in session.soundEvents.compactMap(\.clipFileName) {
                try? FileManager.default.removeItem(at: FileLocations.clipURL(named: name))
            }
        }
        let context = self.context(demo: demo)
        context.delete(record)
        try? context.save()
    }

    func deleteAll(demo: Bool) {
        let context = self.context(demo: demo)
        do {
            try context.delete(model: SleepSessionRecord.self)
            try context.delete(model: JournalEntryRecord.self)
            try context.save()
        } catch {
            Log.storage.error("Delete all failed: \(error.localizedDescription, privacy: .public)")
            for record in sessions(demo: demo) { context.delete(record) }
            for entry in journalEntries(demo: demo) { context.delete(entry) }
            try? context.save()
        }
        if !demo { FileLocations.deleteAllClips() }
    }

    /// Removes the saved clip of one event and updates the stored night.
    func deleteClip(named name: String, in record: SleepSessionRecord, demo: Bool) {
        try? FileManager.default.removeItem(at: FileLocations.clipURL(named: name))
        guard var session = record.decoded() else { return }
        for index in session.soundEvents.indices where session.soundEvents[index].clipFileName == name {
            session.soundEvents[index].clipFileName = nil
        }
        if let payload = try? JSONEncoder().encode(session) {
            record.payload = payload
            try? context(demo: demo).save()
        }
    }

    /// Applies a new score weighting to every stored night. Oldest first, so the comparison with the
    /// previous night uses the new scores as well.
    func rescoreAll(weights: ScoreWeights, demo: Bool) {
        var previous: Int?
        for record in sessions(demo: demo).reversed() {
            guard let session = record.decoded() else { continue }
            let rescored = session.rescored(with: weights, previousScore: previous)
            if let payload = try? JSONEncoder().encode(rescored) {
                record.payload = payload
                record.score = rescored.score.value
                record.qualityRaw = rescored.score.quality.rawValue
            }
            previous = rescored.score.value
        }
        try? context(demo: demo).save()
    }

    func removeAllClipReferences(demo: Bool) {
        for record in sessions(demo: demo) {
            guard var session = record.decoded(), session.soundEvents.contains(where: { $0.clipFileName != nil }) else { continue }
            for index in session.soundEvents.indices { session.soundEvents[index].clipFileName = nil }
            if let payload = try? JSONEncoder().encode(session) { record.payload = payload }
        }
        try? context(demo: demo).save()
    }

    // MARK: - Journal

    func journalEntries(demo: Bool) -> [JournalEntryRecord] {
        let descriptor = FetchDescriptor<JournalEntryRecord>(sortBy: [SortDescriptor(\.night, order: .reverse)])
        return (try? context(demo: demo).fetch(descriptor)) ?? []
    }

    /// Returns the journal entry of a night, creating it (linked to the night's session) if needed.
    func journalEntry(forNight night: Date, demo: Bool, create: Bool) -> JournalEntryRecord? {
        if let existing = journalEntries(demo: demo).first(where: { $0.night == night }) {
            return existing
        }
        guard create else { return nil }
        let session = sessions(demo: demo).first { !$0.isNap && StatisticsCalculator.nightDate(for: $0.start, calendar: .current) == night }
        let entry = JournalEntryRecord(night: night, session: session)
        context(demo: demo).insert(entry)
        try? context(demo: demo).save()
        return entry
    }

    func saveJournal(demo: Bool) {
        try? context(demo: demo).save()
    }

    func delete(_ entry: JournalEntryRecord, demo: Bool) {
        let context = self.context(demo: demo)
        context.delete(entry)
        try? context.save()
    }

    func nightSummaries(demo: Bool) -> [NightSummary] {
        sessions(demo: demo).map(\.summary)
    }
}
