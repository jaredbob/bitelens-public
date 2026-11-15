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

    public var nutrientTotals: NutrientTotals? {
        let meals = rows.compactMap { row -> LoggedMeal? in
            if case .meal(let meal) = row { return meal }
            return nil
        }
        guard !meals.isEmpty else { return nil }
        return DailyMealSummary(localDate: localDate, meals: meals).nutrientTotals
    }
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
}
