import Charts
import SwiftData
import SwiftUI
import SleepCore

/// The morning report of one night.
struct ReportView: View {
    let route: ReportRoute

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var record: SleepSessionRecord?
    @State private var session: CompletedSession?
    @State private var missing = false
    @State private var confirmDelete = false
    @State private var journalRoute: JournalRoute?
    @State private var clipPlayer = ClipPlayer()

    var body: some View {
        Group {
            if let session {
                content(session)
            } else if missing {
                EmptyStateView(symbol: "questionmark.folder", title: "This night is no longer available", message: "It may have been deleted.")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(NightBackground())
        .navigationTitle("Morning report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("report.done")
            }
            if record != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete this night", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel(Text("More"))
                    }
                }
            }
        }
        .confirmationDialog("Delete this night?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteNight() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The analysis, the journal link and any saved sound clips of this night are removed from your iPhone.")
        }
        .sheet(item: $journalRoute) { route in
            JournalEditorView(night: route.night)
                .environment(model)
        }
        .task(id: route.sessionID) { load() }
        .onDisappear { clipPlayer.stop() }
    }

    private func content(_ session: CompletedSession) -> some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                ReportHeader(session: session)
                ScoreSummaryCard(session: session)
                KeyMetricsGrid(metrics: session.metrics)
                HypnogramCard(session: session)
                if !session.insights.isEmpty {
                    InsightsCard(insights: session.insights)
                }
                ScoreBreakdownCard(score: session.score)
                if session.wakeUp.deadline != nil {
                    WakeUpCard(wakeUp: session.wakeUp, smart: session.header.smartAlarmEnabled, napPlan: session.header.napPlan)
                }
                ActivityCard(session: session)
                if session.header.method == .microphone {
                    SoundsCard(session: session, clipPlayer: clipPlayer, onDeleteClip: deleteClip)
                }
                SuggestionsCard(suggestions: session.suggestions)
                if session.header.napPlan == nil {
                    JournalPromptCard(night: StatisticsCalculator.nightDate(for: session.header.start, calendar: .current)) { night in
                        journalRoute = JournalRoute(night: night)
                    }
                }
                DataQualityCard(session: session)
                Text("SleepFlow estimates sleep from sound and movement. It is not a medical device and cannot diagnose sleep disorders.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(Theme.padding)
        }
        .accessibilityIdentifier("report.scroll")
    }

    private func load() {
        guard let found = model.store.session(id: route.sessionID, demo: route.demo), let decoded = found.decoded() else {
            missing = true
            return
        }
        record = found
        session = decoded
    }

    private func deleteNight() {
        clipPlayer.stop()
        if let record {
            model.store.delete(record, demo: route.demo)
        }
        dismiss()
    }

    private func deleteClip(_ name: String) {
        clipPlayer.stop()
        guard let record else { return }
        model.store.deleteClip(named: name, in: record, demo: route.demo)
        session = record.decoded()
    }
}

// MARK: - Header and score

private struct ReportHeader: View {
    let session: CompletedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if session.header.napPlan != nil {
                    Text("Nap on \(Formatters.dayAndDate(session.header.start))")
                } else {
                    Text("Night of \(Formatters.dayAndDate(StatisticsCalculator.nightDate(for: session.header.start, calendar: .current)))")
                }
            }
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(Formatters.timeRange(session.header.start, session.end))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Pill(text: session.header.method.title, symbol: session.header.method.symbol, tint: Theme.info)
                if session.header.isSimulated {
                    Pill(text: "Simulated", symbol: "theatermasks", tint: Theme.accentSoft)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScoreSummaryCard: View {
    let session: CompletedSession

    var body: some View {
        Card {
            VStack(spacing: 14) {
                ScoreRing(score: session.score.value, size: 190, lineWidth: 16)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    Text(session.score.quality.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let previous = session.previousScore {
                        ChangeBadge(change: session.score.value - previous)
                    }
                }
                if session.score.lowConfidence {
                    Label("Only part of the night was measured. Treat this score as a rough estimate.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.accentSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.metrics.noSleepDetected {
                    Label("No sleep was detected this night.", systemImage: "moon.zzz")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct KeyMetricsGrid: View {
    let metrics: SleepMetrics

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            StatTile(title: "Time asleep", value: Formatters.duration(metrics.totalSleep), symbol: "bed.double.fill")
            StatTile(title: "Time in bed", value: Formatters.duration(metrics.timeInBed), symbol: "clock", tint: Theme.info)
            StatTile(title: "Sleep efficiency", value: Formatters.percent(metrics.efficiency), symbol: "gauge.with.dots.needle.67percent", tint: Theme.positive)
            StatTile(
                title: "Fell asleep after",
                value: metrics.sleepLatency.map { Formatters.span(minutes: $0 / 60) } ?? "–",
                symbol: "moon.zzz",
                tint: Theme.stageLight
            )
            StatTile(title: "Awake in the night", value: Formatters.duration(metrics.wakeAfterSleepOnset), symbol: "eye", detail: String(localized: "Interruptions: \(metrics.interruptions)"), tint: Theme.stageAwake)
            StatTile(
                title: "Deep sleep",
                value: Formatters.duration(metrics.deepSleep),
                symbol: "water.waves",
                detail: metrics.totalSleep > 0 ? String(localized: "\(Formatters.percent(metrics.deepSleep / metrics.totalSleep)) of your sleep") : nil,
                tint: Theme.stageDeep
            )
        }
    }
}

// MARK: - Hypnogram

private struct HypnogramCard: View {
    let session: CompletedSession

    var body: some View {
        let hypnogram = session.hypnogram
        let asleep = max(1, hypnogram.duration(of: .light) + hypnogram.duration(of: .deep))
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Sleep phases")
                HypnogramChart(hypnogram: hypnogram, start: session.header.start, end: session.end)
                    .frame(height: 170)
                HStack(spacing: 10) {
                    ForEach([SleepStage.awake, .light, .deep], id: \.self) { stage in
                        let duration = hypnogram.duration(of: stage)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Theme.color(for: stage))
                                    .frame(width: 9, height: 9)
                                    .accessibilityHidden(true)
                                Text(stage.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            Text(Formatters.duration(duration))
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            if stage != .awake {
                                Text(Formatters.percent(duration / asleep))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("Phases are estimated from sound and movement every 30 seconds. Light sleep includes dream (REM) sleep, which SleepFlow cannot tell apart.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Awake on top, deep at the bottom; faded where no sensor data was recorded.
struct HypnogramChart: View {
    let hypnogram: Hypnogram
    let start: Date
    let end: Date

    var body: some View {
        Chart(hypnogram.segments) { segment in
            RectangleMark(
                xStart: .value("Start", segment.start),
                xEnd: .value("End", segment.end),
                yStart: .value("Low", HypnogramChart.lower(segment.stage)),
                yEnd: .value("High", HypnogramChart.lower(segment.stage) + 1)
            )
            .foregroundStyle(Theme.color(for: segment.stage).opacity(segment.hasData ? 1 : 0.25))
        }
        .chartXScale(domain: start...max(end, start.addingTimeInterval(60)))
        .chartYScale(domain: 0...3)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.5, 1.5, 2.5]) { value in
                AxisValueLabel {
                    Text(HypnogramChart.label(for: value.as(Double.self) ?? 0))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .accessibilityLabel(Text("Sleep phases through the night"))
    }

    static func lower(_ stage: SleepStage) -> Double {
        switch stage {
        case .awake: return 2
        case .light: return 1
        case .deep: return 0
        }
    }

    static func label(for value: Double) -> LocalizedStringKey {
        if value >= 2 { return "Awake" }
        if value >= 1 { return "Light" }
        return "Deep"
    }
}

// MARK: - Insights and score breakdown

private struct InsightsCard: View {
    let insights: [SleepInsight]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "What affected your night")
                ForEach(insights) { insight in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: insight.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(insight.isPositive ? Theme.positive : Theme.accent)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        insight.text
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct ScoreBreakdownCard: View {
    let score: SleepScore

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "How the score is made")
                Text("Each factor gets 0–100. The Sleep Score is the weighted average, so the points below add up to \(score.value).")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(score.components) { component in
                    ScoreComponentRow(component: component)
                }
                if score.component(.consistency) == nil {
                    Text("Regularity is included once SleepFlow has three earlier nights to compare with.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NavigationLink {
                    ScoreWeightsView()
                } label: {
                    HStack {
                        Text("Change the weighting")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

private struct ScoreComponentRow: View {
    let component: ScoreComponent

    var body: some View {
        let points = component.contribution.formatted(.number.precision(.fractionLength(1)))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(component.factor.title, systemImage: component.factor.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Text(verbatim: "\(Int(component.score))")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.color(for: Int(component.score)))
            }
            ProgressView(value: min(max(component.score, 0), 100), total: 100)
                .tint(Theme.color(for: Int(component.score)))
            HStack {
                Text(verbatim: component.factor.measuredText(component.measuredValue))
                Spacer()
                Text("Weight \(Formatters.percent(component.weight)) · \(points) points")
            }
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Wake-up

private struct WakeUpCard: View {
    let wakeUp: WakeUpRecord
    let smart: Bool
    let napPlan: NapPlan?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: napPlan == nil ? "Wake-up" : "Wake after sleep")
                if let napPlan {
                    napPlan.title
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                }
                if let summary = wakeUp.summary {
                    summary
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if napPlan != nil {
                    if let countedFrom = wakeUp.countedFrom {
                        DetailRow(title: wakeUp.sleepDetected == true ? "Fell asleep" : "Counting started", value: Formatters.time(countedFrom))
                        if wakeUp.sleepDetected != true {
                            Text("No sleep was detected in time, so counting started anyway.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let napSleep = wakeUp.napSleep {
                        DetailRow(title: "Slept before the alarm", value: Formatters.duration(napSleep))
                    }
                    if let deadline = wakeUp.deadline, let windowStart = wakeUp.windowStart {
                        DetailRow(title: "Wake-up window", value: Formatters.timeRange(windowStart, deadline))
                    }
                } else if let deadline = wakeUp.deadline {
                    DetailRow(title: "Alarm time", value: Formatters.time(deadline))
                    if smart, let windowStart = wakeUp.windowStart {
                        DetailRow(title: "Smart Alarm window", value: Formatters.timeRange(windowStart, deadline))
                    }
                }
                if wakeUp.snoozeCount > 0 {
                    DetailRow(title: "Snoozes", value: "\(wakeUp.snoozeCount)")
                }
            }
        }
    }
}

struct DetailRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(verbatim: value)
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Activity and sounds

/// Movement (motion mode) or sound activity (microphone mode) in 10-minute steps.
private struct ActivityCard: View {
    let session: CompletedSession

    private struct Bin: Identifiable {
        let start: Date
        let end: Date
        let value: Double
        var id: Date { start }
    }

    private static let binLength: TimeInterval = 10 * 60

    private var bins: [Bin] {
        let binLength = ActivityCard.binLength
        let useMotion = session.header.method == .motion
        var groups: [Int: [Double]] = [:]
        for epoch in session.epochs {
            let index = Int(epoch.start.timeIntervalSince(session.header.start) / binLength)
            let value = useMotion ? epoch.movementActivity : epoch.soundActivity
            groups[index, default: []].append(value)
        }
        return groups.keys.sorted().map { index in
            let values = groups[index] ?? []
            let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            let start = session.header.start.addingTimeInterval(Double(index) * binLength)
            return Bin(start: start, end: start.addingTimeInterval(binLength * 0.85), value: mean)
        }
    }

    var body: some View {
        let data = self.bins
        let peak = max(data.map(\.value).max() ?? 0, 0.0001)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: session.header.method == .motion ? "Movement" : "Sound activity")
                Chart(data) { bin in
                    RectangleMark(
                        xStart: .value("Start", bin.start),
                        xEnd: .value("End", bin.end),
                        yStart: .value("Base", 0.0),
                        yEnd: .value("Activity", max(0.02, bin.value / peak))
                    )
                    .foregroundStyle(Theme.accent.opacity(0.35 + 0.65 * min(1, bin.value / peak)))
                    .cornerRadius(2)
                }
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...1)
                .chartXScale(domain: session.header.start...max(session.end, session.header.start.addingTimeInterval(60)))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: 110)
                .accessibilityLabel(Text("Activity through the night"))
                HStack(spacing: 10) {
                    StatTile(title: "Restless sleep", value: Formatters.percent(session.metrics.restlessness), symbol: "figure.roll")
                    StatTile(
                        title: "Movements per hour",
                        value: session.metrics.movementEventsPerHour.formatted(.number.precision(.fractionLength(1))),
                        symbol: "waveform.path",
                        tint: Theme.info
                    )
                }
                if !session.movementPatterns.isEmpty {
                    Text("Repeated, regular movement patterns: \(session.movementPatterns.count). For example restless legs or a partner moving.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SoundsCard: View {
    let session: CompletedSession
    let clipPlayer: ClipPlayer
    let onDeleteClip: (String) -> Void

    private struct TypeCount: Identifiable {
        let type: SoundEventType
        let count: Int
        var id: SoundEventType { type }
    }

    private var counts: [TypeCount] {
        let types: [SoundEventType] = [.snoring, .talking, .coughing, .movement, .disturbance, .unknown]
        return types.compactMap { type in
            let count = session.soundEvents.filter { $0.type == type }.count
            return count > 0 ? TypeCount(type: type, count: count) : nil
        }
    }

    private var clips: [SoundEvent] {
        session.soundEvents.filter { $0.clipFileName != nil }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Sounds")
                if session.soundEvents.isEmpty {
                    Text("No notable sounds were detected.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    SoundTimeline(events: session.soundEvents, start: session.header.start, end: session.end)
                        .frame(height: 34)
                    VStack(spacing: 8) {
                        ForEach(counts) { entry in
                            HStack {
                                Label(entry.type.title, systemImage: entry.type.symbol)
                                    .foregroundStyle(SoundTimeline.color(for: entry.type))
                                Spacer()
                                Text(verbatim: "\(entry.count)")
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            .font(.subheadline)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    if session.metrics.snoringDuration > 0 {
                        DetailRow(title: "Snoring in total", value: Formatters.duration(session.metrics.snoringDuration))
                    }
                }
                if !clips.isEmpty {
                    Divider()
                    Text("Saved clips")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(clips) { event in
                        if let name = event.clipFileName {
                            ClipRow(event: event, name: name, player: clipPlayer, onDelete: { onDeleteClip(name) })
                        }
                    }
                }
                Text("Sounds are recognised on your iPhone from their acoustic pattern. Events marked with ✓ were confirmed by Apple's built-in sound recognition.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// When each sound happened, as coloured ticks along the night.
struct SoundTimeline: View {
    let events: [SoundEvent]
    let start: Date
    let end: Date

    var body: some View {
        GeometryReader { proxy in
            let total = max(end.timeIntervalSince(start), 60)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.surfaceRaised)
                    .frame(height: 8)
                    .frame(maxHeight: .infinity)
                ForEach(events) { event in
                    let fraction = min(max(event.start.timeIntervalSince(start) / total, 0), 1)
                    let width = max(3, proxy.size.width * CGFloat(event.duration / total))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(SoundTimeline.color(for: event.type))
                        .frame(width: width, height: event.type == .snoring ? 26 : 18)
                        .offset(x: proxy.size.width * CGFloat(fraction))
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Timeline of detected sounds"))
    }

    static func color(for type: SoundEventType) -> Color {
        switch type {
        case .snoring: return Theme.accent
        case .talking: return Theme.info
        case .coughing: return Theme.negative
        case .movement: return Theme.stageLight
        case .disturbance: return Theme.accentSoft
        case .breathing: return Theme.positive
        case .unknown: return Theme.textTertiary
        }
    }
}

private struct ClipRow: View {
    let event: SoundEvent
    let name: String
    let player: ClipPlayer
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(name)
            } label: {
                Image(systemName: player.playingName == name ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.playingName == name ? Text("Stop") : Text("Play"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(event.type.title)
                    if event.verifiedByModel {
                        Text(verbatim: "✓")
                            .foregroundStyle(Theme.positive)
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                Text(verbatim: "\(Formatters.time(event.start)) · \(Formatters.duration(event.duration))")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.negative)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Delete clip"))
        }
    }
}

// MARK: - Suggestions, journal, data quality

private struct SuggestionsCard: View {
    let suggestions: [SuggestionKind]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "For tonight")
                ForEach(suggestions, id: \.self) { suggestion in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: suggestion.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(suggestion.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(suggestion.detail)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct JournalPromptCard: View {
    let night: Date
    let open: (Date) -> Void

    @Query private var entries: [JournalEntryRecord]

    init(night: Date, open: @escaping (Date) -> Void) {
        self.night = night
        self.open = open
        _entries = Query(filter: #Predicate<JournalEntryRecord> { $0.night == night })
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Journal")
                if let entry = entries.first {
                    HStack(spacing: 14) {
                        DetailRow(title: "Rested", value: "\(entry.feeling)/5")
                    }
                    if !entry.factors.isEmpty {
                        FactorTags(factors: entry.factors)
                    }
                    Button("Edit entry") { open(night) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("How do you feel this morning? A short note helps you see which habits go with good nights.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        open(night)
                    } label: {
                        Label("Add to journal", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("report.journal")
                }
            }
        }
    }
}

private struct DataQualityCard: View {
    let session: CompletedSession

    private func count(_ kind: MarkerKind) -> Int {
        session.markers.filter { $0.kind == kind }.count
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Measurement")
                DetailRow(title: "Night measured", value: Formatters.percent(session.metrics.dataCoverage))
                ForEach(session.gaps, id: \.start) { gap in
                    DetailRow(title: "Not measured", value: Formatters.timeRange(gap.start, gap.end))
                }
                if count(.trackingInterrupted) > 0 {
                    DetailRow(title: "Pauses in tracking", value: "\(count(.trackingInterrupted))")
                }
                if count(.playbackStarted) > 0 {
                    Text("Relaxation sounds played during the night; sound analysis took this into account.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if count(.thermalWarning) > 0 {
                    Text("The phone got warm, so Apple's sound recognition was paused for a while.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if count(.lowBattery) > 0 {
                    Text("The battery ran low during the night.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
                if count(.recovered) > 0 {
                    Text("The night was restored after SleepFlow was closed.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
                Text("Analysis version \(session.header.algorithmVersion)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
