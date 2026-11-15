import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Invokes the Edge Function with the public Supabase key and current account's
/// access token. Model selection and provider keys are server-side.
public struct SupabaseMealAnalysisClient: MealAnalysisClient {
    private let configuration: SupabaseConfiguration
    private let session: URLSession

    public init(configuration: SupabaseConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? SupabaseConfiguration.makeEphemeralSession(requestTimeout: 35, resourceTimeout: 40)
    }

    public func estimate(provider: AIProvider, input: MealAnalysisInput,
                         accessToken: String,
                         authorizeDispatch: @MainActor @Sendable () throws -> Void) async throws -> MealEstimate {
        let payload: AnalysisRequest
        switch input {
        case .image(let photo, let capturedAt, let notes):
            let timestamp = (capturedAt.timeIntervalSince1970 * 1_000).rounded(.down)
            guard timestamp >= 0, let capturedAtMs = Int64(exactly: timestamp) else { throw DraftIssue.invalidCaptureTime }
            let jpeg = try analysisJPEG(from: photo)
            payload = AnalysisRequest(provider: provider, captured_at_ms: capturedAtMs,
                                      photo_base64: jpeg.base64EncodedString(), notes: notes, description: nil)
        case .description(let description):
            payload = AnalysisRequest(provider: provider, captured_at_ms: nil,
                                      photo_base64: nil, notes: nil, description: description)
        }
        let endpoint = configuration.url.appendingPathComponent("functions/v1/analyze-meal")
        let request = configuration.jsonPost(to: endpoint, body: try JSONEncoder().encode(payload), accessToken: accessToken)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await dispatch(request, authorize: authorizeDispatch) }
        catch URLError.cancelled { throw CancellationError() }
        catch URLError.timedOut { throw AnalysisIssue.timedOut }
        catch is URLError { throw AnalysisIssue.unavailable }

        guard let http = response as? HTTPURLResponse else { throw AnalysisIssue.unavailable }
        let decoder = JSONDecoder()
        switch http.statusCode {
        case 200:
            guard let result = try? decoder.decode(AnalysisResponse.self, from: data),
                  let estimate = result.estimate(for: provider, expectsImage: payload.photo_base64 != nil)
            else { throw AnalysisIssue.invalidEstimate }
            return estimate
        case 401: throw AnalysisIssue.reauthenticationRequired
        case 403:
            let problem = try? decoder.decode(AnalysisProblem.self, from: data)
            throw problem?.error == "approval_required" ? AnalysisIssue.approvalRequired : AnalysisIssue.ownerRequired
        case 410: throw DraftIssue.photoExpired
        case 413: throw DraftIssue.invalidPhoto
        case 422:
            let problem = try? decoder.decode(AnalysisProblem.self, from: data)
            throw problem?.error == "refused" ? AnalysisIssue.refused : AnalysisIssue.invalidEstimate
        case 429:
            guard let problem = try? decoder.decode(AnalysisProblem.self, from: data),
                  problem.error == "allowance_exhausted", let reset = problem.reset_at,
                  let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(reset)
            else { throw AnalysisIssue.unavailable }
            throw AnalysisIssue.allowanceExhausted(resetAt: date)
        case 504: throw AnalysisIssue.timedOut
        case 400, 415:
            let problem = try? decoder.decode(AnalysisProblem.self, from: data)
            if problem?.error == "invalid_photo" { throw DraftIssue.invalidPhoto }
            throw AnalysisIssue.invalidRequest
        default: throw AnalysisIssue.unavailable
        }
    }

    @MainActor private func dispatch(_ request: URLRequest,
                                     authorize: @MainActor () throws -> Void) async throws -> (Data, URLResponse) {
        let (result, continuation) = AsyncThrowingStream<(Data, URLResponse), Error>.makeStream()
        let task = session.dataTask(with: request) { data, response, error in
            if let error { continuation.finish(throwing: error) }
            else if let data, let response {
                continuation.yield((data, response))
                continuation.finish()
            } else { continuation.finish(throwing: AnalysisIssue.unavailable) }
        }
        task.delegate = AnalysisRedirectPolicy()
        return try await withTaskCancellationHandler {
            // Check the active account and permission on the same actor that
            // resumes the prepared request, with no suspension between them.
            do {
                try Task.checkCancellation()
                try authorize()
            } catch {
                task.cancel()
                throw error
            }
            task.resume()
            var responses = result.makeAsyncIterator()
            guard let response = try await responses.next() else { throw CancellationError() }
            return response
        } onCancel: { task.cancel() }
    }

    /// Encodes one oriented JPEG at most 1600 px per side. Re-encoding pixels
    /// leaves the saved capture intact and excludes original EXIF/location data.
    private func analysisJPEG(from photo: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1_600,
              ] as CFDictionary) else { throw DraftIssue.invalidPhoto }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw DraftIssue.invalidPhoto }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), bytes.length <= 4 * 1_024 * 1_024
        else { throw DraftIssue.invalidPhoto }
        return bytes as Data
    }
}

private final class AnalysisRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct AnalysisRequest: Encodable {
    let provider: AIProvider
    let captured_at_ms: Int64?
    let photo_base64: String?
    let notes: String?
    let description: String?
}

private struct AnalysisProblem: Decodable {
    let error: String
    let reset_at: String?
}

private struct AnalysisResponse: Decodable {
    let items: [Item]
    let provenance: EstimateProvenance
    let image_kind: ImageKind?
    let order_time: String?

    enum ImageKind: String, Decodable { case foodPhoto = "food_photo", receipt }

    func estimate(for provider: AIProvider, expectsImage: Bool) -> MealEstimate? {
        guard provenance.provider == provider, !provenance.model.isEmpty,
              let version = provenance.version, !version.isEmpty else { return nil }
        let isV3 = version.hasPrefix("meal-estimate-v3/")
        if isV3 || version.hasPrefix("meal-estimate-v2/") {
            guard items.allSatisfy(\.hasV2Amounts) else { return nil }
        }
        let mealItems = items.map(\.item)
        var estimate = MealEstimate(items: mealItems, provenance: provenance)
        guard isV3 else { return expectsImage ? estimate : nil }
        guard items.allSatisfy(\.hasValidPurchase) else { return nil }

        let quantities = zip(mealItems, items).compactMap { item, response in
            response.purchased_quantity?.value.map { (item.id, $0) }
        }
        if !expectsImage {
            guard image_kind == nil, order_time == nil, quantities.isEmpty else { return nil }
            return estimate
        }
        guard let image_kind else { return nil }
        switch image_kind {
        case .foodPhoto:
            guard quantities.isEmpty, order_time == nil else { return nil }
            estimate.image = .foodPhoto
        case .receipt:
            estimate.image = .receipt(orderTime: order_time,
                                      purchasedQuantities: Dictionary(uniqueKeysWithValues: quantities))
        }
        return estimate
    }

    struct Item: Decodable {
        let name: String
        let description: String
        let grams: RequiredAmount
        let count: RequiredAmount?
        let purchased_quantity: RequiredAmount?
        let serving_description: String
        let nutrients: Amounts

        var hasV2Amounts: Bool { count != nil && nutrients.hasV2Amounts }
        var hasValidPurchase: Bool {
            guard let purchased_quantity else { return false }
            guard let quantity = purchased_quantity.value else { return true }
            return quantity > 0 && quantity == count?.value
        }

        private enum CodingKeys: String, CodingKey {
            case name, description, grams, count, purchased_quantity, serving_description, nutrients
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            name = try fields.decode(String.self, forKey: .name)
            description = try fields.decode(String.self, forKey: .description)
            grams = try fields.decode(RequiredAmount.self, forKey: .grams)
            count = try RequiredAmount.decodeIfDefined(in: fields, key: .count)
            purchased_quantity = try RequiredAmount.decodeIfDefined(in: fields, key: .purchased_quantity)
            serving_description = try fields.decode(String.self, forKey: .serving_description)
            nutrients = try fields.decode(Amounts.self, forKey: .nutrients)
        }

        var item: MealItem {
            MealItem(name: name, description: description,
                     portion: ConsumedPortion(grams: grams.value, servingDescription: serving_description, count: count?.value),
                     nutrients: NutrientAmounts(caloriesKcal: nutrients.calories_kcal.value,
                                                proteinGrams: nutrients.protein_g.value,
                                                carbohydratesGrams: nutrients.carbohydrates_g.value,
                                                fatGrams: nutrients.fat_g.value, fiberGrams: nutrients.fiber_g.value,
                                                sodiumMilligrams: nutrients.sodium_mg.value,
                                                alcoholGrams: nutrients.alcohol_g?.value,
                                                caffeineMilligrams: nutrients.caffeine_mg?.value,
                                                addedSugarGrams: nutrients.added_sugar_g?.value))
        }
    }

    struct Amounts: Decodable {
        let calories_kcal: RequiredAmount
        let protein_g: RequiredAmount
        let carbohydrates_g: RequiredAmount
        let fat_g: RequiredAmount
        let fiber_g: RequiredAmount
        let sodium_mg: RequiredAmount
        let alcohol_g: RequiredAmount?
        let caffeine_mg: RequiredAmount?
        let added_sugar_g: RequiredAmount?

        var hasV2Amounts: Bool { alcohol_g != nil && caffeine_mg != nil && added_sugar_g != nil }

        private enum CodingKeys: String, CodingKey {
            case calories_kcal, protein_g, carbohydrates_g, fat_g, fiber_g, sodium_mg
            case alcohol_g, caffeine_mg, added_sugar_g
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            calories_kcal = try fields.decode(RequiredAmount.self, forKey: .calories_kcal)
            protein_g = try fields.decode(RequiredAmount.self, forKey: .protein_g)
            carbohydrates_g = try fields.decode(RequiredAmount.self, forKey: .carbohydrates_g)
            fat_g = try fields.decode(RequiredAmount.self, forKey: .fat_g)
            fiber_g = try fields.decode(RequiredAmount.self, forKey: .fiber_g)
            sodium_mg = try fields.decode(RequiredAmount.self, forKey: .sodium_mg)
            alcohol_g = try RequiredAmount.decodeIfDefined(in: fields, key: .alcohol_g)
            caffeine_mg = try RequiredAmount.decodeIfDefined(in: fields, key: .caffeine_mg)
            added_sugar_g = try RequiredAmount.decodeIfDefined(in: fields, key: .added_sugar_g)
        }
    }

    /// Null is a meaningful value, but an omitted key is an invalid estimate.
    struct RequiredAmount: Decodable {
        let value: Double?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = container.decodeNil() ? nil : try container.decode(Double.self)
        }

        // Older Edge Function responses omit v2 fields. In v2, null is explicit.
        static func decodeIfDefined<Key: CodingKey>(in fields: KeyedDecodingContainer<Key>, key: Key) throws -> Self? {
            fields.contains(key) ? try fields.decode(Self.self, forKey: key) : nil
        }
    }
}
