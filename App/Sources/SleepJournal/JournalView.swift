import SwiftData
import SwiftUI
import SleepCore

/// Which night a journal editor is open for.
struct JournalRoute: Identifiable, Hashable {
    let night: Date
    var id: Date { night }
}

/// Morning journal: how the night felt and what happened the day before.
struct JournalView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \JournalEntryRecord.night, order: .reverse) private var entries: [JournalEntryRecord]
    @State private var route: JournalRoute?

    private var lastNight: Date {
        StatisticsCalculator.nightDate(for: Date(), calendar: .current)
    }

    private var hasEntryForLastNight: Bool {
        entries.contains { $0.night == lastNight }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.spacing) {
                promptCard
                if entries.isEmpty {
                    Card {
                        EmptyStateView(
                            symbol: "book.closed",
                            title: "No entries yet",
                            message: "Write a few words in the morning. After a week SleepFlow can show which habits go with your best nights."
                        )
                    }
                } else {
                    ForEach(entries) { entry in
                        Button {
                            route = JournalRoute(night: entry.night)
                        } label: {
                            JournalEntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("journal.entry")
                    }
                }
            }
            .padding(Theme.padding)
        }
        .background(NightBackground())
        .navigationTitle("Journal")
        .demoBanner(model.isDemo)
        .sheet(item: $route) { route in
            JournalEditorView(night: route.night)
                .environment(model)
        }
    }

    private var promptCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("How was your night?", systemImage: "sun.horizon")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Rate how rested you feel and tick what happened yesterday. It takes half a minute.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    route = JournalRoute(night: lastNight)
                } label: {
                    Text(hasEntryForLastNight ? LocalizedStringKey("Edit last night's entry") : LocalizedStringKey("Write about last night"))
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("journal.new")
            }
        }
    }
}

struct JournalEntryRow: View {
    let entry: JournalEntryRecord

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Formatters.dayAndDate(entry.night))
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    if let score = entry.session?.score {
                        Pill(text: "Score \(score)", symbol: "moon.zzz", tint: Theme.color(for: score))
                    }
                }
                HStack(spacing: 8) {
                    MiniRating(symbol: "bed.double", label: "Rested", value: entry.feeling)
                    MiniRating(symbol: "bolt", label: "Energy", value: entry.energy)
                    MiniRating(symbol: "face.smiling", label: "Mood", value: entry.mood)
                    MiniRating(symbol: "waveform.path.ecg", label: "Stress", value: entry.stress)
                }
                if !entry.factors.isEmpty {
                    FactorTags(factors: entry.factors)
                }
                if !entry.notes.isEmpty {
                    Text(entry.notes)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct MiniRating: View {
    let symbol: String
    let label: LocalizedStringKey
    let value: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(verbatim: "\(value)/5")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceRaised))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(value) of 5"))
    }
}

/// Compact, wrapping list of logged factors.
struct FactorTags: View {
    let factors: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(factors, id: \.self) { raw in
                    HStack(spacing: 4) {
                        Image(systemName: LifestyleFactor.symbol(forRaw: raw))
                            .accessibilityHidden(true)
                        LifestyleFactor.label(forRaw: raw)
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.surfaceRaised))
                }
            }
        }
    }
}

/// Create or edit the entry of one night. Nothing is stored until the user taps Save.
struct JournalEditorView: View {
    let night: Date

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var feeling = 3
    @State private var energy = 3
    @State private var mood = 3
    @State private var stress = 3
    @State private var notes = ""
    @State private var factors: Set<String> = []
    @State private var exists = false
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Night of \(Formatters.dayAndDate(night))")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Rate the morning after, and tick what happened during the day before.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.surface)

                Section("This morning") {
                    RatingRow(title: "How rested do you feel?", low: "Tired", high: "Rested", value: $feeling)
                    RatingRow(title: "Energy", low: "Low", high: "High", value: $energy)
                    RatingRow(title: "Mood", low: "Low", high: "Good", value: $mood)
                    RatingRow(title: "Stress", low: "Calm", high: "Stressed", value: $stress)
                }
                .listRowBackground(Theme.surface)

                Section("The day before") {
                    FactorPicker(selection: $factors)
                }
                .listRowBackground(Theme.surface)

                Section("Notes") {
                    TextField("Anything worth remembering?", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("journal.notes")
                }
                .listRowBackground(Theme.surface)

                if exists {
                    Section {
                        Button("Delete entry", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightBackground())
            .navigationTitle("Journal entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("journal.save")
                }
            }
            .confirmationDialog("Delete this journal entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let entry = model.store.journalEntry(forNight: night, demo: model.isDemo, create: false) else { return }
        feeling = entry.feeling
        energy = entry.energy
        mood = entry.mood
        stress = entry.stress
        notes = entry.notes
        factors = Set(entry.factors)
        exists = true
    }

    private func save() {
        guard let entry = model.store.journalEntry(forNight: night, demo: model.isDemo, create: true) else {
            dismiss()
            return
        }
        entry.feeling = feeling
        entry.energy = energy
        entry.mood = mood
        entry.stress = stress
        entry.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // Known factors in a stable order, then any unknown values that were already stored.
        let known = LifestyleFactor.allCases.map(\.rawValue).filter { factors.contains($0) }
        let unknown = factors.filter { LifestyleFactor(rawValue: $0) == nil }.sorted()
        entry.factors = known + unknown
        entry.updatedAt = Date()
        model.store.saveJournal(demo: model.isDemo)
        dismiss()
    }

    private func delete() {
        if let entry = model.store.journalEntry(forNight: night, demo: model.isDemo, create: false) {
            model.store.delete(entry, demo: model.isDemo)
        }
        dismiss()
    }
}

/// 1–5 scale with large touch targets. VoiceOver users adjust it with swipe up/down.
struct RatingRow: View {
    let title: LocalizedStringKey
    let low: LocalizedStringKey
    let high: LocalizedStringKey
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { level in
                    Button {
                        value = level
                    } label: {
                        Text(verbatim: "\(level)")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(level == value ? Theme.accentText : Theme.textSecondary)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(level == value ? Theme.accent : Theme.surfaceRaised)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.15), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("\(value) of 5"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(5, value + 1)
            case .decrement: value = max(1, value - 1)
            @unknown default: break
            }
        }
    }
}

struct FactorPicker: View {
    @Binding var selection: Set<String>

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(LifestyleFactor.allCases) { factor in
                let selected = selection.contains(factor.rawValue)
                Button {
                    if selected {
                        selection.remove(factor.rawValue)
                    } else {
                        selection.insert(factor.rawValue)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: factor.symbol)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(factor.title)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(selected ? Theme.accentText : Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selected ? Theme.accent : Theme.surfaceRaised)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("factor.\(factor.rawValue)")
            }
        }
        .padding(.vertical, 4)
    }
}
