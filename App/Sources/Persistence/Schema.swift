import Foundation
import SwiftData
import SleepCore

/// Version 1 of SleepFlow's persistent model.
///
/// Summary values are stored as columns so lists and statistics can be queried cheaply; the full
/// analysed night (epochs, hypnogram, events, insights) is stored as a JSON payload in external
/// storage. New versions are added as `SleepFlowSchemaV2` etc. with a stage in the migration plan.
enum SleepFlowSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [SleepSessionRecord.self, JournalEntryRecord.self]
    }

    @Model
    final class SleepSessionRecord {
        @Attribute(.unique) var id: UUID
        var start: Date
        var end: Date
        var methodRaw: String
        var isSimulated: Bool
        var score: Int
        var qualityRaw: String
        var totalSleep: Double
        var timeInBed: Double
        var efficiency: Double
        var sleepLatency: Double?
        var sleepOnset: Date?
        var finalAwakening: Date?
        var interruptions: Int
        var deepSleep: Double
        var lightSleep: Double
        var dataCoverage: Double
        var snoringDuration: Double
        var sleepGoal: Double
        var algorithmVersion: String
        @Attribute(.externalStorage) var payload: Data
        @Relationship(deleteRule: .nullify, inverse: \JournalEntryRecord.session)
        var journalEntry: JournalEntryRecord?

        init(session: CompletedSession, payload: Data) {
            id = session.id
            start = session.header.start
            end = session.end
            methodRaw = session.header.method.rawValue
            isSimulated = session.header.isSimulated
            score = session.score.value
            qualityRaw = session.score.quality.rawValue
            totalSleep = session.metrics.totalSleep
            timeInBed = session.metrics.timeInBed
            efficiency = session.metrics.efficiency
            sleepLatency = session.metrics.sleepLatency
            sleepOnset = session.metrics.sleepOnset
            finalAwakening = session.metrics.finalAwakening
            interruptions = session.metrics.interruptions
            deepSleep = session.metrics.deepSleep
            lightSleep = session.metrics.lightSleep
            dataCoverage = session.metrics.dataCoverage
            snoringDuration = session.metrics.snoringDuration
            sleepGoal = session.header.sleepGoal
            algorithmVersion = session.header.algorithmVersion
            self.payload = payload
        }
    }

    @Model
    final class JournalEntryRecord {
        @Attribute(.unique) var id: UUID
        /// The evening of the night this entry describes.
        var night: Date
        var createdAt: Date
        var updatedAt: Date
        /// 1...5 scales.
        var feeling: Int
        var energy: Int
        var mood: Int
        var stress: Int
        var notes: String
        /// `LifestyleFactor` raw values.
        var factors: [String]
        var session: SleepSessionRecord?

        init(night: Date, session: SleepSessionRecord? = nil) {
            id = UUID()
            self.night = night
            createdAt = Date()
            updatedAt = Date()
            feeling = 3
            energy = 3
            mood = 3
            stress = 3
            notes = ""
            factors = []
            self.session = session
        }
    }
}

typealias SleepSessionRecord = SleepFlowSchemaV1.SleepSessionRecord
typealias JournalEntryRecord = SleepFlowSchemaV1.JournalEntryRecord

enum SleepFlowMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SleepFlowSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

extension SleepSessionRecord {
    var method: TrackingMethod { TrackingMethod(rawValue: methodRaw) ?? .microphone }
    var quality: ScoreQuality { ScoreQuality(rawValue: qualityRaw) ?? ScoreQuality(score: score) }

    /// Decodes the analysed night. Returns nil if the payload is damaged.
    func decoded() -> CompletedSession? {
        try? JSONDecoder().decode(CompletedSession.self, from: payload)
    }

    var summary: NightSummary {
        NightSummary(
            id: id,
            start: start,
            end: end,
            sleepOnset: sleepOnset,
            finalAwakening: finalAwakening,
            totalSleep: totalSleep,
            timeInBed: timeInBed,
            efficiency: efficiency,
            score: score,
            sleepGoal: sleepGoal,
            factors: journalEntry?.factors ?? []
        )
    }
}
