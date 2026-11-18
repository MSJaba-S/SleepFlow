import Foundation
import SleepModels

/// Compact description of one recorded night, the unit of all long-term statistics.
public struct NightSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: Date
    public var end: Date
    public var sleepOnset: Date?
    public var finalAwakening: Date?
    public var totalSleep: TimeInterval
    public var timeInBed: TimeInterval
    public var efficiency: Double
    public var score: Int
    public var sleepGoal: TimeInterval
    /// Lifestyle factors logged in the journal for this night (raw identifiers).
    public var factors: [String]

    public init(
        id: UUID = UUID(),
        start: Date,
        end: Date,
        sleepOnset: Date?,
        finalAwakening: Date?,
        totalSleep: TimeInterval,
        timeInBed: TimeInterval,
        efficiency: Double,
        score: Int,
        sleepGoal: TimeInterval,
        factors: [String] = []
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.sleepOnset = sleepOnset
        self.finalAwakening = finalAwakening
        self.totalSleep = totalSleep
        self.timeInBed = timeInBed
        self.efficiency = efficiency
        self.score = score
        self.sleepGoal = sleepGoal
        self.factors = factors
    }

    public var bedtime: Date { sleepOnset ?? start }
    public var wakeTime: Date { finalAwakening ?? end }
    public var goalMet: Bool { totalSleep >= sleepGoal - 15 * 60 }
}

public enum StatisticsPeriod: String, Codable, Sendable, CaseIterable {
    case week
    case month
    case year
}

public struct DailyPoint: Sendable, Hashable, Identifiable {
    /// The calendar date of the evening the night started.
    public var night: Date
    public var totalSleep: TimeInterval
    public var score: Int
    public var bedtimeMinutes: Double
    public var wakeMinutes: Double
    public var goalMet: Bool
    public var sessionID: UUID

    public var id: UUID { sessionID }
}

public struct AggregatePoint: Sendable, Hashable, Identifiable {
    public var periodStart: Date
    public var averageSleep: TimeInterval
    public var averageScore: Double
    public var nights: Int

    public var id: Date { periodStart }
}

public struct PeriodSummary: Sendable, Hashable {
    public var nights: Int
    public var averageSleep: TimeInterval
    public var averageTimeInBed: TimeInterval
    public var averageScore: Double
    public var averageEfficiency: Double
    /// 0...100, high when bed and wake times are regular.
    public var consistencyScore: Double?
    public var bedtimeMean: Double?
    public var bedtimeSpread: Double
    public var wakeMean: Double?
    public var wakeSpread: Double
    /// Fraction of nights reaching the sleep goal (0...1).
    public var goalAchievement: Double

    public static let empty = PeriodSummary(
        nights: 0, averageSleep: 0, averageTimeInBed: 0, averageScore: 0, averageEfficiency: 0,
        consistencyScore: nil, bedtimeMean: nil, bedtimeSpread: 0, wakeMean: nil, wakeSpread: 0, goalAchievement: 0
    )
}

/// Average score with and without a journal factor.
public struct FactorImpact: Sendable, Hashable, Identifiable {
    public var factor: String
    public var nightsWith: Int
    public var nightsWithout: Int
    public var averageScoreWith: Double
    public var averageScoreWithout: Double

    public var difference: Double { averageScoreWith - averageScoreWithout }
    public var id: String { factor }
}

public enum StatisticsCalculator {
    /// Nights are attributed to the evening they started: a session starting between 12:00 on day D
    /// and 11:59 on day D+1 belongs to the night of day D.
    public static func nightDate(for start: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: start.addingTimeInterval(-12 * 3600))
    }

    public static func interval(for period: StatisticsPeriod, containing date: Date, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component
        switch period {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        return calendar.dateInterval(of: component, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86_400)
    }

    public static func shift(_ interval: DateInterval, period: StatisticsPeriod, by steps: Int, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component
        switch period {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        let anchor = calendar.date(byAdding: component, value: steps, to: interval.start) ?? interval.start
        return self.interval(for: period, containing: anchor, calendar: calendar)
    }

    public static func nights(_ nights: [NightSummary], in interval: DateInterval, calendar: Calendar) -> [NightSummary] {
        nights.filter { night in
            let date = nightDate(for: night.start, calendar: calendar)
            return date >= interval.start && date < interval.end
        }
    }

    public static func dailyPoints(_ nights: [NightSummary], calendar: Calendar) -> [DailyPoint] {
        nights.map { night in
            DailyPoint(
                night: nightDate(for: night.start, calendar: calendar),
                totalSleep: night.totalSleep,
                score: night.score,
                bedtimeMinutes: ClockTime.minutesSinceMidnight(night.bedtime, calendar: calendar),
                wakeMinutes: ClockTime.minutesSinceMidnight(night.wakeTime, calendar: calendar),
                goalMet: night.goalMet,
                sessionID: night.id
            )
        }
        .sorted { $0.night < $1.night }
    }

    public static func summary(_ nights: [NightSummary], calendar: Calendar) -> PeriodSummary {
        guard !nights.isEmpty else { return .empty }
        let bedMinutes = nights.map { ClockTime.minutesSinceMidnight($0.bedtime, calendar: calendar) }
        let wakeMinutes = nights.map { ClockTime.minutesSinceMidnight($0.wakeTime, calendar: calendar) }
        let bedSpread = ClockTime.circularSpread(minutes: bedMinutes)
        let wakeSpread = ClockTime.circularSpread(minutes: wakeMinutes)
        return PeriodSummary(
            nights: nights.count,
            averageSleep: Stats.mean(nights.map(\.totalSleep)),
            averageTimeInBed: Stats.mean(nights.map(\.timeInBed)),
            averageScore: Stats.mean(nights.map { Double($0.score) }),
            averageEfficiency: Stats.mean(nights.map(\.efficiency)),
            consistencyScore: nights.count >= 3 ? consistencyScore(bedSpread: bedSpread, wakeSpread: wakeSpread) : nil,
            bedtimeMean: ClockTime.circularMean(minutes: bedMinutes),
            bedtimeSpread: bedSpread,
            wakeMean: ClockTime.circularMean(minutes: wakeMinutes),
            wakeSpread: wakeSpread,
            goalAchievement: Double(nights.filter(\.goalMet).count) / Double(nights.count)
        )
    }

    /// 100 when the circular spread of bed and wake times is ≤ 15 min, 0 at ≥ 120 min.
    public static func consistencyScore(bedSpread: Double, wakeSpread: Double) -> Double {
        let spread = (bedSpread + wakeSpread) / 2
        let t = (120 - spread) / (120 - 15)
        return Stats.clamp(t, 0, 1) * 100
    }

    public static func aggregates(_ nights: [NightSummary], by component: Calendar.Component, calendar: Calendar) -> [AggregatePoint] {
        var groups: [Date: [NightSummary]] = [:]
        for night in nights {
            let date = nightDate(for: night.start, calendar: calendar)
            let start = calendar.dateInterval(of: component, for: date)?.start ?? date
            groups[start, default: []].append(night)
        }
        return groups.map { start, members in
            AggregatePoint(
                periodStart: start,
                averageSleep: Stats.mean(members.map(\.totalSleep)),
                averageScore: Stats.mean(members.map { Double($0.score) }),
                nights: members.count
            )
        }
        .sorted { $0.periodStart < $1.periodStart }
    }

    /// Consecutive most recent nights that reached the goal.
    public static func goalStreak(_ nights: [NightSummary]) -> Int {
        var streak = 0
        for night in nights.sorted(by: { $0.start > $1.start }) {
            guard night.goalMet else { break }
            streak += 1
        }
        return streak
    }

    /// Compares the average score of nights with and without each journal factor.
    public static func factorImpacts(_ nights: [NightSummary], minimumNights: Int = 3) -> [FactorImpact] {
        let factors = Set(nights.flatMap(\.factors))
        var result: [FactorImpact] = []
        for factor in factors {
            let with = nights.filter { $0.factors.contains(factor) }
            let without = nights.filter { !$0.factors.contains(factor) }
            guard with.count >= minimumNights, without.count >= minimumNights else { continue }
            result.append(FactorImpact(
                factor: factor,
                nightsWith: with.count,
                nightsWithout: without.count,
                averageScoreWith: Stats.mean(with.map { Double($0.score) }),
                averageScoreWithout: Stats.mean(without.map { Double($0.score) })
            ))
        }
        return result.sorted { abs($0.difference) > abs($1.difference) }
    }
}
