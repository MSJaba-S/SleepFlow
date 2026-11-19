import Foundation
import SleepCore

/// Exports everything SleepFlow knows about the user (GDPR data portability).
@MainActor
enum DataExporter {
    struct ExportBundle: Codable {
        var exportedAt: Date
        var appVersion: String
        var algorithmVersion: String
        var sessions: [CompletedSession]
        var journal: [JournalExport]
    }

    struct JournalExport: Codable {
        var night: Date
        var feeling: Int
        var energy: Int
        var mood: Int
        var stress: Int
        var notes: String
        var factors: [String]
        var sessionID: UUID?
    }

    /// Writes `SleepFlow-export.json` and `SleepFlow-nights.csv` and returns their URLs.
    static func export(store: SleepStore, demo: Bool) throws -> [URL] {
        let folder = FileLocations.exports
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.path) { try manager.removeItem(at: folder) }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let records = store.sessions(demo: demo)
        let sessions = records.compactMap { $0.decoded() }
        let journal = store.journalEntries(demo: demo).map { entry in
            JournalExport(
                night: entry.night,
                feeling: entry.feeling,
                energy: entry.energy,
                mood: entry.mood,
                stress: entry.stress,
                notes: entry.notes,
                factors: entry.factors,
                sessionID: entry.session?.id
            )
        }
        let bundle = ExportBundle(
            exportedAt: Date(),
            appVersion: AppEnvironment.appVersion,
            algorithmVersion: SleepConstants.algorithmVersion,
            sessions: sessions,
            journal: journal
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonURL = folder.appendingPathComponent(demo ? "SleepFlow-demo-export.json" : "SleepFlow-export.json")
        try encoder.encode(bundle).write(to: jsonURL, options: .atomic)

        let csvURL = folder.appendingPathComponent(demo ? "SleepFlow-demo-nights.csv" : "SleepFlow-nights.csv")
        try csv(records).write(to: csvURL, atomically: true, encoding: .utf8)
        return [jsonURL, csvURL]
    }

    static func csv(_ records: [SleepSessionRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var lines = ["start,end,method,score,total_sleep_min,time_in_bed_min,efficiency,latency_min,interruptions,deep_min,light_min,snoring_min,coverage,simulated,nap"]
        for record in records.sorted(by: { $0.start < $1.start }) {
            let fields: [String] = [
                formatter.string(from: record.start),
                formatter.string(from: record.end),
                record.methodRaw,
                String(record.score),
                String(format: "%.1f", record.totalSleep / 60),
                String(format: "%.1f", record.timeInBed / 60),
                String(format: "%.3f", record.efficiency),
                record.sleepLatency.map { String(format: "%.1f", $0 / 60) } ?? "",
                String(record.interruptions),
                String(format: "%.1f", record.deepSleep / 60),
                String(format: "%.1f", record.lightSleep / 60),
                String(format: "%.1f", record.snoringDuration / 60),
                String(format: "%.2f", record.dataCoverage),
                record.isSimulated ? "1" : "0",
                record.isNap ? "1" : "0"
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
