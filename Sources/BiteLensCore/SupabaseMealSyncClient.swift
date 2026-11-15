import Foundation

public struct SupabaseMealSyncClient: MealSyncClient {
    private let configuration: SupabaseConfiguration
    private let session: URLSession

    public init(configuration: SupabaseConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? SupabaseConfiguration.makeEphemeralSession(requestTimeout: 20, resourceTimeout: 30)
    }

    public func sync(_ change: PendingMealChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        try await configuration.syncChange(MealChangeBody(change), rpc: "bitelens_sync_meal",
                                           accessToken: accessToken, session: session)
    }
}

extension SupabaseConfiguration {
    func syncChange(_ body: some Encodable, rpc: String, accessToken: String,
                    session: URLSession) async throws -> MealSyncAcknowledgement {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let endpoint = url.appendingPathComponent("rest/v1/rpc/\(rpc)")
        let request = jsonPost(to: endpoint, body: try encoder.encode(body), accessToken: accessToken)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MealSyncFailure.unavailable }
        switch response.statusCode {
        case 200..<300: return try JSONDecoder().decode(MealSyncAcknowledgement.self, from: data)
        case 401: throw MealSyncFailure.authenticationRequired
        case 400, 403, 409, 422: throw MealSyncFailure.rejected
        default: throw MealSyncFailure.unavailable
        }
    }
}

/// Map only the confirmed structured fields. This contract has no draft or photo properties.
private struct MealChangeBody: Encodable {
    let pMealId: UUID
    let pUserId: UUID
    let pRevision: Int
    let pMeal: CloudMeal?

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(pMealId, forKey: .pMealId)
        try fields.encode(pUserId, forKey: .pUserId)
        try fields.encode(pRevision, forKey: .pRevision)
        try fields.encode(pMeal, forKey: .pMeal)
    }

    private enum CodingKeys: String, CodingKey { case pMealId, pUserId, pRevision, pMeal }

    init(_ change: PendingMealChange) {
        pMealId = change.id
        pUserId = change.ownerID
        pRevision = change.revision
        switch change {
        case .save(let meal, _): pMeal = CloudMeal(meal)
        case .delete: pMeal = nil
        }
    }
}

private struct CloudMeal: Encodable {
    let id: UUID
    let userId: UUID
    let mealAtEpochSeconds: Double
    let localDate: String
    let timeZone: String
    let confirmedAtEpochSeconds: Double
    let notes: String
    let items: [CloudMealItem]
    let estimateProvider: AIProvider?
    let estimateModel: String?
    let estimateVersion: String?

    init(_ meal: MealRecord) {
        id = meal.id
        userId = meal.ownerID
        mealAtEpochSeconds = meal.mealTime.instant.timeIntervalSince1970
        localDate = meal.mealTime.localDate
        timeZone = meal.mealTime.timeZoneIdentifier
        confirmedAtEpochSeconds = meal.confirmedAt.timeIntervalSince1970
        notes = meal.notes
        items = meal.items.map(CloudMealItem.init)
        estimateProvider = meal.estimateProvenance?.provider
        estimateModel = meal.estimateProvenance?.model
        estimateVersion = meal.estimateProvenance?.version
    }
}

private struct CloudMealItem: Encodable {
    let id: UUID
    let values: CloudMealItemValues
    let itemOrigin: MealItemOrigin?
    let originalItemEstimate: CloudMealItemValues?

    init(_ item: MealItem) {
        id = item.id
        values = CloudMealItemValues(name: item.name, description: item.description,
                                    portion: item.portion, nutrients: item.nutrients)
        itemOrigin = item.origin
        originalItemEstimate = item.originalEstimate.map {
            CloudMealItemValues(name: $0.name, description: $0.description, portion: $0.portion, nutrients: $0.nutrients)
        }
    }

    private enum CodingKeys: String, CodingKey { case id, itemOrigin, originalItemEstimate }

    func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id)
        try fields.encodeIfPresent(itemOrigin, forKey: .itemOrigin)
        try fields.encodeIfPresent(originalItemEstimate, forKey: .originalItemEstimate)
    }
}

private struct CloudMealItemValues: Encodable {
    let name: String
    let description: String
    let portionGrams: Double?
    let servingDescription: String
    let consumedCount: Double?
    let caloriesKcal: Double?
    let proteinGrams: Double?
    let carbohydratesGrams: Double?
    let fatGrams: Double?
    let fiberGrams: Double?
    let sodiumMilligrams: Double?
    let alcoholGrams: Double?
    let caffeineMilligrams: Double?
    let addedSugarGrams: Double?

    init(name: String, description: String, portion: ConsumedPortion, nutrients: NutrientAmounts) {
        self.name = name
        self.description = description
        portionGrams = portion.grams
        servingDescription = portion.servingDescription
        consumedCount = portion.count
        caloriesKcal = nutrients.caloriesKcal
        proteinGrams = nutrients.proteinGrams
        carbohydratesGrams = nutrients.carbohydratesGrams
        fatGrams = nutrients.fatGrams
        fiberGrams = nutrients.fiberGrams
        sodiumMilligrams = nutrients.sodiumMilligrams
        alcoholGrams = nutrients.alcoholGrams
        caffeineMilligrams = nutrients.caffeineMilligrams
        addedSugarGrams = nutrients.addedSugarGrams
    }
}
