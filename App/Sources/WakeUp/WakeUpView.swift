import SwiftUI
import SleepCore

/// Shown while the alarm rings: a slow sunrise, the time, and large Stop / Snooze buttons.
struct WakeUpView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(TrackingController.self) private var tracking
    @Environment(AlarmCoordinator.self) private var alarms
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var risen = false
    @State private var stopping = false

    /// A simulated night reached its alarm: nothing rings in the system, the app plays a preview.
    private var isSimulatedAlarm: Bool { !alarms.isRinging && tracking.active?.isSimulated == true }

    var body: some View {
        ZStack {
            sky
            VStack(spacing: 18) {
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Formatters.time(isSimulatedAlarm ? (tracking.simulatedNow ?? context.date) : context.date))
                        .font(.system(size: 80, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Text("Good morning")
                    .font(.display(.title, weight: .semibold))
                    .foregroundStyle(.white)
                if let reason = tracking.smartWakeReason {
                    Text(reason.title)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                if isSimulatedAlarm {
                    Pill(text: "Simulated alarm", symbol: "theatermasks", tint: .white)
                }
                Spacer()
                VStack(spacing: 12) {
                    Button {
                        stop()
                    } label: {
                        Label("Stop", systemImage: "sun.max.fill")
                    }
                    .buttonStyle(.primary)
                    .disabled(stopping)
                    .accessibilityIdentifier("wakeup.stop")

                    if alarms.isRinging {
                        Button {
                            Task { await alarms.snooze() }
                        } label: {
                            Text("Snooze \(settings.alarm.snoozeMinutes) min")
                        }
                        .buttonStyle(.secondary)
                        .disabled(stopping)
                        .accessibilityIdentifier("wakeup.snooze")
                    }
                }
                .padding(.horizontal, Theme.padding)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            if reduceMotion {
                risen = true
            } else {
                withAnimation(.easeOut(duration: 8)) { risen = true }
            }
            if isSimulatedAlarm && !AppEnvironment.isUITesting {
                alarms.preview(soundID: settings.alarm.soundID)
            }
        }
        .onDisappear {
            // The in-app preview of a simulated alarm must not outlive this screen.
            if !alarms.isRinging { alarms.stopPreview() }
        }
    }

    private var sky: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0x0B1030), Color(hex: 0x3A2A6B), Color(hex: 0xE0704A), Color(hex: 0xFFB25B)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(risen ? 1 : 0.35)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: 0xFFE2A8), Color(hex: 0xFFB25B).opacity(0.5), .clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: proxy.size.width * 0.55
                        )
                    )
                    .frame(width: proxy.size.width * 1.1, height: proxy.size.width * 1.1)
                    .position(x: proxy.size.width / 2, y: risen ? proxy.size.height * 0.92 : proxy.size.height * 1.25)
            }
            .background(Color(hex: 0x060A18))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func stop() {
        stopping = true
        if alarms.isRinging {
            // Ends the alarm for this morning; the coordinator then ends the night.
            alarms.stopRinging()
        } else {
            alarms.stopPreview()
            let key = tracking.active?.occurrence?.key ?? "simulated"
            Task { await tracking.wakeConfirmed(occurrenceKey: key) }
        }
    }
}
