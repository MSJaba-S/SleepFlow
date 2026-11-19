import Charts
import SwiftData
import SwiftUI
import SleepCore

/// Long-term trends per week, month or year.
struct StatisticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Query(sort: \SleepSessionRecord.start, order: .reverse) private var sessions: [SleepSessionRecord]

    @State private var period: StatisticsPeriod = .week
    @State private var anchor = Date()

    private var calendar: Calendar { .current }

    var body: some View {
        let interval = StatisticsCalculator.interval(for: period, containing: anchor, calendar: calendar)
        let all = sessions.map(\.summary)
        let nights = StatisticsCalculator.nights(all, in: interval, calendar: calendar)
        ScrollView {
            VStack(spacing: Theme.spacing) {
                Picker("Period", selection: $period) {
                    Text("Week").tag(StatisticsPeriod.week)
                    Text("Month").tag(StatisticsPeriod.month)
                    Text("Year").tag(StatisticsPeriod.year)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("statistics.period")

                PeriodNavigator(
                    title: title(for: interval),
                    canGoForward: interval.end <= Date(),
                    back: { shift(-1, from: interval) },
                    forward: { shift(1, from: interval) }
                )

                if nights.isEmpty {
                    Card {
                        EmptyStateView(
                            symbol: "chart.bar.xaxis",
                            title: "No nights in this period",
                            message: "Track a night or go back in time with the arrows."
                        )
                    }
                } else {
                    SummaryTiles(summary: StatisticsCalculator.summary(nights, calendar: calendar), streak: StatisticsCalculator.goalStreak(all))
                    DurationChartCard(nights: nights, period: period, goal: settings.sleepGoal, interval: interval)
                    ScoreChartCard(nights: nights, period: period, interval: interval)
                    if period != .year {
                        ScheduleChartCard(nights: nights, interval: interval)
                    }
                }
                FactorImpactCard(impacts: StatisticsCalculator.factorImpacts(all))
            }
            .padding(Theme.padding)
        }
        .background(NightBackground())
        .navigationTitle("Statistics")
        .demoBanner(model.isDemo)
    }

    private func shift(_ steps: Int, from interval: DateInterval) {
        let shifted = StatisticsCalculator.shift(interval, period: period, by: steps, calendar: calendar)
        withAnimation(.easeInOut(duration: 0.25)) {
            anchor = shifted.start
        }
    }

    private func title(for interval: DateInterval) -> String {
        let last = interval.end.addingTimeInterval(-1)
        switch period {
        case .week:
            return "\(interval.start.formatted(.dateTime.day().month(.abbreviated)))–\(last.formatted(.dateTime.day().month(.abbreviated)))"
        case .month:
            return interval.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return interval.start.formatted(.dateTime.year())
        }
    }
}

/// Day labels for week and month charts.
private enum DayAxis {
    static func stride(for period: StatisticsPeriod) -> Int {
        period == .week ? 1 : 7
    }

    static func format(for period: StatisticsPeriod) -> Date.FormatStyle {
        if period == .week {
            return Date.FormatStyle().weekday(.abbreviated)
        }
        return Date.FormatStyle().day()
    }
}

private struct PeriodNavigator: View {
    let title: String
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Previous period"))
            Spacer()
            Text(verbatim: title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button(action: forward) {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .disabled(!canGoForward)
            .accessibilityLabel(Text("Next period"))
        }
        .foregroundStyle(Theme.accent)
    }
}

private struct SummaryTiles: View {
    let summary: PeriodSummary
    let streak: Int

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            StatTile(title: "Average sleep", value: Formatters.duration(summary.averageSleep), symbol: "bed.double.fill", detail: String(localized: "Nights: \(summary.nights)"))
            StatTile(title: "Average score", value: "\(Int(summary.averageScore.rounded()))", symbol: "star.fill", tint: Theme.accentSoft)
            StatTile(title: "Sleep efficiency", value: Formatters.percent(summary.averageEfficiency), symbol: "gauge.with.dots.needle.67percent", tint: Theme.positive)
            StatTile(
                title: "Regularity",
                value: summary.consistencyScore.map { "\(Int($0.rounded()))" } ?? "–",
                symbol: "calendar",
                detail: summary.consistencyScore == nil ? String(localized: "Needs 3 nights") : String(localized: "of 100"),
                tint: Theme.info
            )
            StatTile(title: "Sleep goal reached", value: Formatters.percent(summary.goalAchievement), symbol: "target", tint: Theme.accent)
            StatTile(title: "Goal streak", value: "\(streak)", symbol: "flame", detail: String(localized: "nights in a row"), tint: Theme.stageAwake)
        }
    }
}

/// Hours slept per night (week, month) or average per month (year), with the goal as a line.
private struct DurationChartCard: View {
    let nights: [NightSummary]
    let period: StatisticsPeriod
    let goal: TimeInterval
    let interval: DateInterval

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Sleep duration", trailing: "Hours")
                chart
                    .frame(height: 190)
                    .accessibilityLabel(Text("Hours of sleep per night"))
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        let goalHours = goal / 3600
        if period == .year {
            let points = StatisticsCalculator.aggregates(nights, by: .month, calendar: .current)
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value("Month", point.periodStart, unit: .month),
                        y: .value("Hours", point.averageSleep / 3600)
                    )
                    .foregroundStyle(Theme.info.gradient)
                    .cornerRadius(4)
                }
                RuleMark(y: .value("Goal", goalHours))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .chartXScale(domain: interval.start...interval.end)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow))
                }
            }
        } else {
            let points = StatisticsCalculator.dailyPoints(nights, calendar: .current)
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value("Night", point.night, unit: .day),
                        y: .value("Hours", point.totalSleep / 3600)
                    )
                    .foregroundStyle(point.goalMet ? Theme.info : Theme.info.opacity(0.45))
                    .cornerRadius(4)
                }
                RuleMark(y: .value("Goal", goalHours))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Goal")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
            }
            .chartXScale(domain: interval.start...interval.end)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: DayAxis.stride(for: period))) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: DayAxis.format(for: period))
                }
            }
        }
    }
}

private struct ScoreChartCard: View {
    let nights: [NightSummary]
    let period: StatisticsPeriod
    let interval: DateInterval

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Sleep Score")
                chart
                    .frame(height: 170)
                    .accessibilityLabel(Text("Sleep Score over time"))
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if period == .year {
            let points = StatisticsCalculator.aggregates(nights, by: .month, calendar: .current)
            Chart(points) { point in
                LineMark(x: .value("Month", point.periodStart, unit: .month), y: .value("Score", point.averageScore))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Month", point.periodStart, unit: .month), y: .value("Score", point.averageScore))
                    .foregroundStyle(Theme.accent)
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: interval.start...interval.end)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow))
                }
            }
        } else {
            let points = StatisticsCalculator.dailyPoints(nights, calendar: .current)
            Chart(points) { point in
                LineMark(x: .value("Night", point.night, unit: .day), y: .value("Score", point.score))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Night", point.night, unit: .day), y: .value("Score", point.score))
                    .foregroundStyle(Theme.color(for: point.score))
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: interval.start...interval.end)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: DayAxis.stride(for: period))) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: DayAxis.format(for: period))
                }
            }
        }
    }
}

/// Bed and wake times as a bar from falling asleep to waking up.
private struct ScheduleChartCard: View {
    let nights: [NightSummary]
    let interval: DateInterval

    /// Hours after 18:00, so a night is one continuous bar (23:00 → 5, 07:00 → 13).
    static func hoursAfterEvening(_ minutes: Double) -> Double {
        let shifted = (minutes - 18 * 60 + 1_440).truncatingRemainder(dividingBy: 1_440)
        return shifted / 60
    }

    var body: some View {
        let points = StatisticsCalculator.dailyPoints(nights, calendar: .current)
        let summary = StatisticsCalculator.summary(nights, calendar: .current)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Bed and wake times")
                Chart(points) { point in
                    BarMark(
                        x: .value("Night", point.night, unit: .day),
                        yStart: .value("Asleep", ScheduleChartCard.hoursAfterEvening(point.bedtimeMinutes)),
                        yEnd: .value("Awake", ScheduleChartCard.hoursAfterEvening(point.wakeMinutes))
                    )
                    .foregroundStyle(Theme.stageDeep.gradient)
                    .cornerRadius(5)
                }
                .chartXScale(domain: interval.start...interval.end)
                .chartYScale(domain: .automatic(includesZero: false, reversed: true))
                .chartYAxis {
                    AxisMarks(values: .stride(by: 2)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            Text(verbatim: Formatters.clock(minutes: (value.as(Double.self) ?? 0) * 60 + 18 * 60))
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: DayAxis.stride(for: nights.count > 10 ? .month : .week))) { _ in
                        AxisValueLabel(format: DayAxis.format(for: nights.count > 10 ? .month : .week))
                    }
                }
                .frame(height: 190)
                .accessibilityLabel(Text("Bed and wake times"))
                HStack(spacing: 10) {
                    StatTile(title: "Typical bedtime", value: summary.bedtimeMean.map { Formatters.clock(minutes: $0) } ?? "–", symbol: "moon.fill", tint: Theme.stageDeep)
                    StatTile(title: "Typical wake-up", value: summary.wakeMean.map { Formatters.clock(minutes: $0) } ?? "–", symbol: "sunrise.fill", tint: Theme.accent)
                }
            }
        }
    }
}

/// Which journal habits go with better or worse nights.
private struct FactorImpactCard: View {
    let impacts: [FactorImpact]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Habits and your score")
                if impacts.isEmpty {
                    Text("Log habits in the journal. Once a habit has been ticked on at least three nights (and left out on three), SleepFlow compares your scores.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(impacts.prefix(6)) { impact in
                        HStack(spacing: 10) {
                            Image(systemName: LifestyleFactor.symbol(forRaw: impact.factor))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                LifestyleFactor.label(forRaw: impact.factor)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("With: \(impact.nightsWith) nights · without: \(impact.nightsWithout)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            ChangeBadge(change: Int(impact.difference.rounded()))
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text("Average score on nights with the habit compared with nights without it. This shows a connection, not a cause.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
