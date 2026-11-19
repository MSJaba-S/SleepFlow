import SwiftUI
import SleepCore

/// Short first-run flow: benefits, sleep goal, tracking method, wake-up habit, permissions.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(PermissionCenter.self) private var permissions

    @State private var page = 0
    private let pageCount = 6

    var body: some View {
        ZStack {
            NightBackground()
            VStack(spacing: 0) {
                ProgressDots(count: pageCount, current: page)
                    .padding(.top, 12)
                TabView(selection: $page) {
                    WelcomePage().tag(0)
                    GoalPage().tag(1)
                    MethodPage().tag(2)
                    WakePage().tag(3)
                    MicrophonePage().tag(4)
                    AlarmPermissionPage().tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)

                Button {
                    advance()
                } label: {
                    Text(page == pageCount - 1 ? LocalizedStringKey("Start using SleepFlow") : LocalizedStringKey("Continue"))
                }
                .buttonStyle(.primary)
                .padding(.horizontal, Theme.padding)
                .padding(.bottom, 12)
                .accessibilityIdentifier(page == pageCount - 1 ? "onboarding.finish" : "onboarding.continue")
            }
        }
    }

    private func advance() {
        if page < pageCount - 1 {
            page += 1
        } else {
            settings.hasCompletedOnboarding = true
            model.alarmChanged()
        }
    }
}

private struct ProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Theme.accent : Theme.surfaceRaised)
                    .frame(width: index == current ? 22 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.35), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(current + 1) of \(count)"))
    }
}

private struct OnboardingPage<Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 36)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.display(.largeTitle))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            .padding(.horizontal, Theme.padding)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}

private struct WelcomePage: View {
    var body: some View {
        OnboardingPage(symbol: "moon.stars", title: "Sleep better with SleepFlow", subtitle: "SleepFlow listens to your night, estimates how you slept and wakes you at a good moment.") {
            VStack(alignment: .leading, spacing: 18) {
                InfoRow(symbol: "waveform", title: "Tracks your night", text: "Sound or movement analysis on your iPhone shows when you were awake, in light or in deep sleep.")
                InfoRow(symbol: "alarm", title: "Smart Alarm", text: "Wakes you in a light phase – at a set time, or after a power nap or whole sleep cycles counted from when you fall asleep.")
                InfoRow(symbol: "chart.line.uptrend.xyaxis", title: "Understand your habits", text: "Morning reports, a Sleep Score and long-term statistics.")
                InfoRow(symbol: "lock.shield", title: "Private by design", text: "Everything is processed and stored on your iPhone. No account, no cloud, no tracking.")
            }
            .padding(.top, 8)
        }
    }
}

private struct GoalPage: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        OnboardingPage(symbol: "target", title: "Your sleep goal", subtitle: "Most adults need 7–9 hours. Your Sleep Score measures duration against your own goal.") {
            Card {
                VStack(spacing: 14) {
                    Text(Formatters.duration(settings.sleepGoal))
                        .font(.display(.largeTitle))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("onboarding.goalValue")
                    Stepper(value: $settings.sleepGoalMinutes, in: 300...660, step: 15) {
                        Text("Sleep goal")
                    }
                    .accessibilityIdentifier("onboarding.goalStepper")
                }
            }
        }
    }
}

private struct MethodPage: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        OnboardingPage(symbol: "bed.double", title: "How should SleepFlow listen?", subtitle: "You can change this before any night.") {
            VStack(spacing: 12) {
                ForEach(TrackingMethod.allCases, id: \.self) { method in
                    MethodCard(method: method, selected: settings.trackingMethod == method) {
                        settings.trackingMethod = method
                    }
                }
            }
        }
    }
}

struct MethodCard: View {
    let method: TrackingMethod
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: method.symbol)
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text(method.title)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                Text(method.summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                Text(method.placement)
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.leading)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("method.\(method.rawValue)")
    }
}

private struct WakePage: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        OnboardingPage(symbol: "sunrise", title: "When do you want to wake up?", subtitle: "With Smart Alarm, SleepFlow looks for a light phase in the window before this time.") {
            Card {
                AlarmTimeEditor(compact: true)
            }
        }
    }
}

private struct MicrophonePage: View {
    @Environment(PermissionCenter.self) private var permissions
    @Environment(AppSettings.self) private var settings

    var body: some View {
        OnboardingPage(symbol: "mic", title: "Your sound stays on your phone", subtitle: "For sound tracking SleepFlow needs the microphone during the night.") {
            VStack(alignment: .leading, spacing: 16) {
                InfoRow(symbol: "cpu", title: "Analysed on your iPhone", text: "Sound is turned into numbers (levels, frequencies) in real time. Nothing is uploaded.")
                InfoRow(symbol: "waveform.slash", title: "No recordings by default", text: "Short clips of snoring or talking are only saved if you switch it on in Settings – and you can delete them at any time.")
                InfoRow(symbol: "mic.badge.xmark", title: "Prefer no microphone?", text: "Choose movement tracking instead. Everything else works the same.")
                permissionButton
            }
        }
    }

    @ViewBuilder
    private var permissionButton: some View {
        switch permissions.microphone {
        case .granted:
            Label("Microphone allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.positive)
                .font(.headline)
        case .denied:
            PermissionNotice(title: "Microphone access is off", message: "Turn it on in Settings, or use movement tracking.") {
                permissions.openSystemSettings()
            }
        default:
            Button("Allow microphone") {
                Task { await permissions.requestMicrophone() }
            }
            .buttonStyle(.secondary)
            .accessibilityIdentifier("onboarding.allowMicrophone")
        }
    }
}

private struct AlarmPermissionPage: View {
    @Environment(PermissionCenter.self) private var permissions
    @Environment(AlarmCoordinator.self) private var alarms

    var body: some View {
        OnboardingPage(symbol: "alarm", title: "An alarm you can rely on", subtitle: "SleepFlow schedules a system alarm for your wake-up time. The Smart Alarm can only ring earlier, never later.") {
            VStack(alignment: .leading, spacing: 16) {
                if PermissionCenter.alarmKitSupported {
                    InfoRow(symbol: "bell.badge", title: "Rings in Silent mode", text: "SleepFlow uses iOS alarms (AlarmKit). They ring even with the phone locked, muted or in Focus.")
                } else {
                    InfoRow(symbol: "bell.badge", title: "Notification alarm", text: "On this iOS version the alarm uses notifications with sound. Keep Silent mode and Focus in mind.")
                }
                InfoRow(symbol: "doc.text.magnifyingglass", title: "Morning report", text: "Notifications are also used for backup alerts.")
                Button("Allow alarms and notifications") {
                    Task {
                        await alarms.requestAuthorization()
                        await permissions.refresh()
                    }
                }
                .buttonStyle(.secondary)
                .accessibilityIdentifier("onboarding.allowAlarms")
                if permissions.alarms == .granted || permissions.notifications == .granted {
                    Label("Alarm permission set", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.positive)
                        .font(.headline)
                }
            }
        }
    }
}
