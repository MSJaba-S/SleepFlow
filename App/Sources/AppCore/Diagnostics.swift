import Foundation
import Observation

/// Small persistent log of what happened to tracking and alarms (interruptions, restarts, thermal
/// warnings, alarm deliveries). Shown in Settings › About › Diagnostics so problems on a real night
/// can be understood afterwards. Contains no audio and no sleep data.
@MainActor
@Observable
final class DiagnosticsLog {
    struct Entry: Codable, Identifiable, Hashable {
        enum Level: String, Codable { case info, warning, error }
        var id = UUID()
        var date: Date
        var category: String
        var message: String
        var level: Level
    }

    static let maximumEntries = 300

    private(set) var entries: [Entry] = []
    private let url: URL?

    init(persistent: Bool = true) {
        url = persistent ? FileLocations.diagnostics : nil
        if let url, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    func info(_ category: String, _ message: String) {
        add(Entry(date: Date(), category: category, message: message, level: .info))
    }

    func warning(_ category: String, _ message: String) {
        add(Entry(date: Date(), category: category, message: message, level: .warning))
    }

    func error(_ category: String, _ message: String) {
        add(Entry(date: Date(), category: category, message: message, level: .error))
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func add(_ entry: Entry) {
        entries.append(entry)
        if entries.count > DiagnosticsLog.maximumEntries {
            entries.removeFirst(entries.count - DiagnosticsLog.maximumEntries)
        }
        persist()
    }

    private func persist() {
        guard let url else { return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
            FileLocations.protect(url, .completeUntilFirstUserAuthentication)
        }
    }
}
