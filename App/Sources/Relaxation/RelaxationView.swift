import SwiftUI

/// Soundscapes with a sleep timer, and guided breathing.
struct RelaxationView: View {
    /// Shown as a sheet on the night screen: sounds only.
    var compact = false

    @Environment(AppModel.self) private var model
    @Environment(RelaxationController.self) private var relaxation

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                NowPlayingCard()
                SectionTitle(title: "Sounds")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Soundscape.allCases) { soundscape in
                        SoundscapeTile(
                            soundscape: soundscape,
                            playing: relaxation.isPlaying && relaxation.current == soundscape
                        ) {
                            relaxation.toggle(soundscape)
                        }
                    }
                }
                if let error = relaxation.errorMessage {
                    Text(verbatim: error)
                        .font(.footnote)
                        .foregroundStyle(Theme.negative)
                }
                Text("All sounds are generated live on your iPhone – no recordings and no streaming.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    SectionTitle(title: "Breathing")
                        .padding(.top, 8)
                    ForEach(BreathingPattern.all) { pattern in
                        NavigationLink {
                            BreathingView(pattern: pattern)
                        } label: {
                            BreathingRow(pattern: pattern)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("breathing.\(pattern.id)")
                    }
                }
            }
            .padding(Theme.padding)
        }
        .background(NightBackground())
        .navigationTitle("Relax")
        .demoBanner(model.isDemo && !compact)
    }
}

private struct NowPlayingCard: View {
    @Environment(RelaxationController.self) private var relaxation

    var body: some View {
        @Bindable var relaxation = relaxation
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: relaxation.isPlaying ? (relaxation.current?.symbol ?? "speaker.wave.2.fill") : "headphones")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if let current = relaxation.current, relaxation.isPlaying {
                            Text(current.title)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Playing")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("Choose a sound")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text("With a sleep timer it fades out by itself.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    if relaxation.isPlaying {
                        Button {
                            relaxation.stop()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Stop sound"))
                        .accessibilityIdentifier("relax.stop")
                    }
                }
                Slider(value: $relaxation.volume, in: 0...1) {
                    Text("Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(Theme.textTertiary)
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .tint(Theme.accent)
                HStack {
                    Text("Sleep timer")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    TimerMenu()
                }
            }
        }
    }
}

private struct TimerMenu: View {
    @Environment(RelaxationController.self) private var relaxation

    var body: some View {
        Menu {
            Button {
                relaxation.setTimer(minutes: nil)
            } label: {
                if relaxation.timerMinutes == nil {
                    Label("No timer", systemImage: "checkmark")
                } else {
                    Text("No timer")
                }
            }
            ForEach(RelaxationController.timerOptions, id: \.self) { minutes in
                Button {
                    relaxation.setTimer(minutes: minutes)
                } label: {
                    if relaxation.timerMinutes == minutes {
                        Label(Formatters.minutes(TimeInterval(minutes * 60)), systemImage: "checkmark")
                    } else {
                        Text(verbatim: Formatters.minutes(TimeInterval(minutes * 60)))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .accessibilityHidden(true)
                if relaxation.timerEnd != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(verbatim: relaxation.remainingTimerText ?? "")
                            .monospacedDigit()
                    }
                } else if let minutes = relaxation.timerMinutes {
                    Text(verbatim: Formatters.minutes(TimeInterval(minutes * 60)))
                } else {
                    Text("Off")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
        }
        .accessibilityLabel(Text("Sleep timer"))
        .accessibilityIdentifier("relax.timer")
    }
}

private struct SoundscapeTile: View {
    let soundscape: Soundscape
    let playing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: soundscape.symbol)
                        .font(.title2)
                        .foregroundStyle(playing ? Theme.accentText : Theme.accent)
                        .accessibilityHidden(true)
                    Spacer()
                    if playing {
                        Image(systemName: "speaker.wave.2.fill")
                            .symbolEffect(.variableColor.iterative, isActive: playing)
                            .foregroundStyle(Theme.accentText)
                            .accessibilityHidden(true)
                    }
                }
                Text(soundscape.title)
                    .font(.headline)
                    .foregroundStyle(playing ? Theme.accentText : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(soundscape.subtitle)
                    .font(.caption)
                    .foregroundStyle(playing ? Theme.accentText.opacity(0.75) : Theme.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                    .fill(playing ? Theme.accent : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(playing ? .isSelected : [])
        .accessibilityHint(playing ? Text("Double-tap to stop.") : Text("Double-tap to play."))
        .accessibilityIdentifier("soundscape.\(soundscape.rawValue)")
    }
}

private struct BreathingRow: View {
    let pattern: BreathingPattern

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "wind")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(pattern.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(pattern.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .combine)
    }
}

/// Animated breathing guide. The circle grows on the in-breath and shrinks on the out-breath.
struct BreathingView: View {
    let pattern: BreathingPattern

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var running = false
    @State private var startDate = Date()
    @State private var minutes = 3

    var body: some View {
        VStack(spacing: 26) {
            Text(pattern.detail)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { context in
                let elapsed = running ? context.date.timeIntervalSince(startDate) : 0
                let state = pattern.phase(at: elapsed)
                BreathingCircle(
                    phase: running ? state.phase : nil,
                    progress: state.progress,
                    remaining: state.remaining,
                    reduceMotion: reduceMotion
                )
                .sensoryFeedback(.impact(weight: .light), trigger: running ? state.phase : nil)
            }
            .frame(height: 300)
            if running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Double(minutes * 60) - context.date.timeIntervalSince(startDate))
                    Text("Time left: \(BreathingView.minutesAndSeconds(left))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Picker("Duration", selection: $minutes) {
                    ForEach([1, 3, 5, 10], id: \.self) { value in
                        Text(verbatim: Formatters.minutes(TimeInterval(value * 60))).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }
            Button {
                if running {
                    running = false
                } else {
                    startDate = Date()
                    running = true
                }
            } label: {
                Text(running ? LocalizedStringKey("Stop") : LocalizedStringKey("Start"))
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("breathing.toggle")
        }
        .padding(Theme.padding)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NightBackground())
        .navigationTitle(Text(pattern.title))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: running) {
            guard running else { return }
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            if !Task.isCancelled { running = false }
        }
        .onDisappear { running = false }
    }

    /// "2:05"
    static func minutesAndSeconds(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        let rest = total % 60
        return "\(total / 60):" + (rest < 10 ? "0" : "") + "\(rest)"
    }
}

private struct BreathingCircle: View {
    let phase: BreathingPattern.Phase?
    let progress: Double
    let remaining: Double
    let reduceMotion: Bool

    private var scale: CGFloat {
        guard let phase, !reduceMotion else { return 0.8 }
        let eased = 0.5 - cos(progress * .pi) / 2
        switch phase {
        case .inhale: return 0.55 + 0.45 * eased
        case .hold: return 1
        case .exhale: return 1 - 0.45 * eased
        case .rest: return 0.55
        }
    }

    private var label: LocalizedStringKey {
        switch phase {
        case .inhale: return "Breathe in"
        case .hold: return "Hold"
        case .exhale: return "Breathe out"
        case .rest: return "Rest"
        case nil: return "Ready"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(0.10))
                .scaleEffect(scale * 1.12)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.accentSoft, Theme.accent.opacity(0.75)],
                        center: .center,
                        startRadius: 4,
                        endRadius: 140
                    )
                )
                .scaleEffect(scale)
            VStack(spacing: 4) {
                Text(label)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if phase != nil {
                    Text(verbatim: "\(Int(remaining.rounded(.up)))")
                        .font(.display(.largeTitle))
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: 130)
            .foregroundStyle(Theme.accentText)
        }
        .frame(width: 260, height: 260)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}
