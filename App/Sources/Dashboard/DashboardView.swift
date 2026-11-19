import Charts
import SwiftData
import SwiftUI
import SleepCore

/// "Today": start the night, next alarm, last night's score and the past week at a glance.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(TrackingController.self) private var tracking
    @Query(sort: \SleepSessionRecord.start, order: .reverse) private var sessions: [SleepSessionRecord]

    @State private var showPreSleep = false
    @State private var preSleepChoice: WakeChoice = .clock
    @State private var pendingStart: WakeChoice?
    @State private var startError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                header
                if let recovered = tracking.recovered {
                    RecoveryCard(recovered: recovered)
                }
                if let message = startError ?? tracking.errorMessage {
                    ErrorCard(message: message) {
                        startError = nil
                        tracking.clearError()
                    }
                }
                NapCard { preset in
                    openPreSleep(.afterSleep(preset))
                }
                startCard
                AlarmSummaryCard()
                if let latest = sessions.first {
                    LastNightCard(record: latest)
                } else {
                    FirstNightCard()
                }
                if sessions.count >= 2 {
                    WeekCard(sessions: Array(sessions.prefix(7)), goal: settings.sleepGoal)
                }
            }
            .padding(.horizontal, Theme.padding)
            .padding(.bottom, Theme.padding)
        }
        .background(NightBackground())
        .toolbar(.hidden, for: .navigationBar)
        .demoBanner(model.isDemo)
        .sheet(isPresented: $showPreSleep, onDismiss: {
            guard let choice = pendingStart else { return }
            pendingStart = nil
            Task { await startSession(choice) }
        }) {
            PreSleepView(initialChoice: preSleepChoice) { choice in
                pendingStart = choice
                showPreSleep = false
            }
            .environment(model)
            .environment(settings)
            .environment(model.permissions)
            .environment(model.alarms)
            .environment(model.relaxation)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Formatters.dayAndDate(Date()))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            Text(greeting)
                .font(.display(.largeTitle))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private var greeting: LocalizedStringKey {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = settings.userName.trimmingCharacters(in: .whitespaces)
        switch hour {
        case 5..<11: return name.isEmpty ? "Good morning" : "Good morning, \(name)"
        case 11..<17: return name.isEmpty ? "Good afternoon" : "Good afternoon, \(name)"
        case 17..<22: return name.isEmpty ? "Good evening" : "Good evening, \(name)"
        default: return name.isEmpty ? "Good night" : "Good night, \(name)"
        }
    }

    private var startCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.title)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready for bed?")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(settings.trackingMethod == .microphone
                             ? LocalizedStringKey("Sound tracking · phone on the bedside table")
                             : LocalizedStringKey("Movement tracking · phone on the mattress"))
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                }
                Button {
                    openPreSleep(.clock)
                } label: {
                    Label("Start sleep tracking", systemImage: "play.fill")
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("dashboard.start")
            }
        }
    }

    private func openPreSleep(_ choice: WakeChoice) {
        startError = nil
        tracking.clearError()
        preSleepChoice = choice
        showPreSleep = true
    }

    private func startSession(_ choice: WakeChoice) async {
        do {
            try await model.startTracking(wake: choice)
        } catch {
            startError = error.localizedDescription
        }
    }
}

// MARK: - Cards

/// Wake after sleep: power naps and whole sleep cycles, counted from falling asleep.
private struct NapCard: View {
    let open: (NapPreset) -> Void

    private let quick: [NapPreset] = [.powerNap20, .powerNap30, .cycles1]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.title)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake after sleep")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Counts from the moment you fall asleep and wakes you in light sleep – not in deep sleep.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    ForEach(quick) { preset in
                        Button {
                            open(preset)
                        } label: {
                            VStack(spacing: 4) {
                                Text(verbatim: preset.durationText)
                                    .font(.display(.headline))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Text(preset.isPowerNap ? LocalizedStringKey("Power nap") : LocalizedStringKey("1 cycle"))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 62)
                            .background(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous).fill(Theme.surfaceRaised))
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("dashboard.nap.\(preset.rawValue)")
                    }
                }
                Button {
                    open(.cycles2)
                } label: {
                    HStack {
                        Text("More sleep cycles")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ErrorCard: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(Theme.negative)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tracking could not start")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.smallCornerRadius).fill(Theme.negative.opacity(0.12)))
    }
}

/// Shown when the app was terminated during a night and a journal was found on launch.
private struct RecoveryCard: View {
    let recovered: RecoveredSession
    @Environment(TrackingController.self) private var tracking
    @State private var confirmDiscard = false
    @State private var busy = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Your last night was interrupted", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("SleepFlow was closed during the night. Everything until \(Formatters.time(recovered.lastRecordedTime)) was kept safely on your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    busy = true
                    Task {
                        await tracking.finishRecovered()
                        busy = false
                    }
                } label: {
                    Text("Save the night")
                }
                .buttonStyle(.primary)
                .disabled(busy)
                .accessibilityIdentifier("recovery.save")
                if tracking.canResumeRecovered {
                    Button {
                        busy = true
                        Task {
                            try? await tracking.resumeRecovered()
                            busy = false
                        }
                    } label: {
                        Text("Continue tracking")
                    }
                    .buttonStyle(.secondary)
                    .disabled(busy)
                }
                Button("Discard", role: .destructive) {
                    confirmDiscard = true
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .disabled(busy)
            }
        }
        .confirmationDialog("Discard the interrupted night?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { tracking.discardRecovered() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The data recorded so far will be deleted.")
        }
    }
}

/// Next alarm with a quick on/off switch.
private struct AlarmSummaryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(AlarmCoordinator.self) private var alarms
    @Environment(PermissionCenter.self) private var permissions

    var body: some View {
        @Bindable var settings = settings
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Alarm", systemImage: "alarm")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Toggle("Alarm", isOn: $settings.alarm.isEnabled)
                        .labelsHidden()
                        .onChange(of: settings.alarm.isEnabled) { _, _ in model.alarmChanged() }
                        .accessibilityIdentifier("dashboard.alarmToggle")
                }
                if settings.alarm.isEnabled, let next = alarms.nextOccurrence {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Formatters.time(next.deadline))
                            .font(.display(.largeTitle))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                        Text(next.deadline.formatted(.dateTime.weekday(.wide)))
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if settings.alarm.isSmartEnabled {
                        Text("Smart Alarm from \(Formatters.time(next.windowStart)) – wakes you when you are in light sleep.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Rings at the set time.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else if settings.alarm.isEnabled {
                    Text("No upcoming alarm. Choose the days it should ring.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("The alarm is off. SleepFlow tracks your night without waking you.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.alarm.isEnabled && alarms.authorization == .denied {
                    PermissionNotice(title: "Alarms are not allowed", message: "Without permission SleepFlow cannot wake you. Allow alarms in Settings.") {
                        permissions.openSystemSettings()
                    }
                } else if settings.alarm.isEnabled && alarms.authorization == .notDetermined {
                    Button("Allow alarms") {
                        Task { await alarms.requestAuthorization() }
                    }
                    .buttonStyle(.secondary)
                }
                NavigationLink {
                    AlarmSettingsView()
                } label: {
                    HStack {
                        Text("Alarm settings")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
                .accessibilityIdentifier("dashboard.alarmSettings")
            }
        }
    }
}

private struct LastNightCard: View {
    let record: SleepSessionRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.reportRoute = ReportRoute(sessionID: record.id, demo: model.isDemo)
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        SectionTitle(title: "Last night")
                        Spacer()
                        Text(Formatters.shortDate(record.start))
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    HStack(spacing: 18) {
                        ScoreRing(score: record.score, size: 128, lineWidth: 12)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.quality.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Label {
                                Text(Formatters.duration(record.totalSleep))
                            } icon: {
                                Image(systemName: "bed.double.fill")
                            }
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            Label {
                                Text(Formatters.percent(record.efficiency))
                            } icon: {
                                Image(systemName: "gauge.with.dots.needle.67percent")
                            }
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            if record.dataCoverage < 0.6 {
                                Pill(text: "Partly measured", symbol: "exclamationmark.triangle", tint: Theme.accentSoft)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Text("Open morning report")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dashboard.lastNight")
    }
}

private struct FirstNightCard: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Your first night")
                InfoRow(symbol: "1.circle", title: "Start before you sleep", text: "Tap Start sleep tracking when you go to bed and place the phone as shown.")
                InfoRow(symbol: "2.circle", title: "Sleep as usual", text: "SleepFlow measures in the background. With Smart Alarm it wakes you in a light phase.")
                InfoRow(symbol: "3.circle", title: "Read your report", text: "In the morning you get a Sleep Score, your sleep phases and what affected the night.")
                if !settings.demoMode {
                    Button {
                        model.demoModeEnabled = true
                    } label: {
                        Label("Explore with demo data", systemImage: "theatermasks")
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("dashboard.demo")
                    Text("Demo data is simulated and kept apart from your own nights. Switch it off again in Settings.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The last seven nights: averages and a small score chart.
private struct WeekCard: View {
    let sessions: [SleepSessionRecord]
    let goal: TimeInterval

    private var summaries: [NightSummary] { sessions.map(\.summary) }

    var body: some View {
        let summary = StatisticsCalculator.summary(summaries, calendar: .current)
        let points = StatisticsCalculator.dailyPoints(summaries, calendar: .current)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Past 7 nights")
                HStack(spacing: 10) {
                    StatTile(title: "Average score", value: "\(Int(summary.averageScore.rounded()))", symbol: "star.fill")
                    StatTile(title: "Average sleep", value: Formatters.duration(summary.averageSleep), symbol: "bed.double.fill", tint: Theme.info)
                }
                HStack(spacing: 10) {
                    StatTile(
                        title: "Regularity",
                        value: summary.consistencyScore.map { "\(Int($0.rounded()))" } ?? "–",
                        symbol: "calendar",
                        detail: String(localized: "of 100"),
                        tint: Theme.positive
                    )
                    StatTile(title: "Sleep goal reached", value: Formatters.percent(summary.goalAchievement), symbol: "target", tint: Theme.accentSoft)
                }
                Chart(points) { point in
                    BarMark(
                        x: .value("Night", point.night, unit: .day),
                        y: .value("Score", point.score)
                    )
                    .foregroundStyle(Theme.color(for: point.score).gradient)
                    .cornerRadius(5)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .frame(height: 90)
                .accessibilityLabel(Text("Sleep Score of the past nights"))
            }
        }
    }
}
