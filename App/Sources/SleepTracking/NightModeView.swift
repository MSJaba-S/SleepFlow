import SwiftUI
import SleepCore

/// The screen during the night: a dim clock, the alarm window and what is being measured.
/// Stopping needs a long press so the night is not ended by accident.
struct NightModeView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(TrackingController.self) private var tracking
    @Environment(AlarmCoordinator.self) private var alarms
    @Environment(RelaxationController.self) private var relaxation

    @State private var dimmed = false
    @State private var lastInteraction = Date()
    @State private var showSounds = false

    private var isSimulated: Bool { tracking.active?.isSimulated == true }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 22) {
                statusRow
                Spacer(minLength: 10)
                clock
                alarmLine
                Spacer(minLength: 10)
                measurementPanel
                controls
            }
            .padding(.horizontal, Theme.padding)
            .padding(.vertical, 16)
            .opacity(isBusy ? 0.3 : 1)

            if isBusy {
                busyOverlay
            }

            if dimmed && !isBusy {
                dimOverlay
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { registerInteraction() })
        .statusBarHidden(dimmed)
        .persistentSystemOverlays(dimmed ? .hidden : .automatic)
        .animation(.easeInOut(duration: 0.8), value: dimmed)
        .task { await dimLoop() }
        .sheet(isPresented: $showSounds) {
            NavigationStack {
                RelaxationView(compact: true)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSounds = false }
                        }
                    }
            }
            .environment(model)
            .environment(relaxation)
            .presentationDetents([.medium, .large])
        }
    }

    private var isBusy: Bool {
        tracking.phase == .starting || tracking.phase == .finishing
    }

    // MARK: - Parts

    private var background: some View {
        ZStack {
            Color(hex: 0x03050D).ignoresSafeArea()
            RadialGradient(
                colors: [Theme.accent.opacity(0.10), .clear],
                center: .bottom,
                startRadius: 10,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Pill(text: tracking.active?.header.method == .motion ? "Movement" : "Microphone",
                 symbol: tracking.active?.header.method.symbol ?? "waveform",
                 tint: Theme.accentSoft)
            if isSimulated {
                Pill(text: "Simulated night", symbol: "theatermasks", tint: Theme.info)
            }
            Spacer()
            sensorBadge
        }
    }

    @ViewBuilder
    private var sensorBadge: some View {
        switch tracking.sensorState {
        case .starting:
            Pill(text: "Starting", symbol: "hourglass", tint: Theme.textSecondary)
        case .active:
            Pill(text: "Measuring", symbol: "dot.radiowaves.left.and.right", tint: Theme.positive)
                .accessibilityIdentifier("night.measuring")
        case .interrupted:
            Pill(text: "Paused", symbol: "pause.circle", tint: Theme.negative)
        }
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = isSimulated ? (tracking.simulatedNow ?? context.date) : context.date
            VStack(spacing: 6) {
                Text(Formatters.time(now))
                    .font(.system(size: 84, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier("night.clock")
                if let start = tracking.active?.header.start {
                    Text("Tracking for \(Formatters.duration(now.timeIntervalSince(start)))")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }
    }

    @ViewBuilder
    private var alarmLine: some View {
        if let plan = tracking.napPlan, alarms.ringState == .idle {
            napLine(plan)
        } else if case .snoozed(let until, _) = alarms.ringState {
            Label("Snoozing until \(Formatters.time(until))", systemImage: "zzz")
                .font(.headline)
                .foregroundStyle(Theme.accentSoft)
        } else if let occurrence = tracking.active?.occurrence {
            VStack(spacing: 4) {
                if tracking.active?.header.smartAlarmEnabled == true {
                    Label("Smart Alarm \(Formatters.time(occurrence.windowStart))–\(Formatters.time(occurrence.deadline))", systemImage: "alarm")
                        .font(.headline)
                        .foregroundStyle(Theme.accentSoft)
                    Text("Wakes you in light sleep – at the latest at \(Formatters.time(occurrence.deadline)).")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                } else {
                    Label("Alarm at \(Formatters.time(occurrence.deadline))", systemImage: "alarm")
                        .font(.headline)
                        .foregroundStyle(Theme.accentSoft)
                }
            }
        } else {
            Label("No alarm tonight", systemImage: "alarm.waves.left.and.right")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    /// Wake after sleep: waiting for sleep, then the window in which SleepFlow will wake you.
    @ViewBuilder
    private func napLine(_ plan: NapPlan) -> some View {
        VStack(spacing: 6) {
            plan.title
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
            if let countStart = tracking.napCountStart, let occurrence = tracking.active?.occurrence {
                Group {
                    if tracking.napSleepDetected {
                        Label("Asleep since \(Formatters.time(countStart))", systemImage: "moon.zzz.fill")
                    } else {
                        Label("Counting since \(Formatters.time(countStart))", systemImage: "moon.zzz.fill")
                    }
                }
                .font(.headline)
                .foregroundStyle(Theme.accentSoft)
                .accessibilityIdentifier("night.napCounting")
                Text("Wakes you in light sleep between \(Formatters.time(occurrence.windowStart)) and \(Formatters.time(occurrence.deadline)).")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let start = tracking.active?.header.start {
                Label("Waiting for you to fall asleep…", systemImage: "hourglass")
                    .font(.headline)
                    .foregroundStyle(Theme.accentSoft)
                    .accessibilityIdentifier("night.napWaiting")
                Text("Counting starts when SleepFlow notices that you are asleep – at the latest at \(Formatters.time(plan.latestCountStart(start: start))).")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var measurementPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .interrupted = tracking.sensorState {
                Text(pauseExplanation)
                    .font(.footnote)
                    .foregroundStyle(Theme.accentSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tracking.active?.header.method != .motion {
                LevelMeter(level: tracking.level)
            }
            HStack(spacing: 10) {
                NightStat(title: "Sounds", value: "\(tracking.soundCounts.values.reduce(0, +))", symbol: "waveform")
                NightStat(title: "Movements", value: "\(tracking.movementCount)", symbol: "figure.roll")
                if isSimulated, let estimate = tracking.estimate {
                    NightStat(title: "Estimated now", text: estimate.probabilities.mostLikely.shortTitle, symbol: "moon.zzz")
                }
            }
            Text(placementReminder)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private var pauseExplanation: LocalizedStringKey {
        if tracking.active?.header.method == .motion {
            return "Movement tracking pauses while SleepFlow is not on screen. Keep the app open during the night."
        }
        return "The microphone is busy or unavailable (for example during a call). Tracking resumes automatically."
    }

    private var placementReminder: LocalizedStringKey {
        if tracking.active?.header.method == .motion {
            return "Phone face down on the mattress, next to your pillow. Keep SleepFlow open; the screen dims by itself."
        }
        return "You can lock the phone now. SleepFlow keeps listening and the alarm rings as planned."
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                showSounds = true
            } label: {
                HStack {
                    Image(systemName: relaxation.isPlaying ? "speaker.wave.2.fill" : "headphones")
                        .accessibilityHidden(true)
                    if let current = relaxation.current, relaxation.isPlaying {
                        Text(current.title)
                        if relaxation.timerEnd != nil {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(verbatim: "· \(relaxation.remainingTimerText ?? "")")
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white.opacity(0.5))
                            }
                        }
                    } else {
                        Text("Relaxing sounds")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("night.sounds")

            HoldToStopButton {
                Task { await model.stopTracking() }
            }
        }
    }

    private var busyOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text(tracking.phase == .starting ? LocalizedStringKey("Starting the night…") : LocalizedStringKey("Analysing your night…"))
                .font(.headline)
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .accessibilityElement(children: .combine)
    }

    private var dimOverlay: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Formatters.time(isSimulated ? (tracking.simulatedNow ?? context.date) : context.date))
                    .font(.system(size: 44, weight: .ultraLight, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.22))
            }
        }
        .onTapGesture { registerInteraction() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Night screen dimmed"))
        .accessibilityHint(Text("Double-tap to show the controls."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { registerInteraction() }
        .transition(.opacity)
    }

    // MARK: - Dimming

    private func registerInteraction() {
        lastInteraction = Date()
        if dimmed { dimmed = false }
    }

    private func dimLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard settings.dimNightScreen, !isBusy, !showSounds else { continue }
            if !dimmed && Date().timeIntervalSince(lastInteraction) > 20 {
                dimmed = true
            }
        }
    }
}

private struct NightStat: View {
    let title: LocalizedStringKey
    var value: String?
    var text: LocalizedStringKey?
    let symbol: String

    init(title: LocalizedStringKey, value: String, symbol: String) {
        self.title = title
        self.value = value
        self.text = nil
        self.symbol = symbol
    }

    init(title: LocalizedStringKey, text: LocalizedStringKey, symbol: String) {
        self.title = title
        self.value = nil
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Group {
                if let value {
                    Text(verbatim: value)
                } else if let text {
                    Text(text)
                }
            }
            .font(.headline)
            .foregroundStyle(Color.white.opacity(0.85))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Live sound level relative to the room's noise floor.
private struct LevelMeter: View {
    let level: LevelReading?

    private let segments = 24

    var body: some View {
        let above = max(0, (level?.decibels ?? -160) - (level?.noiseFloor ?? 0))
        let lit = level == nil ? 0 : min(segments, Int((above / 30) * Double(segments)) + 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { index in
                    Capsule()
                        .fill(index < lit ? color(for: index) : Color.white.opacity(0.08))
                        .frame(height: 10)
                }
            }
            .animation(.easeOut(duration: 0.25), value: lit)
            Text(level == nil ? LocalizedStringKey("Waiting for sound…") : LocalizedStringKey("Sound level in the room"))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sound level"))
        .accessibilityValue(Text(verbatim: level.map { "\(Int($0.decibels.rounded())) dBFS" } ?? "–"))
    }

    private func color(for index: Int) -> Color {
        let fraction = Double(index) / Double(segments)
        if fraction > 0.75 { return Theme.negative }
        if fraction > 0.45 { return Theme.accent }
        return Theme.positive.opacity(0.8)
    }
}

/// Press and hold to stop; VoiceOver users get a direct action.
struct HoldToStopButton: View {
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var completions = 0
    private let duration = 1.2

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.08))
            GeometryReader { proxy in
                Capsule()
                    .fill(Theme.accent.opacity(0.45))
                    .frame(width: max(0, proxy.size.width * progress))
            }
            Label("Hold to stop", systemImage: "stop.fill")
                .font(.headline)
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(maxWidth: .infinity)
        }
        .frame(height: 58)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 50, perform: {
            progress = 0
            completions += 1
            action()
        }, onPressingChanged: { pressing in
            if pressing {
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        })
        .sensoryFeedback(.success, trigger: completions)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Stop tracking"))
        .accessibilityHint(Text("Ends the night and shows your morning report."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityIdentifier("night.stop")
    }
}
