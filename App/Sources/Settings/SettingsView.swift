import SwiftUI
import SleepCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(PermissionCenter.self) private var permissions
    @Environment(AlarmCoordinator.self) private var alarms

    @State private var clipsSize: Int64 = 0
    @State private var confirmDeleteClips = false
    @State private var confirmClearDemo = false
    @State private var launchLanguage: AppSettings.LanguageChoice?

    var body: some View {
        @Bindable var settings = settings
        @Bindable var model = model
        List {
            Section("Sleep") {
                TextField("Your first name (optional)", text: $settings.userName)
                    .textContentType(.givenName)
                    .submitLabel(.done)
                Stepper(value: $settings.sleepGoalMinutes, in: 300...660, step: 15) {
                    HStack {
                        Text("Sleep goal")
                        Spacer()
                        Text(Formatters.duration(settings.sleepGoal))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityIdentifier("settings.goal")
                Picker("Tracking method", selection: $settings.trackingMethod) {
                    ForEach(TrackingMethod.allCases, id: \.self) { method in
                        Text(method.title).tag(method)
                    }
                }
                NavigationLink {
                    AlarmSettingsView()
                } label: {
                    LabeledContent("Alarm") {
                        Text(alarmSummary)
                    }
                }
                .accessibilityIdentifier("settings.alarm")
                NavigationLink {
                    ScoreWeightsView()
                } label: {
                    Text("Sleep Score weighting")
                }
            }
            .listRowBackground(Theme.surface)

            Section {
                Toggle("Use Apple's sound recognition", isOn: $settings.useSoundModel)
                Toggle("Save short sound clips", isOn: $settings.saveSoundClips)
                    .accessibilityIdentifier("settings.clips")
                if clipsSize > 0 {
                    LabeledContent("Saved clips") {
                        Text(ByteCountFormatter.string(fromByteCount: clipsSize, countStyle: .file))
                    }
                    Button("Delete all sound clips", role: .destructive) {
                        confirmDeleteClips = true
                    }
                }
            } header: {
                Text("Sound analysis")
            } footer: {
                Text("Sound is analysed the moment it is recorded and then thrown away – only numbers such as levels and detected events are kept. If you turn on clips, up to 40 short recordings of snoring and talking per night are kept on this iPhone so you can listen to them.")
            }
            .listRowBackground(Theme.surface)

            Section {
                Toggle("Dim the night screen automatically", isOn: $settings.dimNightScreen)
            } header: {
                Text("Night screen")
            }
            .listRowBackground(Theme.surface)

            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(AppSettings.LanguageChoice.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .accessibilityIdentifier("settings.language")
            } header: {
                Text("Appearance and language")
            } footer: {
                if let launchLanguage, launchLanguage != settings.language {
                    Text("Close and reopen SleepFlow to use the new language.")
                }
            }
            .listRowBackground(Theme.surface)

            Section {
                Toggle("Show demo data", isOn: $model.demoModeEnabled)
                    .accessibilityIdentifier("settings.demo")
                if settings.demoMode {
                    Button {
                        Task { await model.generateDemoData() }
                    } label: {
                        HStack {
                            Text("Create new demo nights")
                            if model.isGeneratingDemoData {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isGeneratingDemoData)
                    Button("Delete demo data", role: .destructive) {
                        confirmClearDemo = true
                    }
                }
            } header: {
                Text("Demo")
            } footer: {
                Text("Demo nights are simulated and stored completely apart from your own data. They never appear in your own statistics or exports.")
            }
            .listRowBackground(Theme.surface)

            Section("Permissions") {
                PermissionRow(title: "Microphone", symbol: "mic", state: permissions.microphone) {
                    Task { _ = await permissions.requestMicrophone() }
                } openSettings: {
                    permissions.openSystemSettings()
                }
                PermissionRow(title: "Notifications", symbol: "bell", state: permissions.notifications) {
                    Task { _ = await permissions.requestNotifications() }
                } openSettings: {
                    permissions.openSystemSettings()
                }
                if PermissionCenter.alarmKitSupported {
                    PermissionRow(title: "Alarms", symbol: "alarm", state: permissions.alarms) {
                        Task { await alarms.requestAuthorization() }
                    } openSettings: {
                        permissions.openSystemSettings()
                    }
                }
            }
            .listRowBackground(Theme.surface)

            Section("Privacy and data") {
                NavigationLink {
                    PrivacyView()
                } label: {
                    Label("Privacy", systemImage: "hand.raised")
                }
                NavigationLink {
                    DataManagementView()
                } label: {
                    Label("Export and delete data", systemImage: "externaldrive")
                }
                .accessibilityIdentifier("settings.data")
            }
            .listRowBackground(Theme.surface)

            Section("About") {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("About SleepFlow", systemImage: "info.circle")
                }
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle("Settings")
        .demoBanner(model.isDemo)
        .task {
            if launchLanguage == nil { launchLanguage = settings.language }
            clipsSize = FileLocations.clipsSize()
            await permissions.refresh()
        }
        .confirmationDialog("Delete all sound clips?", isPresented: $confirmDeleteClips, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                FileLocations.deleteAllClips()
                model.store.removeAllClipReferences(demo: false)
                model.store.removeAllClipReferences(demo: true)
                clipsSize = FileLocations.clipsSize()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete all demo data?", isPresented: $confirmClearDemo, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.clearDemoData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your own nights are not affected.")
        }
    }

    private var alarmSummary: LocalizedStringKey {
        guard settings.alarm.isEnabled else { return "Off" }
        let time = Formatters.clock(minutes: Double(settings.alarm.hour * 60 + settings.alarm.minute))
        return settings.alarm.isSmartEnabled ? "\(time) · Smart Alarm" : "\(time)"
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let state: PermissionState
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            switch state {
            case .granted:
                Text("Allowed")
                    .foregroundStyle(Theme.positive)
            case .denied:
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderless)
            case .notDetermined:
                Button("Allow", action: request)
                    .buttonStyle(.borderless)
            case .unavailable:
                Text("Not available")
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

extension AppSettings.Appearance {
    var title: LocalizedStringKey {
        switch self {
        case .system: return "Same as iPhone"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

extension AppSettings.LanguageChoice {
    var title: LocalizedStringKey {
        switch self {
        case .system: return "Same as iPhone"
        case .danish: return "Dansk"
        case .english: return "English"
        }
    }
}

/// Lets the user decide how much each factor counts in the Sleep Score.
struct ScoreWeightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    @State private var resets = 0
    @State private var applied = false

    var body: some View {
        List {
            Section {
                ForEach(ScoreFactor.allCases, id: \.self) { factor in
                    WeightRow(
                        factor: factor,
                        weight: settings.scoreWeights.weight(for: factor),
                        share: settings.scoreWeights.share(of: factor)
                    ) { newValue in
                        let updated = settings.scoreWeights.setting(factor, to: newValue)
                        if !updated.isEmpty {
                            settings.scoreWeights = updated
                            applied = false
                        }
                    }
                }
            } header: {
                Text("Weighting")
            } footer: {
                Text("The percentage shows how much a factor counts when all six are measured. Set a factor to zero to leave it out. At least one factor must count.")
            }
            .listRowBackground(Theme.surface)
            .id(resets)

            Section {
                Button("Apply to earlier nights") {
                    model.rescoreStoredNights()
                    applied = true
                }
                .accessibilityIdentifier("weights.apply")
                Button("Reset to standard") {
                    settings.scoreWeights = .standard
                    resets += 1
                    applied = false
                }
            } footer: {
                Text(applied
                     ? LocalizedStringKey("Earlier nights have been recalculated with the new weighting.")
                     : LocalizedStringKey("New weights are used for coming nights. Recalculate earlier nights to compare them fairly."))
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle("Sleep Score weighting")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WeightRow: View {
    let factor: ScoreFactor
    let share: Double
    let onChange: (Double) -> Void

    @State private var value: Double

    init(factor: ScoreFactor, weight: Double, share: Double, onChange: @escaping (Double) -> Void) {
        self.factor = factor
        self.share = share
        self.onChange = onChange
        _value = State(initialValue: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(factor.title, systemImage: factor.symbol)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Text(verbatim: Formatters.percent(share))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $value, in: 0...0.5, step: 0.05) {
                Text(factor.title)
            }
            .tint(Theme.accent)
            .onChange(of: value) { _, newValue in
                onChange(newValue)
            }
        }
        .padding(.vertical, 4)
    }
}
