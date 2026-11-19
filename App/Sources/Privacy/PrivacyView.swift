import SwiftUI

/// Plain-language privacy information. Everything here describes what the code actually does.
struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                PrivacySection(
                    symbol: "iphone",
                    title: "Everything stays on your iPhone",
                    text: "SleepFlow has no account, no server, no analytics, no advertising and no tracking. Nothing you record is sent anywhere. The developer has no access to your data."
                )
                PrivacySection(
                    symbol: "waveform",
                    title: "Microphone",
                    text: "Sound is analysed in memory while it is recorded and then discarded. Only results such as sound levels and detected events (for example snoring at 02:14) are saved. Audio is stored only if you turn on sound clips, and then only short clips on this iPhone."
                )
                PrivacySection(
                    symbol: "figure.roll",
                    title: "Movement",
                    text: "With movement tracking SleepFlow reads the phone's motion sensor and stores how much you moved per 30 seconds – nothing else."
                )
                PrivacySection(
                    symbol: "lock.shield",
                    title: "Storage and protection",
                    text: "Your nights and journal are kept in SleepFlow's private storage and protected by iOS data protection. Sound clips and the recording of a running night are excluded from backups. Your nights are part of your normal iPhone backup, like other app data, but are never synced to iCloud by SleepFlow."
                )
                PrivacySection(
                    symbol: "doc.text.magnifyingglass",
                    title: "Your rights",
                    text: "You can see, export and delete all your data at any time under Settings › Export and delete data – single nights or everything at once. Deleting the app also deletes all data."
                )
                PrivacySection(
                    symbol: "hand.raised",
                    title: "Permissions",
                    text: "Microphone, notifications and alarms are only used for what is described in the app. You can withdraw them at any time in the iPhone Settings app."
                )
                PrivacySection(
                    symbol: "cross.case",
                    title: "Not a medical device",
                    text: "SleepFlow estimates sleep from sound and movement. The results are not a diagnosis. If you are worried about your sleep, snoring or breathing, talk to a doctor."
                )
            }
            .padding(Theme.padding)
        }
        .background(NightBackground())
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacySection: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
