import BiteLensCore
import HealthKit

@MainActor final class HealthKitClient: AppleHealthClient, ObservationAppleHealthClient {
    private lazy var store = HKHealthStore()

    func isAvailable() async -> Bool { HKHealthStore.isHealthDataAvailable() }

    func authorizedNutrients() async -> Set<Nutrient> {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        return AppleHealthSample.supportedNutrients.filter { nutrient in
            guard let type = nutrient.healthKitType else { return false }
            return store.authorizationStatus(for: type) == .sharingAuthorized
        }
    }

    func requestAuthorization(for nutrients: Set<Nutrient>) async throws {
        let types = Set<HKSampleType>(nutrients.compactMap(\.healthKitType))
        try await store.requestAuthorization(toShare: types, read: [])
    }

    func save(_ sample: AppleHealthSample) async throws {
        guard let type = sample.nutrient.healthKitType else { throw HealthKitClientError.unsupportedNutrient }
        let unit: HKUnit = sample.nutrient == .alcohol ? .count() : HKUnit(from: sample.unit)
        let quantity = HKQuantity(unit: unit, doubleValue: sample.amount)
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: sample.syncIdentifier,
            HKMetadataKeySyncVersion: sample.revision,
        ]
        let entry = HKQuantitySample(type: type, quantity: quantity,
                                     start: sample.mealTime, end: sample.mealTime, metadata: metadata)
        try await store.save(entry)
    }

    func ownSampleRevision(mealID: UUID, nutrient: Nutrient) async throws -> Int? {
        guard let type = nutrient.healthKitType else { throw HealthKitClientError.unsupportedNutrient }
        try requireWriteAccess(for: type)
        let predicate = ownSamplePredicate(mealID: mealID, nutrient: nutrient)
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                            sortDescriptors: [])
        let samples = try await query.result(for: store)
        try requireWriteAccess(for: type)
        return try samples.map { try syncRevision(of: $0) }.max()
    }

    func hasOwnSampleDeletion(mealID: UUID, nutrient: Nutrient, revision: Int) async throws -> Bool {
        guard let type = nutrient.healthKitType else { throw HealthKitClientError.unsupportedNutrient }
        try requireWriteAccess(for: type)
        let predicate = ownSamplePredicate(mealID: mealID, nutrient: nutrient)
        let query = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                                    anchor: nil)
        let result = try await query.result(for: store)
        try requireWriteAccess(for: type)
        let identifier = AppleHealthSample.syncIdentifier(mealID: mealID, nutrient: nutrient)
        return result.deletedObjects.contains { deletion in
            deletion.metadata?[HKMetadataKeySyncIdentifier] as? String == identifier &&
                deletion.metadata?[HKMetadataKeySyncVersion] as? Int == revision
        }
    }

    func deleteOwnSamples(mealID: UUID, nutrient: Nutrient) async throws -> Bool {
        guard let type = nutrient.healthKitType else { throw HealthKitClientError.unsupportedNutrient }
        let predicate = ownSamplePredicate(mealID: mealID, nutrient: nutrient)
        return try await store.deleteObjects(of: type, predicate: predicate) > 0
    }

    func writeAccess(for category: Symptom) async -> ObservationAppleHealthWriteAccess {
        guard HKHealthStore.isHealthDataAvailable(), let type = category.healthKitType else { return .denied }
        return switch store.authorizationStatus(for: type) {
        case .notDetermined: .notDetermined
        case .sharingDenied: .denied
        case .sharingAuthorized: .authorized
        @unknown default: .denied
        }
    }

    func requestWriteAccess(for categories: Set<Symptom>) async throws {
        let types = Set<HKSampleType>(categories.compactMap(\.healthKitType))
        try await store.requestAuthorization(toShare: types, read: [])
    }

    func save(_ sample: ObservationAppleHealthSample) async throws {
        guard let type = sample.category.healthKitType else { throw HealthKitClientError.unsupportedSymptom }
        try requireWriteAccess(for: type)
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: sample.syncIdentifier,
            HKMetadataKeySyncVersion: sample.revision,
        ]
        let entry = HKCategorySample(type: type, value: sample.value, start: sample.instant, end: sample.instant,
                                     metadata: metadata)
        try await store.save(entry)
    }

    func ownSampleRevision(observationID: UUID, category: Symptom) async throws -> Int? {
        guard let type = category.healthKitType else { throw HealthKitClientError.unsupportedSymptom }
        try requireWriteAccess(for: type)
        let identifier = ObservationAppleHealthSample.syncIdentifier(observationID: observationID)
        let query = HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: ownSamplePredicate(identifier))],
                                            sortDescriptors: [])
        let samples = try await query.result(for: store)
        try requireWriteAccess(for: type)
        return try samples.map { try syncRevision(of: $0) }.max()
    }

    func hasOwnSampleDeletion(observationID: UUID, category: Symptom, revision: Int) async throws -> Bool {
        guard let type = category.healthKitType else { throw HealthKitClientError.unsupportedSymptom }
        try requireWriteAccess(for: type)
        let identifier = ObservationAppleHealthSample.syncIdentifier(observationID: observationID)
        let predicate = ownSamplePredicate(identifier)
        let query = HKAnchoredObjectQueryDescriptor(predicates: [.categorySample(type: type, predicate: predicate)],
                                                    anchor: nil)
        let result = try await query.result(for: store)
        try requireWriteAccess(for: type)
        return result.deletedObjects.contains { deletion in
            deletion.metadata?[HKMetadataKeySyncIdentifier] as? String == identifier &&
                deletion.metadata?[HKMetadataKeySyncVersion] as? Int == revision
        }
    }

    func deleteOwnSamples(observationID: UUID, category: Symptom) async throws {
        guard let type = category.healthKitType else { throw HealthKitClientError.unsupportedSymptom }
        try requireWriteAccess(for: type)
        let identifier = ObservationAppleHealthSample.syncIdentifier(observationID: observationID)
        _ = try await store.deleteObjects(of: type, predicate: ownSamplePredicate(identifier))
    }

    private func syncRevision(of sample: HKSample) throws -> Int {
        guard let revision = sample.metadata?[HKMetadataKeySyncVersion] as? Int else {
            throw HealthKitClientError.missingSyncVersion
        }
        return revision
    }

    private func requireWriteAccess(for type: HKSampleType) throws {
        guard store.authorizationStatus(for: type) == .sharingAuthorized else {
            throw HealthKitClientError.writeAccessRequired
        }
    }

    private func ownSamplePredicate(mealID: UUID, nutrient: Nutrient) -> NSPredicate {
        ownSamplePredicate(AppleHealthSample.syncIdentifier(mealID: mealID, nutrient: nutrient))
    }

    private func ownSamplePredicate(_ identifier: String) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [identifier]),
        ])
    }
}

private enum HealthKitClientError: Error {
    case unsupportedNutrient
    case unsupportedSymptom
    case writeAccessRequired
    case missingSyncVersion
}

private extension Nutrient {
    var healthKitType: HKQuantityType? {
        guard AppleHealthSample.supportedNutrients.contains(self) else { return nil }
        let identifier: HKQuantityTypeIdentifier
        switch self {
        case .calories: identifier = .dietaryEnergyConsumed
        case .protein: identifier = .dietaryProtein
        case .carbohydrates: identifier = .dietaryCarbohydrates
        case .fat: identifier = .dietaryFatTotal
        case .fiber: identifier = .dietaryFiber
        case .sodium: identifier = .dietarySodium
        case .caffeine: identifier = .dietaryCaffeine
        case .alcohol: identifier = .numberOfAlcoholicBeverages
        case .addedSugar: return nil
        }
        return HKQuantityType.quantityType(forIdentifier: identifier)
    }
}

private extension Symptom {
    var healthKitType: HKCategoryType? {
        HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: healthKitIdentifier))
    }
}
