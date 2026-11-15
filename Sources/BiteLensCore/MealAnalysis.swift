import Foundation

public protocol MealAnalysisClient: Sendable {
    /// Call the authorization check immediately before dispatching the request.
    func estimate(provider: AIProvider, input: MealAnalysisInput,
                  accessToken: String,
                  authorizeDispatch: @MainActor @Sendable () throws -> Void) async throws -> MealEstimate
}

public enum MealAnalysisInput: Sendable {
    case image(Data, capturedAt: Date, notes: String)
    case description(String)
}

public enum AnalysisIssue: Error, Equatable, Sendable {
    case providerRequired
    case permissionRequired
    case alreadyRunning
    case draftChanged
    case reauthenticationRequired
    case ownerRequired
    case approvalRequired
    case allowanceExhausted(resetAt: Date)
    case unavailable
    case timedOut
    case refused
    case invalidEstimate
    case itemsNotIdentified
    case invalidRequest
    case notesTooLong
    case descriptionRequired
}

extension MealWorkflow {
    public func isAnalyzingDraft(_ id: UUID) -> Bool { analyzingDraftIDs.contains(id) }

    /// Uses the explicit selection at the start of the attempt. Only a successful,
    /// still-current result can replace review items, and it stays unconfirmed.
    public func analyzeDraft(_ id: UUID, provider requestedProvider: AIProvider? = nil) async throws {
        let draft = localMeals.drafts[try draftIndex(for: id)]
        guard let provider = requestedProvider ?? selectedProvider else { throw AnalysisIssue.providerRequired }
        guard hasAnalysisPermission(for: provider) else { throw AnalysisIssue.permissionRequired }
        guard let analysis else { throw AnalysisIssue.unavailable }
        if let photo = draft.photo, isPhotoExpired(photo) {
            resumeLocalWork()
            throw DraftIssue.photoExpired
        }
        guard draft.notes.utf16.count <= 2_000 else { throw AnalysisIssue.notesTooLong }
        if draft.photo == nil, draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AnalysisIssue.descriptionRequired
        }
        guard analyzingDraftIDs.insert(id).inserted else { throw AnalysisIssue.alreadyRunning }
        let activation = accountActivationID
        defer { if accountActivationID == activation { analyzingDraftIDs.remove(id) } }

        let generation = authenticationGeneration
        let token = try await accessToken()
        try checkAnalysisIsCurrent(draft, generation: generation)
        let input: MealAnalysisInput
        if let photo = draft.photo {
            input = .image(try readPhoto(photo), capturedAt: photo.retentionStartedAt, notes: draft.notes)
        } else {
            input = .description(draft.notes)
        }
        var estimate: MealEstimate
        do {
            estimate = try await analysis.estimate(provider: provider, input: input, accessToken: token) {
                try self.checkAnalysisIsCurrent(draft, generation: generation)
                guard self.hasAnalysisPermission(for: provider) else { throw AnalysisIssue.permissionRequired }
                if let photo = draft.photo, self.isPhotoExpired(photo) { throw DraftIssue.photoExpired }
            }
        } catch AnalysisIssue.reauthenticationRequired {
            if authenticationGeneration == generation, access == .owner { requireCloudReauthentication() }
            throw AnalysisIssue.reauthenticationRequired
        }
        try checkAnalysisIsCurrent(draft, generation: generation)
        guard estimate.provenance.provider == provider else { throw AnalysisIssue.invalidEstimate }
        if draft.photo == nil {
            guard estimate.image == nil else { throw AnalysisIssue.invalidEstimate }
            guard !estimate.items.isEmpty else { throw AnalysisIssue.itemsNotIdentified }
        }

        var proposed = localMeals.drafts[try draftIndex(for: id)]
        proposed.applyImageTimeSuggestion(estimate.image, now: now())
        if proposed.needsMealTime, case .image(let bytes, _, _) = input {
            if let headerTime = await receiptEmailHeader(bytes) {
                let quantities: [UUID: Double]
                if case .receipt(_, let purchased) = estimate.image { quantities = purchased }
                else { quantities = [:] }
                estimate.image = .receipt(orderTime: headerTime, purchasedQuantities: quantities)
            }
            try checkAnalysisIsCurrent(draft, generation: generation)
        }
        do { try applyEstimate(estimate, to: id) }
        catch is MealReviewIssue { throw AnalysisIssue.invalidEstimate }
        if estimate.items.isEmpty { throw AnalysisIssue.itemsNotIdentified }
    }

    /// Repairs a reviewed draft whose estimate did not include a usable time.
    public func suggestReceiptTimeForReviewedDraft(_ id: UUID) async {
        let activation = accountActivationID
        guard let original = drafts.first(where: { $0.id == id }), original.needsMealTime,
              original.review?.estimateProvenance != nil, let data = try? photoData(for: id),
              let time = await receiptEmailHeader(data), !Task.isCancelled,
              accountActivationID == activation,
              let index = try? draftIndex(for: id) else { return }
        var updated = localMeals
        guard updated.drafts[index].photo == original.photo, updated.drafts[index].needsMealTime else { return }
        updated.drafts[index].applyImageTimeSuggestion(.receipt(orderTime: time, purchasedQuantities: [:]), now: now())
        if updated.drafts[index].hasSuggestedMealTime { try? saveLocalMeals(updated) }
    }

    private func checkAnalysisIsCurrent(_ original: MealDraft, generation: Int) throws {
        try Task.checkCancellation()
        guard generation == authenticationGeneration,
              let current = drafts.first(where: { $0.id == original.id }),
              current.photo == original.photo, current.notes == original.notes, current.review == original.review
        else { throw AnalysisIssue.draftChanged }
    }
}
