import Foundation
import SleepModels

/// Crash-safe, append-only record of the night being tracked.
///
/// Every finished epoch, event and marker is appended as one JSON line as soon as it exists.
/// If the app is terminated (by the user, iOS or a crash) the night can be recovered from these
/// files on the next launch; at most the last unfinished epoch is lost.
public final class SessionJournal {
    public enum JournalError: Error, Equatable {
        case notStarted
        case alreadyStarted
    }

    static let headerFile = "header.json"
    static let epochsFile = "epochs.jsonl"
    static let soundsFile = "sounds.jsonl"
    static let movementsFile = "movements.jsonl"
    static let markersFile = "markers.jsonl"

    public let directory: URL
    /// Applies iOS data protection to created files (injected by the app; no-op elsewhere).
    public let protect: ((URL) -> Void)?
    public private(set) var header: SessionHeader?
    private var handles: [String: FileHandle] = [:]

    public init(directory: URL, protect: ((URL) -> Void)? = nil) {
        self.directory = directory
        self.protect = protect
    }

    deinit {
        for handle in handles.values {
            try? handle.close()
        }
    }

    public static func exists(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(headerFile).path)
    }

    public func start(_ header: SessionHeader) throws {
        guard self.header == nil else { throw JournalError.alreadyStarted }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        protect?(directory)
        let headerURL = directory.appendingPathComponent(SessionJournal.headerFile)
        try SessionJournal.encoder().encode(header).write(to: headerURL, options: .atomic)
        protect?(headerURL)
        for name in [SessionJournal.epochsFile, SessionJournal.soundsFile, SessionJournal.movementsFile, SessionJournal.markersFile] {
            let url = directory.appendingPathComponent(name)
            _ = fileManager.createFile(atPath: url.path, contents: nil)
            protect?(url)
        }
        self.header = header
    }

    /// Re-opens an existing journal for appending (after recovery).
    public func resume(_ header: SessionHeader) {
        self.header = header
    }

    public func append(_ epoch: EpochFeatures) throws {
        try appendLine(epoch, to: SessionJournal.epochsFile)
    }

    public func append(_ event: SoundEvent) throws {
        try appendLine(event, to: SessionJournal.soundsFile)
    }

    public func append(_ event: MovementEvent) throws {
        try appendLine(event, to: SessionJournal.movementsFile)
    }

    public func append(_ marker: SessionMarker) throws {
        try appendLine(marker, to: SessionJournal.markersFile)
    }

    /// Flushes and closes the files; the journal stays on disk until `discard()`.
    public func close() {
        for handle in handles.values {
            try? handle.synchronize()
            try? handle.close()
        }
        handles.removeAll()
    }

    public func discard() throws {
        close()
        header = nil
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func appendLine<T: Encodable>(_ value: T, to name: String) throws {
        guard header != nil else { throw JournalError.notStarted }
        var data = try SessionJournal.encoder().encode(value)
        data.append(0x0A)
        let fileHandle = try openHandle(named: name)
        try fileHandle.write(contentsOf: data)
    }

    private func openHandle(named name: String) throws -> FileHandle {
        if let existing = handles[name] { return existing }
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            protect?(url)
        }
        let newHandle = try FileHandle(forWritingTo: url)
        try newHandle.seekToEnd()
        handles[name] = newHandle
        return newHandle
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: - Recovery

    /// Reads a journal left behind by a previous run. Malformed lines (for example a line that was
    /// being written when the app was killed) are skipped.
    public static func recover(from directory: URL) -> RecoveredSession? {
        let headerURL = directory.appendingPathComponent(headerFile)
        guard let headerData = try? Data(contentsOf: headerURL),
              let header = try? decoder().decode(SessionHeader.self, from: headerData) else { return nil }
        let epochs: [EpochFeatures] = readLines(directory.appendingPathComponent(epochsFile))
        let sounds: [SoundEvent] = readLines(directory.appendingPathComponent(soundsFile))
        let movements: [MovementEvent] = readLines(directory.appendingPathComponent(movementsFile))
        let markers: [SessionMarker] = readLines(directory.appendingPathComponent(markersFile))
        return RecoveredSession(header: header, epochs: epochs, soundEvents: sounds, movementEvents: movements, markers: markers)
    }

    static func readLines<T: Decodable>(_ url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = SessionJournal.decoder()
        var result: [T] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let value = try? decoder.decode(T.self, from: Data(line)) {
                result.append(value)
            }
        }
        return result
    }
}

/// Contents of a journal found on launch.
public struct RecoveredSession: Sendable {
    public var header: SessionHeader
    public var epochs: [EpochFeatures]
    public var soundEvents: [SoundEvent]
    public var movementEvents: [MovementEvent]
    public var markers: [SessionMarker]

    public init(header: SessionHeader, epochs: [EpochFeatures], soundEvents: [SoundEvent], movementEvents: [MovementEvent], markers: [SessionMarker]) {
        self.header = header
        self.epochs = epochs
        self.soundEvents = soundEvents
        self.movementEvents = movementEvents
        self.markers = markers
    }

    public var isFinished: Bool { markers.contains { $0.kind == .ended } }

    /// Time of the last thing that was recorded.
    public var lastRecordedTime: Date {
        var latest = header.start
        if let epoch = epochs.max(by: { $0.index < $1.index }) { latest = max(latest, epoch.end) }
        if let sound = soundEvents.map(\.end).max() { latest = max(latest, sound) }
        if let movement = movementEvents.map(\.end).max() { latest = max(latest, movement) }
        if let marker = markers.map(\.time).max() { latest = max(latest, marker) }
        return latest
    }
}
