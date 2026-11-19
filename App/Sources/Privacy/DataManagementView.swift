import SwiftData
import SwiftUI
import SleepCore

/// Export everything, delete single nights, or erase all personal data.
struct DataManagementView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \SleepSessionRecord.start, order: .reverse) private var sessions: [SleepSessionRecord]
    @Query private var journal: [JournalEntryRecord]

    @State private var exportURLs: [URL] = []
    @State private var exportError: String?
    @State private var confirmDeleteAll = false
    @State private var deletedAll = false

    var body: some View {
        List {
            Section {
                LabeledContent("Nights") { Text(verbatim: "\(sessions.count)") }
                LabeledContent("Journal entries") { Text(verbatim: "\(journal.count)") }
                LabeledContent("Sound clips") {
                    Text(ByteCountFormatter.string(fromByteCount: FileLocations.clipsSize(), countStyle: .file))
                }
            } header: {
                Text(model.isDemo ? LocalizedStringKey("Demo data") : LocalizedStringKey("Stored on this iPhone"))
            }
            .listRowBackground(Theme.surface)

            Section {
                Button {
                    createExport()
                } label: {
                    Label("Create export", systemImage: "doc.badge.arrow.up")
                }
                .accessibilityIdentifier("data.export")
                if !exportURLs.isEmpty {
                    ShareLink(items: exportURLs) {
                        Label("Share export files", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("data.share")
                }
                if let exportError {
                    Text(verbatim: exportError)
                        .font(.footnote)
                        .foregroundStyle(Theme.negative)
                }
            } header: {
                Text("Export")
            } footer: {
                Text("A JSON file with every night in full detail and a CSV file with one line per night, for spreadsheets. You decide where they go.")
            }
            .listRowBackground(Theme.surface)

            Section {
                if sessions.isEmpty {
                    Text("No nights stored.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(sessions) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Formatters.dayAndDate(record.start))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(verbatim: "\(Formatters.timeRange(record.start, record.end)) · \(Formatters.duration(record.totalSleep))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Text(verbatim: "\(record.score)")
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundStyle(Theme.color(for: record.score))
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onDelete(perform: deleteNights)
                }
            } header: {
                Text("Nights")
            } footer: {
                Text("Swipe left on a night to delete it.")
            }
            .listRowBackground(Theme.surface)

            if !model.isDemo {
                Section {
                    Button("Delete all my data", role: .destructive) {
                        confirmDeleteAll = true
                    }
                    .accessibilityIdentifier("data.deleteAll")
                    if deletedAll {
                        Label("All personal data has been deleted.", systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.positive)
                    }
                } footer: {
                    Text("Deletes every night, the journal, all sound clips and the diagnostics log. Your settings are kept. This cannot be undone.")
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle("Export and delete data")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all your data?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                model.deleteAllPersonalData()
                exportURLs = []
                deletedAll = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every night, journal entry and sound clip is removed from this iPhone. This cannot be undone.")
        }
    }

    private func createExport() {
        exportError = nil
        do {
            exportURLs = try DataExporter.export(store: model.store, demo: model.isDemo)
        } catch {
            exportURLs = []
            exportError = error.localizedDescription
        }
    }

    private func deleteNights(at offsets: IndexSet) {
        let records = offsets.map { sessions[$0] }
        for record in records {
            model.store.delete(record, demo: model.isDemo)
        }
    }
}
