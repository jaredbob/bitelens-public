import Foundation

public enum HistoryRow: Equatable, Sendable, Identifiable {
    case meal(LoggedMeal)
    case observation(LoggedObservation)

    public enum ID: Hashable, Sendable {
        case meal(UUID)
        case observation(UUID)
    }

    public var id: ID {
        switch self {
        case .meal(let meal): .meal(meal.id)
        case .observation(let observation): .observation(observation.id)
        }
    }

    public var time: MealTime {
        switch self {
        case .meal(let meal): meal.record.mealTime
        case .observation(let observation): observation.record.time
        }
    }

    fileprivate var recordID: UUID {
        switch id {
        case .meal(let uuid), .observation(let uuid): uuid
        }
    }
}

public struct DailyHistory: Equatable, Sendable, Identifiable {
    public let localDate: String
    public let rows: [HistoryRow]
    public var id: String { localDate }

    /// The recorded Gregorian date represented at midnight UTC.
    public var calendarDate: Date? { try? MealTime.localDateFormat.parse(localDate) }

    public var nutrientTotals: NutrientTotals? {
        let meals = rows.compactMap { row -> LoggedMeal? in
            if case .meal(let meal) = row { return meal }
            return nil
        }
        guard !meals.isEmpty else { return nil }
        return DailyMealSummary(localDate: localDate, meals: meals).nutrientTotals
    }
}

public enum NutrientHistoryPeriod: String, CaseIterable, Sendable {
    case week, month, allTime

    fileprivate var calendarComponent: Calendar.Component? {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .allTime: nil
        }
    }
}

public struct NutrientHistoryExtreme: Equatable, Sendable {
    // Gregorian date label at midnight UTC, independent of the meal's actual time zone.
    public let date: Date
    public let amount: Double
    public let tieCount: Int
    public var localDate: String { MealTime.localDateFormat.format(date) }
}

public struct NutrientHistorySummary: Equatable, Sendable, Identifiable {
    public let dates: ClosedRange<Date>?
    public let dayCount: Int
    public let average: Double?
    public let high: NutrientHistoryExtreme?
    public let low: NutrientHistoryExtreme?
    public var id: Date? { dates?.lowerBound }

    fileprivate init(dates: ClosedRange<Date>?, totals: [(date: Date, amount: Double)]) {
        self.dates = dates
        dayCount = totals.count
        guard let highest = totals.map(\.amount).max(), let lowest = totals.map(\.amount).min() else {
            average = nil
            high = nil
            low = nil
            return
        }
        average = totals.reduce(0) { $0 + $1.amount } / Double(dayCount)
        high = Self.extreme(amount: highest, in: totals)
        low = Self.extreme(amount: lowest, in: totals)
    }

    private static func extreme(amount: Double, in totals: [(date: Date, amount: Double)]) -> NutrientHistoryExtreme? {
        let tiedDates = totals.filter { $0.amount == amount }.map(\.date)
        return tiedDates.max().map { NutrientHistoryExtreme(date: $0, amount: amount, tieCount: tiedDates.count) }
    }
}

public struct NutrientHistory: Equatable, Sendable {
    public let through: Date
    public let summaries: [NutrientHistorySummary]
}

extension MealWorkflow {
    public var dailyHistory: [DailyHistory] {
        let rows = loggedMeals.map(HistoryRow.meal) + loggedObservations.map(HistoryRow.observation)
        return Dictionary(grouping: rows, by: \.time.localDate).map { date, entries in
            let sorted = entries.sorted { lhs, rhs in
                if lhs.time.instant != rhs.time.instant { return lhs.time.instant > rhs.time.instant }
                if lhs.recordID != rhs.recordID { return lhs.recordID.uuidString < rhs.recordID.uuidString }
                // Meals were inserted before observations, preserving their order on an ID collision.
                return false
            }
            return DailyHistory(localDate: date, rows: sorted)
        }
        .sorted { $0.localDate > $1.localDate }
    }

    public func nutrientHistory(for nutrient: Nutrient, in period: NutrientHistoryPeriod,
                                asOf date: Date, timeZone: TimeZone = .current) -> NutrientHistory {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 2

        // Group recorded calendar dates independently of travel and daylight saving time.
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let today = calendar.date(from: localCalendar.dateComponents([.year, .month, .day], from: date))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let mealDays = dailyHistory.compactMap { day -> (date: Date, total: NutrientTotal)? in
            guard let date = day.calendarDate, date <= yesterday,
                  let totals = day.nutrientTotals else { return nil }
            return (date, totals[nutrient])
        }

        let groupedDays = Dictionary(grouping: mealDays) { day -> DateInterval? in
            period.calendarComponent.flatMap { calendar.dateInterval(of: $0, for: day.date) }
        }
        let summaries = groupedDays.map { interval, days in
            let dates = interval.map { $0.start...calendar.date(byAdding: .day, value: -1, to: $0.end)! }
            let totals = days.compactMap { day -> (date: Date, amount: Double)? in
                guard !day.total.isIncomplete, let amount = day.total.knownAmount else { return nil }
                return (day.date, amount)
            }
            return NutrientHistorySummary(dates: dates, totals: totals)
        }.sorted { ($0.id ?? .distantPast) > ($1.id ?? .distantPast) }
        return NutrientHistory(through: yesterday, summaries: summaries)
    }
}
