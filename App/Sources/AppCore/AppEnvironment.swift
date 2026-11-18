import Foundation
import os

/// Process-wide configuration: launch arguments used by UI tests and bundle information.
enum AppEnvironment {
    static let arguments: [String] = ProcessInfo.processInfo.arguments

    /// Set by UI tests. Uses in-memory storage and never touches real data.
    static var isUITesting: Bool { arguments.contains("-UITestMode") }
    /// Start with an empty app (fresh onboarding).
    static var resetState: Bool { arguments.contains("-ResetState") }
    static var skipOnboarding: Bool { arguments.contains("-SkipOnboarding") }
    /// Replace microphone and accelerometer with the night simulator (fast-forwarded).
    static var useSimulatedSensors: Bool { arguments.contains("-SimulatedSensors") }
    static var seedDemoData: Bool { arguments.contains("-SeedDemoData") }

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil && !isUITesting
    }

    static var usesInMemoryStorage: Bool { isUITesting || isRunningUnitTests }

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }
}

enum Log {
    static let app = Logger(subsystem: "com.samir.SleepFlow", category: "app")
    static let tracking = Logger(subsystem: "com.samir.SleepFlow", category: "tracking")
    static let audio = Logger(subsystem: "com.samir.SleepFlow", category: "audio")
    static let motion = Logger(subsystem: "com.samir.SleepFlow", category: "motion")
    static let alarm = Logger(subsystem: "com.samir.SleepFlow", category: "alarm")
    static let storage = Logger(subsystem: "com.samir.SleepFlow", category: "storage")
}

/// Where SleepFlow keeps its files, and which iOS data protection each location gets.
///
/// Files written during the night must stay writable while the phone is locked, so the journal uses
/// "complete until first user authentication" and sound clips use "complete unless open" (they can be
/// created while locked but only read after the phone has been unlocked).
enum FileLocations {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = AppEnvironment.usesInMemoryStorage ? "SleepFlow-Test" : "SleepFlow"
        return base.appendingPathComponent(folder, isDirectory: true)
    }

    static var activeSession: URL { root.appendingPathComponent("ActiveSession", isDirectory: true) }
    /// Journal of a simulated night; kept apart from real tracking data.
    static var simulatedSession: URL { root.appendingPathComponent("SimulatedSession", isDirectory: true) }
    static var clips: URL { root.appendingPathComponent("Clips", isDirectory: true) }
    static var exports: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SleepFlowExport", isDirectory: true) }
    static var diagnostics: URL { root.appendingPathComponent("diagnostics.json") }

    static func prepare() {
        let manager = FileManager.default
        for url in [root, clips] {
            if !manager.fileExists(atPath: url.path) {
                try? manager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            protect(url, .completeUntilFirstUserAuthentication)
        }
        // Personal sleep data stays on this iPhone: exclude it from iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)
    }

    static func protect(_ url: URL, _ protection: FileProtectionType) {
        try? FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
    }

    static func protectJournalFile(_ url: URL) {
        protect(url, .completeUntilFirstUserAuthentication)
    }

    static func clipURL(named name: String) -> URL {
        clips.appendingPathComponent(name)
    }

    static func deleteAllClips() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil) else { return }
        for file in files { try? manager.removeItem(at: file) }
    }

    static func clipsSize() -> Int64 {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: clips, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
