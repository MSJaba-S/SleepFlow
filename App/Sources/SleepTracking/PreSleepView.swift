import SwiftUI
import SleepCore

/// Last check before the night: method, placement, alarm and permissions.
struct PreSleepView: View {
    /// Called when everything is ready; the dashboard closes this sheet and starts the night.
    let onStart: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(PermissionCenter.self) private var permissions
    @Environment(AlarmCoordinator.self) private var alarms
    @Environment(RelaxationController.self) private var relaxation
    @Environment(\.dismiss) private var dismiss

    @State private var requesting = false
    @State private var problem: LocalizedStringKey?

    private var usesSimulator: Bool { model.isDemo || AppEnvironment.useSimulatedSensors }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    if usesSimulator {
                        demoNotice
                    }
                    SectionTitle(title: "How to measure")
                    VStack(spacing: 10) {
                        ForEach(TrackingMethod.allCases, id: \.self) { method in
                            MethodCard(method: method, selected: settings.trackingMethod == method) {
                                settings.trackingMethod = method
                                problem = nil
                            }
                        }
                    }
                    if settings.trackingMethod == .microphone && !usesSimulator {
                        microphoneStatus
                    }

                    SectionTitle(title: "Wake-up")
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            alarmSummary
                            NavigationLink {
                                AlarmSettingsView()
                            } label: {
                                Text("Change alarm")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }

                    SectionTitle(title: "Before you sleep")
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            InfoRow(symbol: "battery.100.bolt", title: "Plug in the charger", text: "Tracking all night uses battery. With the charger connected, nothing is missed.")
                            InfoRow(symbol: "moon.circle", title: "Use a Sleep Focus", text: "Silences notifications at night. A SleepFlow alarm still rings.")
                            if !alarms.ringsThroughSilentMode {
                                InfoRow(symbol: "speaker.wave.2", title: "Keep the volume up", text: "On this iPhone the alarm is a notification with sound. Turn off Silent mode and leave the volume up.")
                            }
                            if relaxation.isPlaying {
                                InfoRow(symbol: "headphones", title: "Relaxation sound continues", text: "SleepFlow knows the sound is playing and takes it into account.")
                            }
                        }
                    }

                    if let problem {
                        Text(problem)
                            .font(.subheadline)
                            .foregroundStyle(Theme.negative)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.padding)
            }
            .background(NightBackground())
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await prepareAndStart() }
                } label: {
                    if requesting {
                        ProgressView()
                            .tint(Theme.accentText)
                    } else {
                        Label("Start the night", systemImage: "moon.fill")
                    }
                }
                .buttonStyle(.primary)
                .disabled(requesting)
                .padding(.horizontal, Theme.padding)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .accessibilityIdentifier("presleep.start")
            }
            .navigationTitle("Ready for bed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var demoNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "theatermasks.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Demo mode: a simulated night runs in about a minute, including the Smart Alarm. Your own data is not touched.")
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.smallCornerRadius).fill(Theme.accent.opacity(0.12)))
    }

    @ViewBuilder
    private var microphoneStatus: some View {
        switch permissions.microphone {
        case .granted:
            Label("Microphone allowed", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.positive)
        case .denied:
            PermissionNotice(title: "Microphone access is off", message: "Turn it on in Settings, or use movement tracking.") {
                permissions.openSystemSettings()
            }
        default:
            Text("SleepFlow will ask for the microphone when you start.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var alarmSummary: some View {
        if !settings.alarm.isEnabled {
            Text("No alarm. SleepFlow tracks the night without waking you.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        } else if usesSimulator {
            Text("The simulated night ends with a simulated alarm.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        } else if let next = alarms.nextOccurrence, next.deadline.timeIntervalSinceNow < 18 * 3600 {
            VStack(alignment: .leading, spacing: 4) {
                Text(Formatters.time(next.deadline))
                    .font(.display(.title))
                    .foregroundStyle(Theme.textPrimary)
                if settings.alarm.isSmartEnabled {
                    Text("Smart Alarm between \(Formatters.time(next.windowStart)) and \(Formatters.time(next.deadline)).")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        } else {
            Text("No alarm in the next 18 hours.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func prepareAndStart() async {
        problem = nil
        if settings.trackingMethod == .microphone && !usesSimulator {
            switch permissions.microphone {
            case .denied:
                problem = "Microphone access is off. Allow it in Settings or choose movement tracking."
                return
            case .granted:
                break
            default:
                requesting = true
                let granted = await permissions.requestMicrophone()
                requesting = false
                if !granted {
                    problem = "Without the microphone SleepFlow cannot use sound tracking. Choose movement tracking instead."
                    return
                }
            }
        }
        if settings.alarm.isEnabled && !usesSimulator && alarms.authorization == .notDetermined {
            requesting = true
            await alarms.requestAuthorization()
            requesting = false
        }
        onStart()
    }
}
