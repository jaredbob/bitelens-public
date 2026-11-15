import Foundation

public enum Nutrient: String, CaseIterable, Codable, Sendable {
    case calories, protein, carbohydrates, fat, fiber, sodium, alcohol, caffeine, addedSugar

    public var unit: String {
        switch self {
        case .calories: "kcal"
        case .sodium, .caffeine: "mg"
        default: "g"
        }
    }
}

public struct NutrientAmounts: Codable, Equatable, Sendable {
    public var caloriesKcal: Double?
    public var proteinGrams: Double?
    public var carbohydratesGrams: Double?
    public var fatGrams: Double?
    public var fiberGrams: Double?
    public var sodiumMilligrams: Double?
    public var alcoholGrams: Double?
    public var caffeineMilligrams: Double?
    public var addedSugarGrams: Double?

    public init(caloriesKcal: Double? = nil, proteinGrams: Double? = nil, carbohydratesGrams: Double? = nil,
                fatGrams: Double? = nil, fiberGrams: Double? = nil, sodiumMilligrams: Double? = nil,
                alcoholGrams: Double? = nil, caffeineMilligrams: Double? = nil, addedSugarGrams: Double? = nil) {
        self.caloriesKcal = caloriesKcal
        self.proteinGrams = proteinGrams
        self.carbohydratesGrams = carbohydratesGrams
        self.fatGrams = fatGrams
        self.fiberGrams = fiberGrams
        self.sodiumMilligrams = sodiumMilligrams
        self.alcoholGrams = alcoholGrams
        self.caffeineMilligrams = caffeineMilligrams
        self.addedSugarGrams = addedSugarGrams
    }

    public subscript(_ nutrient: Nutrient) -> Double? {
        get { self[keyPath: nutrient.amountKeyPath] }
        set { self[keyPath: nutrient.amountKeyPath] = newValue }
    }
}

private extension Nutrient {
    var amountKeyPath: WritableKeyPath<NutrientAmounts, Double?> {
        switch self {
        case .calories: \.caloriesKcal
        case .protein: \.proteinGrams
        case .carbohydrates: \.carbohydratesGrams
        case .fat: \.fatGrams
        case .fiber: \.fiberGrams
        case .sodium: \.sodiumMilligrams
        case .alcohol: \.alcoholGrams
        case .caffeine: \.caffeineMilligrams
        case .addedSugar: \.addedSugarGrams
        }
    }
}

public struct NutrientTotal: Equatable, Sendable {
    public let knownAmount: Double?
    public let isIncomplete: Bool

    public init(knownAmount: Double?, isIncomplete: Bool) {
        self.knownAmount = knownAmount
        self.isIncomplete = isIncomplete
    }
}

public struct NutrientTotals: Equatable, Sendable {
    private let totals: [Nutrient: NutrientTotal]

    public init(items: [MealItem]) {
        totals = Dictionary(uniqueKeysWithValues: Nutrient.allCases.map { nutrient in
            let known = items.compactMap { $0.nutrients[nutrient] }
            return (nutrient, NutrientTotal(knownAmount: known.isEmpty ? nil : known.reduce(0, +),
                                            isIncomplete: known.count < items.count))
        })
    }

    public subscript(_ nutrient: Nutrient) -> NutrientTotal {
        totals[nutrient] ?? NutrientTotal(knownAmount: nil, isIncomplete: false)
    }
}

public struct ConsumedPortion: Codable, Equatable, Sendable {
    public var grams: Double?
    public var servingDescription: String
    public var count: Double?

    public init(grams: Double? = nil, servingDescription: String = "", count: Double? = nil) {
        self.grams = grams
        self.servingDescription = servingDescription
        self.count = count
    }
}

public enum MealItemOrigin: String, Codable, Sendable {
    case ai, manual
}

public struct OriginalItemEstimate: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let portion: ConsumedPortion
    public let nutrients: NutrientAmounts

    fileprivate init(_ item: MealItem) {
        name = item.name
        description = item.description
        portion = item.portion
        nutrients = item.nutrients
    }
}

public struct MealItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var description: String
    public private(set) var origin: MealItemOrigin?
    public private(set) var originalEstimate: OriginalItemEstimate?
    public var isCorrected: Bool? {
        originalEstimate.map { $0 != OriginalItemEstimate(self) }
    }
    public var portion: ConsumedPortion {
        didSet {
            if portion.grams != oldValue.grams {
                scaleNutrients(from: oldValue.grams)
                countBaselines = nil
            } else if portion.count != oldValue.count {
                if let old = oldValue.count, old.isFinite, old > 0,
                   let new = portion.count, new.isFinite, new > 0 {
                    portion.grams = scaleFromCount(old, to: new, grams: portion.grams)
                } else {
                    countBaselines = nil
                }
            }
        }
    }
    public var nutrients: NutrientAmounts {
        get { nutrientAmounts }
        set {
            for nutrient in Nutrient.allCases where newValue[nutrient] != nutrientAmounts[nutrient] {
                setNutrientAmount(newValue[nutrient], for: nutrient)
            }
        }
    }

    private var nutrientAmounts: NutrientAmounts
    private var nutrientBaselines: [String: AmountBaseline]?
    private var countBaselines: [String: AmountBaseline]?

    private enum CodingKeys: String, CodingKey {
        case id, name, description, portion, nutrientBaselines, countBaselines, origin, originalEstimate
        case nutrientAmounts = "nutrients"
    }

    public init(id: UUID = UUID(), name: String, description: String = "",
                portion: ConsumedPortion = ConsumedPortion(), nutrients: NutrientAmounts = NutrientAmounts()) {
        self.id = id
        self.name = name
        self.description = description
        self.portion = portion
        self.nutrientAmounts = nutrients
        self.origin = .manual
    }

    fileprivate init(copying item: MealItem) {
        id = UUID()
        name = item.name
        description = item.description
        origin = item.origin
        originalEstimate = item.originalEstimate
        portion = item.portion
        nutrientAmounts = item.nutrientAmounts
        nutrientBaselines = item.nutrientBaselines
        countBaselines = item.countBaselines
    }

    fileprivate mutating func retainOriginalEstimate() {
        originalEstimate = OriginalItemEstimate(self)
        origin = .ai
    }

    fileprivate mutating func preserveOrigin(of previous: MealItem?) {
        if let previous {
            origin = previous.origin
            originalEstimate = previous.originalEstimate
        } else {
            origin = .manual
            originalEstimate = nil
        }
    }

    /// Applies an explicit correction, even when it equals the currently displayed amount.
    public mutating func setNutrientAmount(_ amount: Double?, for nutrient: Nutrient) {
        nutrientAmounts[nutrient] = amount
        nutrientBaselines?[nutrient.rawValue] = nil
        if nutrientBaselines?.isEmpty == true { nutrientBaselines = nil }
        countBaselines?[nutrient.rawValue] = nil
        if countBaselines?.isEmpty == true { countBaselines = nil }
    }

    private mutating func scaleNutrients(from previousWeight: Double?) {
        var baselines = nutrientBaselines ?? [:]
        for nutrient in Nutrient.allCases {
            guard let amount = nutrientAmounts[nutrient] else { continue }
            let key = nutrient.rawValue
            if baselines[key] == nil, let previousWeight, previousWeight.isFinite, previousWeight > 0 {
                baselines[key] = AmountBaseline(reference: previousWeight, amount: amount)
            }
            if let grams = portion.grams, grams.isFinite, grams >= 0, let baseline = baselines[key] {
                nutrientAmounts[nutrient] = baseline.amount(at: grams)
            }
        }
        nutrientBaselines = baselines.isEmpty ? nil : baselines
    }

    private mutating func scaleFromCount(_ old: Double, to new: Double, grams: Double?) -> Double? {
        var baselines = countBaselines ?? [:]
        func scaled(_ amount: Double, key: String) -> Double {
            let baseline = baselines[key] ?? AmountBaseline(reference: old, amount: amount)
            baselines[key] = baseline
            return baseline.amount(at: new)
        }
        let scaledGrams = grams.map { scaled($0, key: "weight") }
        for nutrient in Nutrient.allCases {
            if let amount = nutrientAmounts[nutrient] {
                nutrientAmounts[nutrient] = scaled(amount, key: nutrient.rawValue)
            }
        }
        countBaselines = baselines.isEmpty ? nil : baselines
        // Count scaling preserves nutrient amounts per gram, including the
        // weight reference used to recover from zero or unknown weight.
        return scaledGrams
    }

    private struct AmountBaseline: Codable, Equatable, Sendable {
        let reference: Double
        let amount: Double

        // Existing local libraries encoded the weight reference as grams.
        private enum CodingKeys: String, CodingKey { case reference = "grams", amount }

        func amount(at value: Double) -> Double {
            if value == reference { return amount }
            if value == 0 || amount == 0 { return 0 }
            let ratio = value / reference
            if ratio.isNormal { return amount * ratio }

            // Keep the intermediate ratio from overflowing or underflowing before multiplication.
            return Double(sign: .plus, exponent: value.exponent - reference.exponent + amount.exponent,
                          significand: value.significand / reference.significand * amount.significand)
        }
    }
}

public struct EstimateProvenance: Codable, Equatable, Sendable {
    public let provider: AIProvider
    public let model: String
    public let version: String?

    public init(provider: AIProvider, model: String, version: String? = nil) {
        self.provider = provider
        self.model = model
        self.version = version
    }
}

public struct MealEstimate: Codable, Equatable, Sendable {
    public let items: [MealItem]
    public let provenance: EstimateProvenance
    var image: MealImageEstimate? = nil

    public init(items: [MealItem], provenance: EstimateProvenance) {
        self.items = items
        self.provenance = provenance
    }
}

enum MealImageEstimate: Codable, Equatable, Sendable {
    case foodPhoto
    case receipt(orderTime: String?, purchasedQuantities: [UUID: Double])
}

/// Manual entries and corrected estimates use the same review state.
public struct MealReview: Codable, Equatable, Sendable {
    public internal(set) var items: [MealItem]
    public let estimateProvenance: EstimateProvenance?
    let originalEstimateItemIDs: Set<UUID>?
    var purchasedQuantities: [UUID: Double]? = nil
    public var nutrientTotals: NutrientTotals { NutrientTotals(items: items) }

    public func purchasedQuantity(for itemID: UUID) -> Double? { purchasedQuantities?[itemID] }

    var originatingItemIDs: Set<UUID>? {
        if let originalEstimateItemIDs { return originalEstimateItemIDs }
        // Older drafts only stored the surviving review items.
        return estimateProvenance == nil ? nil : Set(items.map(\.id))
    }
}

/// Structured confirmed data. The local photo reference is separate from this record.
public struct MealRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let ownerID: UUID
    public let mealTime: MealTime
    public let confirmedAt: Date
    public let notes: String
    public let items: [MealItem]
    public let estimateProvenance: EstimateProvenance?
    public var nutrientTotals: NutrientTotals { NutrientTotals(items: items) }
}

public struct LoggedMeal: Codable, Equatable, Sendable, Identifiable {
    public let record: MealRecord
    public let photo: StoredMealImage?
    public let revision: Int
    public var id: UUID { record.id }

    init(record: MealRecord, photo: StoredMealImage?, revision: Int = 1) {
        self.record = record
        self.photo = photo
        self.revision = revision
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        record = try values.decode(MealRecord.self, forKey: .record)
        photo = try values.decodeIfPresent(StoredMealImage.self, forKey: .photo)
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 1
    }
}

public struct DailyMealSummary: Equatable, Sendable, Identifiable {
    public let localDate: String
    public let meals: [LoggedMeal]
    public var id: String { localDate }
    public var nutrientTotals: NutrientTotals { NutrientTotals(items: meals.flatMap(\.record.items)) }
}

public enum MealReviewIssue: Error, Equatable, Sendable {
    case itemsRequired
    case itemNameRequired
    case duplicateItems
    case invalidAmount
    case invalidCount
    case loggedMealNotFound
    case invalidProvenance
}

struct LocalMealLibrary: Codable {
    var drafts: [MealDraft] = []
    var loggedMeals: [LoggedMeal] = []
    var pendingChanges: [PendingMealChange] = []
    var loggedObservations: [LoggedObservation] = []
    var pendingObservationChanges: [PendingObservationChange] = []
    var appleHealthSymptomSharingEnabled = false
    var observationAppleHealth = ObservationAppleHealthState()

    var appleHealthSyncEnabled = false
    var appleHealthAuthorizationRequest = AppleHealthAuthorizationRequest.pending
    var appleHealthAuthorizationIncludesAlcohol = false
    var appleHealthMeals: [UUID: AppleHealthMealState] = [:]

    private enum CodingKeys: String, CodingKey {
        case drafts, loggedMeals, pendingChanges, appleHealthSyncEnabled, appleHealthAuthorizationRequest, appleHealthMeals
        case appleHealthAuthorizationIncludesAlcohol
        case loggedObservations, pendingObservationChanges, appleHealthSymptomSharingEnabled, observationAppleHealth
    }
    private enum LegacyKeys: String, CodingKey { case pendingCreates }
    private struct LegacyCreate: Decodable { let meal: MealRecord }

    init(drafts: [MealDraft] = []) { self.drafts = drafts }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        drafts = try values.decode([MealDraft].self, forKey: .drafts)
        loggedMeals = try values.decode([LoggedMeal].self, forKey: .loggedMeals)
        loggedObservations = try values.decodeIfPresent([LoggedObservation].self, forKey: .loggedObservations) ?? []
        pendingObservationChanges = try values.decodeIfPresent([PendingObservationChange].self, forKey: .pendingObservationChanges) ?? []
        appleHealthSymptomSharingEnabled = try values.decodeIfPresent(Bool.self, forKey: .appleHealthSymptomSharingEnabled) ?? false
        observationAppleHealth = try values.decodeIfPresent(ObservationAppleHealthState.self, forKey: .observationAppleHealth) ?? .init()
        appleHealthSyncEnabled = try values.decodeIfPresent(Bool.self, forKey: .appleHealthSyncEnabled) ?? false
        appleHealthAuthorizationRequest = try values.decodeIfPresent(AppleHealthAuthorizationRequest.self,
                                                                     forKey: .appleHealthAuthorizationRequest) ?? .pending
        appleHealthAuthorizationIncludesAlcohol = try values.decodeIfPresent(Bool.self,
                                                                              forKey: .appleHealthAuthorizationIncludesAlcohol) ?? false
        appleHealthMeals = try values.decodeIfPresent([UUID: AppleHealthMealState].self, forKey: .appleHealthMeals) ?? [:]
        if let changes = try values.decodeIfPresent([PendingMealChange].self, forKey: .pendingChanges) {
            pendingChanges = changes
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            pendingChanges = try (legacy.decodeIfPresent([LegacyCreate].self, forKey: .pendingCreates) ?? [])
                .map { .save($0.meal, revision: 1) }
        }
    }

    mutating func enqueue(_ change: PendingMealChange) {
        pendingChanges.removeAll { $0.id == change.id }
        pendingChanges.append(change)
    }

    var photos: [StoredMealImage] { drafts.compactMap(\.photo) + loggedMeals.compactMap(\.photo) }
}

extension MealWorkflow {
    public var loggedMeals: [LoggedMeal] {
        guard access == .owner else { return [] }
        return localMeals.loggedMeals.filter { $0.record.ownerID == activeAccountID }.sorted {
            if $0.record.mealTime.instant == $1.record.mealTime.instant {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.record.mealTime.instant > $1.record.mealTime.instant
        }
    }

    public var dailyMealSummaries: [DailyMealSummary] {
        Dictionary(grouping: loggedMeals, by: \.record.mealTime.localDate)
            .map { DailyMealSummary(localDate: $0.key, meals: $0.value) }
            .sorted { $0.localDate > $1.localDate }
    }

    public var pendingMealChanges: [PendingMealChange] {
        guard access == .owner else { return [] }
        return localMeals.pendingChanges.filter { $0.ownerID == activeAccountID }
    }

    public func copyLoggedMealToDraft(_ id: UUID, timeZone: TimeZone = .current) throws -> MealDraft {
        let record = localMeals.loggedMeals[try loggedMealIndex(for: id)].record
        let items = record.items.map { MealItem(copying: $0) }
        let estimatedItemIDs = Set(items.lazy.filter { $0.origin != .manual }.map(\.id))
        let provenance = estimatedItemIDs.isEmpty ? nil : record.estimateProvenance
        let review = MealReview(items: items, estimateProvenance: provenance,
                                originalEstimateItemIDs: provenance == nil ? nil : estimatedItemIDs)
        let draft = MealDraft(id: UUID(), photo: nil, notes: record.notes,
                              mealTime: MealTime(instant: now(), timeZone: timeZone), review: review)
        var updated = localMeals
        updated.drafts.append(draft)
        try saveLocalMeals(updated)
        return draft
    }

    public func updateDraftItems(_ id: UUID, items: [MealItem]) throws {
        let index = try draftIndex(for: id)
        try validate(items: items)
        var updated = localMeals
        let previous = updated.drafts[index].review
        let originalIDs = previous?.originatingItemIDs
        let itemIDs = Set(items.map(\.id))
        let keepsEstimate = originalIDs?.isDisjoint(with: itemIDs) == false
        updated.drafts[index].review = MealReview(items: preservingOrigins(in: items, from: previous?.items ?? []),
                                                  estimateProvenance: keepsEstimate ? previous?.estimateProvenance : nil,
                                                  originalEstimateItemIDs: originalIDs,
                                                  purchasedQuantities: previous?.purchasedQuantities?.filter { itemIDs.contains($0.key) })
        try saveLocalMeals(updated)
    }

    /// Stores a normalized result in the draft. Confirmation is a separate action.
    public func applyEstimate(_ estimate: MealEstimate, to id: UUID) throws {
        let index = try draftIndex(for: id)
        guard !estimate.provenance.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MealReviewIssue.invalidProvenance }
        if estimate.items.isEmpty {
            guard case .receipt(_?, _) = estimate.image else { throw MealReviewIssue.itemsRequired }
            var updated = localMeals
            updated.drafts[index].applyImageTimeSuggestion(estimate.image, now: now())
            if updated.drafts[index] != localMeals.drafts[index] { try saveLocalMeals(updated) }
            return
        }
        try validate(items: estimate.items)
        var updated = localMeals
        let items = estimate.items.map { item in
            var estimated = item
            estimated.retainOriginalEstimate()
            return estimated
        }
        var review = MealReview(items: items, estimateProvenance: estimate.provenance,
                                originalEstimateItemIDs: Set(items.map(\.id)))
        if case .receipt(_, let purchasedQuantities) = estimate.image {
            review.purchasedQuantities = purchasedQuantities
        }
        updated.drafts[index].review = review
        updated.drafts[index].applyImageTimeSuggestion(estimate.image, now: now())
        try saveLocalMeals(updated)
    }

    /// Explicitly confirms the reviewed draft without making a network request.
    @discardableResult public func confirmMeal(_ id: UUID) throws -> LoggedMeal {
        guard let ownerID = activeAccountID else { throw WorkflowIssue.accessDenied }
        let index = try draftIndex(for: id)
        let draft = localMeals.drafts[index]
        let linkedUrge = draft.linkingUrgeID.flatMap { try? urgeIndex(for: $0) }
        guard let review = draft.review, !review.items.isEmpty else { throw MealReviewIssue.itemsRequired }
        guard !draft.needsMealTime else { throw DraftIssue.mealTimeRequired }
        try validate(items: review.items)
        let record = MealRecord(id: draft.id, ownerID: ownerID, mealTime: draft.mealTime, confirmedAt: now(),
                                notes: draft.notes, items: review.items, estimateProvenance: review.estimateProvenance)
        let logged = LoggedMeal(record: record, photo: draft.photo)
        var updated = localMeals
        updated.drafts.remove(at: index)
        updated.loggedMeals.append(logged)
        updated.enqueue(.save(record, revision: logged.revision))
        if let linkedUrge { updated.setUrgeMealLink(at: linkedUrge, to: logged.id) }
        if appleHealthSyncEnabled { updated.appleHealthMeals[logged.id] = AppleHealthMealState() }
        try saveLocalMeals(updated)
        scheduleAppleHealthSync()
        if linkedUrge != nil { scheduleObservationAppleHealthSync() }
        return logged
    }

    @discardableResult public func updateLoggedMeal(_ id: UUID, mealTime: MealTime, notes: String,
                                                   items: [MealItem]) throws -> LoggedMeal {
        let index = try loggedMealIndex(for: id)
        guard !items.isEmpty else { throw MealReviewIssue.itemsRequired }
        try validate(items: items)
        let previous = localMeals.loggedMeals[index]
        let original = previous.record
        let record = MealRecord(id: id, ownerID: original.ownerID, mealTime: mealTime,
                                confirmedAt: original.confirmedAt, notes: notes,
                                items: preservingOrigins(in: items, from: original.items),
                                estimateProvenance: original.estimateProvenance)
        guard record != original else { return previous }
        let edited = LoggedMeal(record: record, photo: previous.photo, revision: previous.revision + 1)
        var updated = localMeals
        updated.loggedMeals[index] = edited
        updated.enqueue(.save(record, revision: edited.revision))
        try saveLocalMeals(updated)
        scheduleAppleHealthSync()
        return edited
    }

    public func deleteLoggedMeal(_ id: UUID) throws {
        let index = try loggedMealIndex(for: id)
        try sharedImageInbox?.remove(id, for: sharedImageAccountID)
        var updated = localMeals
        let deleted = updated.loggedMeals.remove(at: index)
        // A create could have committed even if its response never arrived.
        updated.enqueue(.delete(id: id, ownerID: deleted.record.ownerID, revision: deleted.revision + 1))
        let linkedUrges = updated.loggedObservations.indices.filter { index in
            let record = updated.loggedObservations[index].record
            return record.ownerID == deleted.record.ownerID && record.mealID == id
        }
        for index in linkedUrges {
            updated.setUrgeMealLink(at: index, to: nil)
        }
        try saveLocalMeals(updated)
        scheduleAppleHealthSync()
        if !linkedUrges.isEmpty { scheduleObservationAppleHealthSync() }
        if let photo = deleted.photo { try? draftStorage?.removePhoto(photo) }
    }

    public func photoData(forLoggedMeal id: UUID) throws -> Data {
        try readPhoto(localMeals.loggedMeals[try loggedMealIndex(for: id)].photo)
    }

    private func loggedMealIndex(for id: UUID) throws -> Int {
        guard access == .owner else { throw WorkflowIssue.accessDenied }
        guard let index = localMeals.loggedMeals.firstIndex(where: { $0.id == id && $0.record.ownerID == activeAccountID })
        else { throw MealReviewIssue.loggedMealNotFound }
        return index
    }

    private func validate(items: [MealItem]) throws {
        guard Set(items.map(\.id)).count == items.count else { throw MealReviewIssue.duplicateItems }
        for item in items {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw MealReviewIssue.itemNameRequired }
            let amounts = [item.portion.grams] + Nutrient.allCases.map { item.nutrients[$0] }
            guard amounts.compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 })
            else { throw MealReviewIssue.invalidAmount }
            if let count = item.portion.count, !count.isFinite || count <= 0 {
                throw MealReviewIssue.invalidCount
            }
        }
    }

    private func preservingOrigins(in items: [MealItem], from previous: [MealItem]) -> [MealItem] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return items.map { item in
            var updated = item
            updated.preserveOrigin(of: previousByID[item.id])
            return updated
        }
    }
}
