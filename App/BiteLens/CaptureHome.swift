import BiteLensCore
import PhotosUI
import SwiftUI
import UIKit

private enum CaptureSheet: Identifiable {
    case drafts
    case history
    case draft(UUID)
    case signIn
    case observation
    var id: String {
        switch self {
        case .drafts: "drafts"
        case .history: "history"
        case .draft(let id): id.uuidString
        case .signIn: "sign-in"
        case .observation: "observation"
        }
    }
}

struct CaptureHome: View {
    let workflow: MealWorkflow
    var cameraRequest: UUID? = nil
    var linkedUrgeID: UUID? = nil
    var photoOnly = false
    @State private var presented: CaptureSheet?
    @State private var errorMessage: String?
    @State private var showPhotoPicker = false
    @State private var selectedImage: PhotosPickerItem?
    @State private var confirmedMeal = false
    @Environment(\.dismiss) private var dismiss

    private var isHome: Bool { linkedUrgeID == nil && !photoOnly }
    private var title: String {
        if photoOnly { return "Meal from Photo" }
        return isHome ? "BiteLens" : "Log a linked meal"
    }

    var body: some View {
        let account = workflow.accountActivationID
        let enterManually: (() -> Void)? = photoOnly ? nil : { startManualDraft() }
        MealCameraView(isActive: presented == nil && !showPhotoPicker && selectedImage == nil,
                       isImporting: selectedImage != nil, chooseFromPhotos: { showPhotoPicker = true },
                       enterMealManually: enterManually) { capture in
            guard workflow.accountActivationID == account else { return }
            do {
                let draft = try workflow.captureMeal(photoData: capture.data, capturedAt: capture.capturedAt,
                                                     timeZone: capture.timeZone, linkingUrgeID: linkedUrgeID)
                errorMessage = nil
                presented = .draft(draft.id)
            } catch { errorMessage = error.draftMessage }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if workflow.cloudStatus == .reauthenticationRequired {
                Button("Sign in again to reconnect") { presented = .signIn }
                    .font(.footnote).padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
            } else if workflow.cloudStatus == .offline {
                Label("Offline · capture still works", systemImage: "wifi.slash")
                    .font(.footnote).padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if isHome {
                    Button { presented = .drafts } label: {
                        Label("Drafts (\(workflow.drafts.count))", systemImage: "tray.full")
                    }
                    .accessibilityIdentifier("pending-drafts")
                    Button { presented = .history } label: {
                        Label("History", systemImage: "clock")
                    }
                    .accessibilityIdentifier("meal-history")
                } else {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isHome {
                    ObservationLogButton { presented = .observation }
                    NavigationLink(value: CaptureDestination.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        }
        .onChange(of: cameraRequest) { _, _ in
            presented = nil
            errorMessage = nil
            showPhotoPicker = false
            selectedImage = nil
        }
        .onChange(of: workflow.sharedDraftToOpen, initial: true) { _, id in
            guard isHome, let id else { return }
            showPhotoPicker = false
            selectedImage = nil
            errorMessage = nil
            presented = .draft(id)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedImage,
                      matching: .images, preferredItemEncoding: .current)
        .task(id: selectedImage) {
            guard let selection = selectedImage else { return }
            await importImage(selection)
        }
        .sheet(item: $presented, onDismiss: {
            if !isHome, confirmedMeal { dismiss() }
        }) { sheet in
            NavigationStack {
                switch sheet {
                case .drafts: PendingDraftsView(workflow: workflow)
                case .history: MealHistoryView(workflow: workflow)
                case .draft(let id):
                    DraftDetail(workflow: workflow, id: id) {
                        confirmedMeal = true
                        presented = nil
                    }
                    .onAppear { workflow.didOpenSharedDraft(id) }
                case .signIn: SignInView(workflow: workflow, reauthenticating: true)
                case .observation: NewObservationView(workflow: workflow)
                }
            }
        }
        .alert("Couldn't start meal draft", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 { errorMessage = nil }
        })) {
            Button("Try again", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func startManualDraft() {
        do {
            let draft = try workflow.startManualDraft(linkingUrgeID: linkedUrgeID)
            errorMessage = nil
            presented = .draft(draft.id)
        } catch { errorMessage = error.draftMessage }
    }

    private func importImage(_ selection: PhotosPickerItem) async {
        let account = workflow.accountActivationID
        defer { if selectedImage == selection { selectedImage = nil } }
        do {
            let data = try await selection.loadTransferable(type: Data.self)
            try Task.checkCancellation()
            guard workflow.accountActivationID == account, selectedImage == selection else { return }
            guard let data else { throw DraftIssue.invalidPhoto }
            let draft = try workflow.importMealImage(data, linkingUrgeID: linkedUrgeID)
            errorMessage = nil
            if presented == nil { presented = .draft(draft.id) }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, workflow.accountActivationID == account, selectedImage == selection else { return }
            errorMessage = error is DraftIssue || error is WorkflowIssue || error is ObservationIssue
                ? error.draftMessage : "Photos couldn't load this image. Check your connection and try again."
        }
    }
}

struct MealCameraView: View {
    var isActive = true
    var isImporting = false
    var chooseFromPhotos: (() -> Void)?
    var enterMealManually: (() -> Void)?
    let onCapture: @MainActor (CameraCapture) -> Void
    @StateObject private var camera = MealCameraModel()
    @Environment(\.scenePhase) private var scenePhase
    private var shouldRun: Bool { isActive && scenePhase == .active }
    private var suppressesCamera: Bool {
        #if DEBUG
        UITestMode.isEnabled
        #else
        false
        #endif
    }

    var body: some View {
        let showsPreview = shouldRun && camera.status == .ready
        ZStack {
            Color.black.ignoresSafeArea()
            if !suppressesCamera {
                // Keep the layer mounted across sheets and camera pauses. Removing it
                // can make AVFoundation rebuild the capture graph during navigation.
                CameraPreview(device: camera.device, isVisible: showsPreview)
                    .ignoresSafeArea(edges: .bottom)
                    .opacity(showsPreview ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Meal camera preview")
                    .accessibilityHidden(!showsPreview)
            }
            VStack(spacing: 20) {
                Spacer()
                if suppressesCamera {
                    Text("Camera checks stay on a device.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("camera-not-used")
                } else if camera.status == .denied {
                    ContentUnavailableView {
                        Label("Allow camera access", systemImage: "camera.fill")
                    } description: {
                        Text("Allow BiteLens to use your camera in Settings. Your pending drafts stay saved.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(.borderedProminent)
                    }
                } else if camera.status == .unavailable {
                    ContentUnavailableView {
                        Label("Camera unavailable", systemImage: "camera")
                    } description: {
                        Text("Try restarting the camera. You can still open your pending drafts.")
                    } actions: {
                        Button("Restart camera") { Task { await camera.start() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if camera.status == .starting {
                    ProgressView("Starting camera…")
                }
                Spacer()
                if let message = camera.message {
                    Text(message).font(.callout).multilineTextAlignment(.center)
                    Button("Restart camera") { Task { await camera.start() } }
                }
                Text("Photograph your meal").font(.headline)
                Text("Saved privately on this iPhone, even offline.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.8))
                Button { camera.capture(onCapture: onCapture) } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(.white).frame(width: 62, height: 62)
                        if camera.isCapturing { ProgressView().tint(.black) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(camera.status != .ready || camera.isCapturing || !shouldRun)
                .opacity(camera.status == .ready ? 1 : 0.4)
                .accessibilityLabel("Capture meal")
                .accessibilityIdentifier("capture-meal")
                if isImporting {
                    ProgressView("Importing image…")
                } else if let chooseFromPhotos {
                    Button(action: chooseFromPhotos) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(camera.isCapturing)
                    .accessibilityIdentifier("choose-meal-image")
                }
                if let enterMealManually {
                    Button(action: enterMealManually) {
                        Label("Enter meal manually", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.bordered)
                    .disabled(camera.isCapturing || isImporting)
                    .accessibilityIdentifier("enter-meal-manually")
                }
            }
            .padding(24)
            .foregroundStyle(.white)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
        }
        .task(id: shouldRun) {
            #if DEBUG
            if UITestMode.isEnabled { return }
            #endif
            if shouldRun { await camera.start() }
            else { camera.stop() }
        }
        .onDisappear {
            #if DEBUG
            if UITestMode.isEnabled { return }
            #endif
            camera.stop()
        }
    }
}

private struct PendingDraftsView: View {
    let workflow: MealWorkflow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if workflow.drafts.isEmpty {
                ContentUnavailableView("No pending drafts", systemImage: "tray",
                                       description: Text("Take a photo, choose an image, or enter a meal manually."))
                    .accessibilityIdentifier("no-pending-drafts")
            }
            ForEach(workflow.drafts.reversed()) { draft in
                NavigationLink {
                    DraftDetail(workflow: workflow, id: draft.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.needsMealTime ? "Meal time needed" : draft.mealTime.displayDate).font(.headline)
                        Text(draft.notes.isEmpty ? "Meal draft" : draft.notes).lineLimit(2)
                        let expired = draft.photo.map { workflow.isPhotoExpired($0) } ?? false
                        Text(expired ? "Image expired · not logged" : "Saved locally · not logged")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Pending drafts")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct DraftDetail: View {
    let workflow: MealWorkflow
    let id: UUID
    var onMealConfirmed: (() -> Void)? = nil
    @State private var errorMessage: String?
    @State private var showRetake = false
    @State private var confirmDiscard = false
    @State private var notesFrame = CGRect.null
    @FocusState private var notesFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var draft: MealDraft? { workflow.drafts.first { $0.id == id } }

    var body: some View {
        Group {
            if let draft {
                Form {
                    if let photo = draft.photo {
                        Section {
                            MealImagePreview(workflow: workflow, photo: photo, isVisible: !showRetake) {
                                try workflow.photoData(for: id)
                            }
                            if draft.canRetakePhoto {
                                Button("Retake photo") { showRetake = true }
                            }
                        }
                    }
                    Section(draft.photo == nil ? "Meal description" : "Optional context") {
                        TextField(draft.photo == nil ? "e.g. 2 scrambled eggs and 1 slice of toast" : "Ingredients, servings, or other notes",
                                  text: Binding(get: { draft.notes }, set: { notes in
                            save { try workflow.updateDraftNotes(id, notes: notes) }
                        }), axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("draft-notes")
                        .focused($notesFocused)
                        .onGeometryChange(for: CGRect.self) { geometry in
                            geometry.frame(in: .global)
                        } action: { frame in
                            notesFrame = frame
                        }
                    }
                    DraftAnalysisSection(workflow: workflow, draft: draft)
                    Section("Meal time") {
                        if draft.needsMealTime {
                            Text("Choose when you ate before confirming. Analysis may suggest a time from the image.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if draft.usesImportDateForMealTime {
                            Text("The image shows a time. The date is set to the day you imported it.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if draft.hasSuggestedMealTime {
                            Text("Suggested from the image. Adjust it to when you ate.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        MealTimeFields(time: Binding(get: { draft.mealTime }, set: { time in
                            saveMealTime(time)
                        }))
                        if draft.needsMealTime {
                            Button("Use displayed time") { saveMealTime(draft.mealTime) }
                        }
                    }
                    Section {
                        if let provenance = draft.review?.estimateProvenance {
                            Text(provenance.reviewLabel).font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(draft.review?.items ?? []) { item in
                            NavigationLink {
                                MealItemEditor(initialItem: item, isNew: false, save: saveItem,
                                               remove: { try removeItem(item.id) })
                            } label: {
                                MealItemReviewLabel(item: item, purchasedQuantity: draft.review?.purchasedQuantity(for: item.id))
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    save { try removeItem(item.id) }
                                }
                            }
                        }
                        NavigationLink {
                            MealItemEditor(initialItem: MealItem(name: ""), isNew: true, save: saveItem)
                        } label: {
                            Label("Add food or drink", systemImage: "plus")
                        }
                    } header: {
                        Text("Meal items")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if draft.review?.items.isEmpty == false {
                                Text("Swipe left on an item to remove it.")
                            }
                            Text("You can also add meal items directly.")
                        }
                    }
                    if let review = draft.review, !review.items.isEmpty {
                        Section("Meal nutrient totals") {
                            NutrientTotalRows(totals: review.nutrientTotals)
                        }
                    }
                    Section {
                        Button("Confirm meal") {
                            save {
                                try workflow.confirmMeal(id)
                                if let onMealConfirmed { onMealConfirmed() }
                                else { dismiss() }
                            }
                        }
                        .disabled(draft.needsMealTime || draft.review?.items.isEmpty != false)
                        .accessibilityIdentifier("confirm-meal")
                        Text("Confirmation logs this meal and updates your totals on this iPhone, even offline.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        Label("Draft saved on this iPhone", systemImage: "checkmark.circle")
                        Button("Discard draft", role: .destructive) { confirmDiscard = true }
                    }
                    if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
                }
                .uiTestKeyboardDismiss { notesFocused = false }
                .gesture(DraftFormTap { location in
                    if notesFocused, !notesFrame.contains(location) { notesFocused = false }
                })
            } else {
                ContentUnavailableView("Draft unavailable", systemImage: "tray")
            }
        }
        .navigationTitle("Meal draft")
        .task(id: draft?.review?.estimateProvenance == nil || draft?.needsMealTime != true ? nil : draft?.photo?.id) {
            await workflow.suggestReceiptTimeForReviewedDraft(id)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onChange(of: draft?.canRetakePhoto) { _, canRetake in
            if canRetake != true { showRetake = false }
        }
        .fullScreenCover(isPresented: $showRetake) {
            NavigationStack {
                MealCameraView { capture in
                    do {
                        try workflow.retakePhoto(for: id, photoData: capture.data, capturedAt: capture.capturedAt)
                        errorMessage = nil
                    } catch { errorMessage = error.draftMessage }
                    showRetake = false
                }
                .navigationTitle("Retake meal photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showRetake = false } } }
            }
        }
        .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard draft", role: .destructive) {
                do { try workflow.discardDraft(id); dismiss() }
                catch { errorMessage = error.draftMessage }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func saveMealTime(_ time: MealTime) {
        if let zone = TimeZone(identifier: time.timeZoneIdentifier) {
            save { try workflow.setMealTime(id, instant: time.instant, timeZone: zone) }
        }
    }

    private func saveItem(_ item: MealItem) throws {
        var items = draft?.review?.items ?? []
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
        try workflow.updateDraftItems(id, items: items)
    }

    private func removeItem(_ itemID: UUID) throws {
        let items = draft?.review?.items ?? []
        try workflow.updateDraftItems(id, items: items.filter { $0.id != itemID })
    }

    private func save(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil }
        catch { errorMessage = error.draftMessage }
    }
}

private struct DraftFormTap: UIGestureRecognizerRepresentable {
    let onTap: (CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        // Observe the tap without taking it away from a form control.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { onTap(context.converter.location(in: .global)) }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

extension Error {
    var draftMessage: String {
        if self as? WorkflowIssue == .accessDenied {
            return "Sign in with the approved owner's account to access your drafts."
        }
        if self as? ObservationIssue == .notFound || self as? ObservationIssue == .urgeRequired {
            return "That urge is no longer available."
        }
        switch self as? MealReviewIssue {
        case .itemsRequired: return "Add at least one food or drink to confirm this meal."
        case .itemNameRequired: return "Enter a name for each food or drink."
        case .invalidAmount: return "Use non-negative numbers for amounts, or leave unknown values blank."
        case .invalidCount: return "Enter a count greater than zero or leave it blank."
        case .loggedMealNotFound: return "That meal is no longer available."
        default: break
        }
        return switch self as? DraftIssue {
        case .photoExpired: "This image has expired. You can still enter the meal manually."
        case .invalidPhoto, .invalidCaptureTime: "Couldn't use that image. Take a photo or choose another image."
        case .retakeAfterEstimate: "This draft already has a meal estimate. Your original photo and review are saved."
        case .retakeImportedImage: "Choose another image from Photos to start a new draft."
        case .mealTimeRequired: "Set the meal time before confirming."
        default: "Couldn't save your draft securely. Unlock your iPhone, check available storage, and try again. Your saved drafts stay here."
        }
    }
}
