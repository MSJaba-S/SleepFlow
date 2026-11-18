// swift-tools-version: 6.0
// SleepCore: platform-neutral sleep analysis engine for SleepFlow.
// Pure Swift + Foundation so every algorithm can be unit tested on macOS, iOS and Linux.
import PackageDescription

let package = Package(
    name: "SleepCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SleepCore", targets: ["SleepCore"])
    ],
    targets: [
        .target(name: "SleepModels"),
        .target(name: "AudioAnalysis", dependencies: ["SleepModels"]),
        .target(name: "MotionAnalysis", dependencies: ["SleepModels"]),
        .target(name: "SleepIntelligence", dependencies: ["SleepModels"]),
        .target(name: "SleepScoring", dependencies: ["SleepModels"]),
        .target(name: "SmartAlarm", dependencies: ["SleepModels"]),
        .target(name: "SleepStatistics", dependencies: ["SleepModels"]),
        .target(
            name: "SleepSession",
            dependencies: ["SleepModels", "AudioAnalysis", "MotionAnalysis", "SleepIntelligence", "SleepScoring", "SmartAlarm"]
        ),
        .target(
            name: "SleepSimulation",
            dependencies: ["SleepModels", "AudioAnalysis", "MotionAnalysis"]
        ),
        .target(
            name: "SleepCore",
            dependencies: [
                "SleepModels", "AudioAnalysis", "MotionAnalysis", "SleepIntelligence",
                "SleepScoring", "SmartAlarm", "SleepStatistics", "SleepSession", "SleepSimulation"
            ]
        ),
        .testTarget(name: "SleepCoreTests", dependencies: ["SleepCore"])
    ]
)
