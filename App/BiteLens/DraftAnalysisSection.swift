import BiteLensCore
import SwiftUI

struct DraftAnalysisSection: View {
    let workflow: MealWorkflow
    let draft: MealDraft
    @State private var attempt: AnalysisRequest?
    @State private var errorMessage: String?
    @State private var pendingReplacement: AIProvider?
    @State private var pendingPermission: AnalysisRequest?

    private struct AnalysisRequest: Equatable {
        let provider: AIProvider
        let draft: MealDraft
        let accountActivationID: UUID
    }

    private var hasReviewedItems: Bool { draft.review?.items.isEmpty == false }
    private var isAnalyzing: Bool { attempt != nil || workflow.isAnalyzingDraft(draft.id) }
    private var isExpired: Bool { draft.photo.map { workflow.isPhotoExpired($0) } ?? false }

    var body: some View {
        Section {
            if isAnalyzing {
                ProgressView("Estimating meal…")
            } else if isExpired {
                Text("This image has expired. You can still review or enter the meal items.")
                    .foregroundStyle(.secondary)
            } else if draft.photo == nil, draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Describe your food and drinks, including portions if you know them.")
                    .foregroundStyle(.secondary)
            } else if let provider = workflow.selectedProvider {
                Button(analysisTitle(provider)) {
                    startAnalysis(provider)
                }
                .accessibilityIdentifier("analyze-meal")
                if errorMessage != nil || hasReviewedItems {
                    Menu("Use a different provider") {
                        ForEach(AIProvider.allCases.filter { $0 != provider }, id: \.self) { other in
                            Button("Analyze with \(other.displayName)") { startAnalysis(other) }
                        }
                    }
                }
            } else {
                Text("Choose an analysis provider in Settings. You can also enter the meal items here.")
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Meal estimate")
        } footer: {
            if workflow.isBeta, let provider = workflow.selectedProvider, !isExpired {
                Text(sharingDisclosure(draft, provider: provider))
            } else if draft.photo == nil {
                Text("Analyze sends your meal description to the selected AI provider.")
            } else if !isExpired {
                Text("Analyze sends this image, including visible receipt details, to the selected AI provider.")
            }
        }
        .confirmationDialog("Replace the current meal items?", isPresented: Binding(
            get: { pendingReplacement != nil },
            set: { if !$0 { pendingReplacement = nil } }
        ), titleVisibility: .visible, presenting: pendingReplacement) { provider in
            Button("Analyze with \(provider.displayName)") { requestAnalysis(provider) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("A successful estimate replaces the current items and corrections. You can review it before confirming.")
        }
        .alert("Share with \(pendingPermission?.provider.displayName ?? "AI provider")?", isPresented: Binding(
            get: { pendingPermission != nil },
            set: { if !$0 { pendingPermission = nil } }
        ), presenting: pendingPermission) { request in
            Button("Allow and analyze") {
                guard isCurrent(request) else { return }
                workflow.setAnalysisPermission(for: request.provider, allowed: true)
                attempt = request
            }
            Button("Not now", role: .cancel) {}
        } message: { request in
            Text(sharingDisclosure(request.draft, provider: request.provider) + " You can use this provider for future meal images, notes or descriptions and withdraw permission in Settings.")
        }
        .task(id: attempt) {
            guard let request = attempt else { return }
            defer { attempt = nil }
            guard isCurrent(request) else { return }
            errorMessage = nil
            do { try await workflow.analyzeDraft(request.draft.id, provider: request.provider) }
            catch is CancellationError {}
            catch { errorMessage = analysisMessage(error) }
        }
    }

    private func startAnalysis(_ provider: AIProvider) {
        if hasReviewedItems { pendingReplacement = provider }
        else { requestAnalysis(provider) }
    }

    private func requestAnalysis(_ provider: AIProvider) {
        let request = AnalysisRequest(provider: provider, draft: draft, accountActivationID: workflow.accountActivationID)
        guard isCurrent(request) else { return }
        if workflow.hasAnalysisPermission(for: provider) { attempt = request }
        else { pendingPermission = request }
    }

    private func isCurrent(_ request: AnalysisRequest) -> Bool {
        workflow.accountActivationID == request.accountActivationID && workflow.drafts.contains(request.draft)
    }

    private func sharingDisclosure(_ draft: MealDraft, provider: AIProvider) -> String {
        if draft.photo == nil { return "Analysis sends your meal description to \(provider.displayName)." }
        let image = "this meal image, including any visible receipt details"
        let includesNotes = !draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return "Analysis sends \(image)\(includesNotes ? ", and your notes" : "") to \(provider.displayName)."
    }

    private func analysisTitle(_ provider: AIProvider) -> String {
        if errorMessage != nil { return "Retry with \(provider.displayName)" }
        if hasReviewedItems { return "Analyze again with \(provider.displayName)" }
        return "Analyze with \(provider.displayName)"
    }

    private func analysisMessage(_ error: Error) -> String {
        switch error as? AnalysisIssue {
        case .timedOut: return "Analysis timed out. Try again or enter the meal items manually."
        case .refused, .invalidEstimate: return "Analysis couldn't produce a usable estimate. Try adding more detail or enter the meal items manually."
        case .itemsNotIdentified: return "Analysis couldn't identify any food or drinks. You can add them manually."
        case .unavailable: return "Analysis is unavailable. Check your connection and try again, or enter the meal items manually."
        case .notesTooLong: return draft.photo == nil
            ? "Shorten the meal description to 2,000 characters before analysis."
            : "Shorten the notes to 2,000 characters before analysis."
        case .descriptionRequired: return "Describe your meal before analyzing it."
        case .draftChanged: return "The draft changed during analysis. Your changes are saved. Analyze again when ready."
        case .invalidRequest: return draft.photo == nil
            ? "Analysis couldn't read the description. Try again or enter the meal items manually."
            : "Analysis couldn't read the request. Check your iPhone's date and time and try again."
        case .reauthenticationRequired: return "Sign in again from the camera screen to reconnect. You can still edit or confirm the meal here."
        case .ownerRequired: return "Analysis requires the approved owner's account."
        case .approvalRequired: return "Analysis requires an approved BiteLens Beta account. You can still enter the meal items manually."
        case .allowanceExhausted(let reset):
            return "You’ve reached the daily Meal Estimate limit. Try again at \(reset.formatted(date: .abbreviated, time: .shortened)). You can still log meals manually."
        case .permissionRequired: return "Allow sharing with the selected provider to analyze this meal."
        case .alreadyRunning, .providerRequired, nil: break
        }
        if let issue = error as? WorkflowIssue {
            switch issue {
            case .signInRequired: return "Sign in again from the camera screen to reconnect. Your draft is saved."
            case .authenticationUnavailable: return "Check your connection and try again, or enter the meal items manually."
            default: break
            }
        }
        if error as? DraftIssue == .photoUnavailable {
            return draft.canRetakePhoto
                ? "The photo is unavailable. Retake it or enter the meal items manually."
                : "The image is unavailable. You can still review or enter the meal items."
        }
        return error.draftMessage
    }
}
