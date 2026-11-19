import SwiftUI
import SleepCore

struct AboutView: View {
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 64, height: 64)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surfaceRaised))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "SleepFlow")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Version \(AppEnvironment.appVersion) (\(AppEnvironment.buildNumber))")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.vertical, 6)
                LabeledContent("Analysis version") { Text(verbatim: SleepConstants.algorithmVersion) }
            }
            .listRowBackground(Theme.surface)

            Section("How SleepFlow works") {
                AboutRow(title: "Sound", text: "About 20 times a second the microphone signal is turned into features such as loudness, pitch and spectrum. Snoring, talking, coughing and movement sounds are recognised by their pattern; Apple's built-in sound recognition can confirm them.")
                AboutRow(title: "Movement", text: "On the mattress the motion sensor measures small movements. Long, still periods usually mean deeper sleep.")
                AboutRow(title: "Sleep phases", text: "Every 30 seconds sound and movement are combined into an estimate of awake, light or deep sleep, smoothed over the whole night.")
                AboutRow(title: "Smart Alarm", text: "In the wake-up window SleepFlow waits for a moment of light sleep or waking. At the end of the window the alarm always rings.")
                AboutRow(title: "Sleep Score", text: "Six factors – duration, efficiency, time to fall asleep, interruptions, restlessness and regularity – are scored 0–100 and combined with weights you can change.")
            }
            .listRowBackground(Theme.surface)

            Section("Sounds and licences") {
                AboutRow(title: "Original sounds", text: "All alarm and relaxation sounds are created by SleepFlow itself. They contain no recordings from other sources.")
                AboutRow(title: "No third-party code", text: "SleepFlow is built only with Apple's frameworks. No external libraries, no tracking SDKs.")
            }
            .listRowBackground(Theme.surface)

            Section {
                Text("SleepFlow is not a medical device. It estimates sleep from sound and movement and cannot diagnose sleep disorders such as sleep apnoea.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle("About SleepFlow")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutRow: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Recent tracking and alarm events, to understand what happened on a real night.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                if model.diagnostics.entries.isEmpty {
                    Text("Nothing logged yet.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(model.diagnostics.entries.reversed()) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: DiagnosticsView.symbol(for: entry.level))
                                .foregroundStyle(DiagnosticsView.color(for: entry.level))
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: entry.message)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(verbatim: "\(entry.date.formatted(date: .abbreviated, time: .standard)) · \(entry.category)")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } footer: {
                Text("Technical events from tracking and alarms (interruptions, restarts, warm phone, alarm deliveries). Contains no audio and no sleep data, and never leaves your iPhone.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.diagnostics.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear the diagnostics log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.diagnostics.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }

    static func symbol(for level: DiagnosticsLog.Entry.Level) -> String {
        switch level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    static func color(for level: DiagnosticsLog.Entry.Level) -> Color {
        switch level {
        case .info: return Theme.textSecondary
        case .warning: return Theme.accentSoft
        case .error: return Theme.negative
        }
    }
}
