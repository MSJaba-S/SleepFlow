// Umbrella module: `import SleepCore` gives the app every engine module.
@_exported import SleepModels
@_exported import AudioAnalysis
@_exported import MotionAnalysis
@_exported import SleepIntelligence
@_exported import SleepScoring
@_exported import SmartAlarm
@_exported import SleepStatistics
@_exported import SleepSession
@_exported import SleepSimulation

public enum SleepCoreInfo {
    public static let version = SleepConstants.algorithmVersion
}
