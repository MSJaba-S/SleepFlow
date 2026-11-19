import SwiftUI
import SleepCore

/// Wake time, Smart Alarm window and repeat days. Used in onboarding and settings.
struct AlarmTimeEditor: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    var compact = false

    @State private var time = Date()
    @State private var loaded = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            if !compact {
                Toggle("Alarm", isOn: $settings.alarm.isEnabled)
                    .onChange(of: settings.alarm.isEnabled) { _, _ in model.alarmChanged() }
                    .accessibilityIdentifier("alarm.enabled")
            }
            DatePicker("Wake-up time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)
                .onChange(of: time) { _, newValue in
                    guard loaded else { return }
                    let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                    settings.alarm.hour = components.hour ?? 7
                    settings.alarm.minute = components.minute ?? 0
                    model.alarmChanged()
                }
                .accessibilityIdentifier("alarm.time")

            Toggle("Smart Alarm", isOn: $settings.alarm.isSmartEnabled)
                .onChange(of: settings.alarm.isSmartEnabled) { _, _ in model.alarmChanged() }
                .accessibilityIdentifier("alarm.smart")

            if settings.alarm.isSmartEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wake-up window")
                        .font(.subheadline.weight(.semibold))
                    Picker("Wake-up window", selection: $settings.alarm.smartWindowMinutes) {
                        ForEach(AlarmSettings.allowedWindows, id: \.self) { minutes in
                            Text(Formatters.minutes(TimeInterval(minutes * 60))).tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.alarm.smartWindowMinutes) { _, _ in model.alarmChanged() }
                    .accessibilityIdentifier("alarm.window")
                    Text(windowExplanation)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Repeat")
                    .font(.subheadline.weight(.semibold))
                WeekdayPicker(selection: $settings.alarm.weekdays)
                    .onChange(of: settings.alarm.weekdays) { _, _ in model.alarmChanged() }
                Text(settings.alarm.weekdays.isEmpty ? LocalizedStringKey("Rings once, at the next occurrence.") : LocalizedStringKey("Rings on the selected days."))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .onAppear {
            var components = DateComponents()
            components.hour = settings.alarm.hour
            components.minute = settings.alarm.minute
            time = Calendar.current.date(from: components) ?? Date()
            DispatchQueue.main.async { loaded = true }
        }
    }

    private var windowExplanation: String {
        var components = DateComponents()
        components.hour = settings.alarm.hour
        components.minute = settings.alarm.minute
        let deadline = Calendar.current.date(from: components) ?? Date()
        let start = deadline.addingTimeInterval(-settings.alarm.effectiveWindow)
        return String(localized: "SleepFlow looks for light sleep between \(Formatters.time(start)) and \(Formatters.time(deadline)). At \(Formatters.time(deadline)) the alarm always rings.")
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Weekday>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Weekday.mondayFirst, id: \.self) { day in
                let selected = selection.contains(day)
                Button {
                    if selected { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(WeekdayPicker.symbol(for: day))
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
                        .background(Circle().fill(selected ? Theme.accent : Theme.surfaceRaised))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(WeekdayPicker.name(for: day)))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("weekday.\(day.rawValue)")
            }
        }
    }

    static func symbol(for day: Weekday) -> String {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let index = day.rawValue - 1
        return index < symbols.count ? symbols[index] : "?"
    }

    static func name(for day: Weekday) -> String {
        let names = Calendar.current.standaloneWeekdaySymbols
        let index = day.rawValue - 1
        return index < names.count ? names[index] : ""
    }
}

struct AlarmSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AlarmCoordinator.self) private var alarms
    @Environment(AppModel.self) private var model
    @Environment(PermissionCenter.self) private var permissions

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                AlarmTimeEditor()
                    .padding(.vertical, 6)
            }
            .listRowBackground(Theme.surface)

            Section("Sound") {
                ForEach(AlarmSound.all) { sound in
                    Button {
                        settings.alarm.soundID = sound.id
                        alarms.preview(soundID: sound.id)
                        model.alarmChanged()
                    } label: {
                        HStack {
                            Text(sound.title)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if settings.alarm.soundID == sound.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(settings.alarm.soundID == sound.id ? .isSelected : [])
                }
                Toggle("Vibration", isOn: $settings.alarm.vibrationEnabled)
                    .onChange(of: settings.alarm.vibrationEnabled) { _, _ in model.alarmChanged() }
            }
            .listRowBackground(Theme.surface)

            Section("Snooze") {
                Picker("Snooze length", selection: $settings.alarm.snoozeMinutes) {
                    ForEach(AlarmSettings.allowedSnooze, id: \.self) { minutes in
                        Text(Formatters.minutes(TimeInterval(minutes * 60))).tag(minutes)
                    }
                }
                .onChange(of: settings.alarm.snoozeMinutes) { _, _ in model.alarmChanged() }
            }
            .listRowBackground(Theme.surface)

            Section {
                HStack {
                    Text("Alarm system")
                    Spacer()
                    Text(alarms.activeBackendName == "AlarmKit" ? LocalizedStringKey("iOS alarm (AlarmKit)") : LocalizedStringKey("Notifications"))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let next = alarms.nextOccurrence {
                    HStack {
                        Text("Next alarm")
                        Spacer()
                        Text(next.deadline.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if alarms.authorization == .denied {
                    PermissionNotice(title: "Alarms are not allowed", message: "Without permission SleepFlow cannot wake you. Allow alarms in Settings.") {
                        permissions.openSystemSettings()
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                Text(alarms.ringsThroughSilentMode
                     ? LocalizedStringKey("The alarm is an iOS alarm: it rings with the phone locked, in Silent mode and in Focus. Vibration follows your iPhone's sound settings.")
                     : LocalizedStringKey("The alarm is a notification with sound. It follows Silent mode and Focus. If tracking is running, SleepFlow also rings itself."))
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle("Alarm")
        .onDisappear { alarms.stopPreview() }
    }
}
