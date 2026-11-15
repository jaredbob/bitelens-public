import BiteLensCore
import SwiftUI
import UIKit

struct MealImagePreview: View {
    let workflow: MealWorkflow
    let photo: StoredMealImage
    var isVisible = true
    let read: () throws -> Data
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var previewHeight = 220.0
    @State private var preview: UIImage?
    @State private var previewID: UUID?
    @State private var showFullScreen = false

    private var isActive: Bool { scenePhase == .active && isVisible }

    var body: some View {
        let isExpired = workflow.isPhotoExpired(photo)
        let canPreview = isActive && !isExpired
        // The form sizes this container. Loading the photo must not resize its row.
        Color.clear
            .frame(height: previewHeight)
            .overlay {
                if canPreview, previewID == photo.id, let preview {
                    Button { showFullScreen = true } label: {
                        Image(uiImage: preview).resizable().scaledToFit()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View meal image full screen")
                } else {
                    VStack(spacing: 8) {
                        Label(isExpired ? "Image expired" : "Image unavailable", systemImage: "photo")
                            .font(.headline)
                        Text("The meal information is still saved.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
            }
            .task(id: PreviewIdentity(photoID: photo.id, active: canPreview)) {
                clearPreview()
                guard canPreview, !Task.isCancelled else { return }
                preview = (try? read()).flatMap(UIImage.init(data:))
                previewID = photo.id
            }
            .onDisappear { clearPreview() }
            .fullScreenCover(isPresented: $showFullScreen) {
                FullScreenMealImage(workflow: workflow, photo: photo, read: read)
            }
    }

    private func clearPreview() {
        preview = nil
        previewID = nil
    }

    private struct PreviewIdentity: Hashable {
        let photoID: UUID
        let active: Bool
    }
}

private struct FullScreenMealImage: View {
    let workflow: MealWorkflow
    let photo: StoredMealImage
    let read: () throws -> Data
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        let isExpired = workflow.isPhotoExpired(photo)
        let canDisplay = scenePhase == .active && workflow.access == .owner && !isExpired
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if canDisplay, let image {
                ZoomableMealImage(image: image)
            } else if scenePhase == .active {
                ContentUnavailableView(isExpired ? "Image expired" : "Image unavailable", systemImage: "photo")
            }
            HStack {
                if canDisplay, let image {
                    let photo = Image(uiImage: image)
                    ShareLink(item: photo, preview: SharePreview("Meal photo", image: photo)) {
                        Label("Share photo", systemImage: "square.and.arrow.up")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                }
                Spacer()
                Button("Close image", systemImage: "xmark.circle.fill") { dismiss() }
                    .font(.largeTitle)
                    .frame(width: 44, height: 44)
            }
            .labelStyle(.iconOnly)
            .shadow(radius: 4)
            .padding()
        }
        .preferredColorScheme(.dark)
        .task(id: canDisplay) {
            image = canDisplay ? (try? read()).flatMap(UIImage.init(data:)) : nil
        }
        .onDisappear { image = nil }
    }
}

private struct ZoomableMealImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ImageScrollView { ImageScrollView(image: image) }
    func updateUIView(_ view: ImageScrollView, context: Context) {}

    final class ImageScrollView: UIScrollView, UIScrollViewDelegate {
        private let imageView: UIImageView
        private var fittedBounds: CGSize = .zero

        init(image: UIImage) {
            imageView = UIImageView(image: image)
            super.init(frame: .zero)
            delegate = self
            maximumZoomScale = 5
            contentInsetAdjustmentBehavior = .never
            imageView.isAccessibilityElement = true
            imageView.accessibilityLabel = "Meal image"
            addSubview(imageView)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let size = imageView.image?.size, bounds.width > 0, bounds.height > 0,
                  fittedBounds != bounds.size else { return }
            fittedBounds = bounds.size
            zoomScale = 1
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            centerImage()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

        private func centerImage() {
            let x = max(0, (bounds.width - contentSize.width) / 2)
            let y = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }
    }
}

struct MealItemEditor: View {
    let initialItem: MealItem
    let isNew: Bool
    let save: (MealItem) throws -> Void
    var remove: (() throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var item: MealItem?
    @State private var weight: String?
    @State private var count: String?
    @State private var amounts: [Nutrient: String] = [:]
    @State private var portionEditStart: (field: AmountField, item: MealItem)?
    @FocusState private var focusedAmount: AmountField?
    @State private var errorMessage: String?

    private enum AmountField: Hashable {
        case weight, count
        case nutrient(Nutrient)
    }

    var body: some View {
        Form {
            if let itemBinding = Binding($item) {
                Section("Food or drink") {
                    TextField("Name", text: itemBinding.name)
                    TextField("Description (optional)", text: itemBinding.description, axis: .vertical)
                }
                Section {
                    amountField("Weight (g)", text: Binding(
                        get: { weight ?? amountText(item?.portion.grams) },
                        set: { updatePortion(.weight, text: $0) }
                    ), field: .weight)
                    amountField("Count (optional)", text: Binding(
                        get: { count ?? amountText(item?.portion.count) },
                        set: { updatePortion(.count, text: $0) }
                    ), field: .count)
                    TextField("Serving description, e.g. one cup", text: itemBinding.portion.servingDescription)
                } header: {
                    Text("Consumed portion")
                } footer: {
                    Text("Changing a known count adjusts the total weight and nutrients. Changing the weight adjusts known nutrients.")
                }
                Section {
                    ForEach(Nutrient.allCases, id: \.self) { nutrient in
                        amountField("\(nutrient.title) (\(nutrient.unit))", text: Binding(
                            get: { amounts[nutrient] ?? amountText(item?.nutrients[nutrient]) },
                            set: { updateNutrient(nutrient, text: $0) }
                        ), field: .nutrient(nutrient))
                    }
                } header: {
                    Text("Nutrients for the consumed portion")
                } footer: {
                    Text("Leave unknown amounts blank. Enter 0 for a known zero.")
                }
                if let item, item.isCorrected == true, let original = item.originalEstimate {
                    Section { OriginalEstimateDisclosure(original: original) }
                }
            }
            if let remove {
                Section {
                    Button("Remove meal item", role: .destructive) {
                        do {
                            try remove()
                            dismiss()
                        } catch {
                            errorMessage = error.draftMessage
                        }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle(isNew ? "Add meal item" : "Edit meal item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save", action: saveEdits)
                    .disabled(item?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            }
        }
        .onAppear {
            guard item == nil else { return }
            item = initialItem
        }
        .onChange(of: focusedAmount) { previous, _ in
            if portionEditStart?.field == previous { portionEditStart = nil }
        }
    }

    private func amountText(_ amount: Double?) -> String {
        let format = FloatingPointFormatStyle<Double>.number.locale(locale)
            .grouping(.never).precision(.significantDigits(1...17))
        return amount.map { $0.formatted(format) } ?? ""
    }

    private func amountField(_ label: String, text: Binding<String>, field: AmountField) -> some View {
        LabeledContent {
            TextField(label, text: text, prompt: Text("Unknown"))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .focused($focusedAmount, equals: field)
                .accessibilityLabel(label)
        } label: {
            Text(label)
        }
    }

    private func parseAmount(_ text: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scanner = Scanner(string: trimmed)
        scanner.locale = locale
        guard let value = scanner.scanDouble(), scanner.isAtEnd, value.isFinite, value >= 0
        else { throw MealReviewIssue.invalidAmount }
        return value
    }

    private func parseCount(_ text: String) throws -> Double? {
        if let value = try parseAmount(text) {
            guard value > 0 else { throw MealReviewIssue.invalidCount }
            return value
        }
        return nil
    }

    private func updatePortion(_ field: AmountField, text: String) {
        guard let current = item else { return }
        var updated = portionEditStart?.field == field ? portionEditStart?.item ?? current : current
        portionEditStart = (field, updated)
        do {
            switch field {
            case .weight:
                weight = text
                updated.portion.grams = try parseAmount(text)
            case .count:
                count = text
                updated.portion.count = try parseCount(text)
                if updated.portion.grams != current.portion.grams, let typed = weight,
                   (try? parseAmount(typed)) != nil || typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    weight = nil
                }
            case .nutrient:
                return
            }
            updated.name = current.name
            updated.description = current.description
            updated.portion.servingDescription = current.portion.servingDescription
            for nutrient in Nutrient.allCases where updated.nutrients[nutrient] != current.nutrients[nutrient] {
                guard let typed = amounts[nutrient] else { continue }
                // Keep invalid direct edits visible until the user fixes them.
                do {
                    _ = try parseAmount(typed)
                    amounts[nutrient] = nil
                } catch {}
            }
            item = updated
        } catch {}
    }

    private func updateNutrient(_ nutrient: Nutrient, text: String) {
        amounts[nutrient] = text
        portionEditStart = nil
        do {
            item?.setNutrientAmount(try parseAmount(text), for: nutrient)
        } catch {}
    }

    private func saveEdits() {
        guard var updated = item else { return }
        do {
            if let weight { _ = try parseAmount(weight) }
            if let count { _ = try parseCount(count) }
            for text in amounts.values { _ = try parseAmount(text) }
            updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try save(updated)
            dismiss()
        } catch {
            errorMessage = error.draftMessage
        }
    }
}

struct NutrientTotalRows: View {
    let totals: NutrientTotals

    var body: some View {
        ForEach(Nutrient.allCases, id: \.self) { nutrient in
            let total = totals[nutrient]
            LabeledContent(nutrient.title) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(nutrient.display(total.knownAmount))
                    if total.isIncomplete {
                        Text(total.knownAmount == nil ? "Incomplete" : "Incomplete · known subtotal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct MealTimeFields: View {
    @Binding var time: MealTime
    var title = "When you ate"
    var latest: Date?

    private var zone: TimeZone { TimeZone(identifier: time.timeZoneIdentifier) ?? .current }

    private var instant: Binding<Date> {
        Binding(
            get: { time.instant },
            set: { time = MealTime(instant: $0, timeZone: zone) }
        )
    }

    var body: some View {
        Group {
            if let latest {
                DatePicker(title, selection: instant, in: ...latest)
            } else {
                DatePicker(title, selection: instant)
            }
        }
        .environment(\.timeZone, zone)
        Picker("Time zone", selection: Binding(
            get: { time.timeZoneIdentifier },
            set: { identifier in
                if let newZone = TimeZone(identifier: identifier) {
                    time = MealTime(instant: time.instant, timeZone: newZone)
                }
            }
        )) {
            ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + [time.timeZoneIdentifier])).sorted(), id: \.self) { identifier in
                Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
            }
        }
    }
}

struct MealHistoryView: View {
    let workflow: MealWorkflow
    @Environment(\.dismiss) private var dismiss
    @State private var showMealCamera = false
    @State private var showLogSymptom = false
    @State private var draftID: UUID?
    @State private var draftError: String?

    var body: some View {
        let days = workflow.dailyHistory
        let pendingDeletions = workflow.pendingMealChanges.count {
            if case .delete = $0 { true } else { false }
        }
        List {
            if pendingDeletions > 0 {
                Label(pendingDeletions == 1 ? "1 deletion pending sync" : "\(pendingDeletions) deletions pending sync",
                      systemImage: "arrow.trianglehead.clockwise")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if days.isEmpty {
                ContentUnavailableView("Nothing logged yet", systemImage: "clock")
            }
            ForEach(days) { day in
                Section(day.localDate) {
                    if let totals = day.nutrientTotals {
                        NavigationLink("Daily nutrient totals") {
                            List {
                                Section(day.localDate) {
                                    NutrientTotalRows(totals: totals)
                                }
                            }
                            .navigationTitle("Daily totals")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                    ForEach(day.rows) { row in
                        switch row {
                        case .meal(let meal):
                            NavigationLink {
                                LoggedMealDetail(workflow: workflow, id: meal.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(meal.record.items.map(\.portionTitle).joined(separator: ", ")).lineLimit(2)
                                    HStack {
                                        Text(meal.record.mealTime.displayTime)
                                        MealSyncStatus(workflow: workflow, id: meal.id)
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("logged-meal")
                            .swipeActions(edge: .leading) {
                                Button { openDraft { try workflow.copyLoggedMealToDraft(meal.id) } } label: {
                                    Label("Copy to Draft", systemImage: "document.on.document")
                                }
                                .tint(.accentColor)
                            }
                        case .observation(let observation):
                            NavigationLink {
                                ObservationDetail(workflow: workflow, id: observation.id)
                            } label: {
                                ObservationChip(observation: observation)
                            }
                            .accessibilityIdentifier(observation.record.kind == .symptom ? "symptom-chip" : "urge-chip")
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .navigationDestination(item: $draftID) { id in
            DraftDetail(workflow: workflow, id: id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button { showMealCamera = true } label: {
                        Label("Meal from Photo", systemImage: "camera")
                    }
                    Button { openDraft { try workflow.startManualDraft() } } label: {
                        Label("Enter Meal Manually", systemImage: "square.and.pencil")
                    }
                    Button { showLogSymptom = true } label: {
                        Label("Log Symptom", systemImage: "clipboard")
                    }
                } label: {
                    Label("Add", systemImage: "plus").labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("history-add")
            }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .fullScreenCover(isPresented: $showMealCamera) {
            NavigationStack { CaptureHome(workflow: workflow, photoOnly: true) }
        }
        .sheet(isPresented: $showLogSymptom) {
            NavigationStack { NewObservationView(workflow: workflow) }
        }
        .alert("Couldn't start meal draft", isPresented: Binding(get: { draftError != nil }, set: {
            if !$0 { draftError = nil }
        })) {
            Button("OK", role: .cancel) { draftError = nil }
        } message: { Text(draftError ?? "") }
    }

    private func openDraft(_ create: () throws -> MealDraft) {
        do { draftID = try create().id }
        catch { draftError = error.draftMessage }
    }
}

struct LoggedMealDetail: View {
    let workflow: MealWorkflow
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeletion = false
    @State private var deleteFailed = false

    private var meal: LoggedMeal? { workflow.loggedMeals.first { $0.id == id } }

    var body: some View {
        List {
            if let meal {
                let record = meal.record
                Section {
                    if let photo = meal.photo {
                        MealImagePreview(workflow: workflow, photo: photo) {
                            try workflow.photoData(forLoggedMeal: id)
                        }
                    }
                    MealSyncStatus(workflow: workflow, id: id)
                }
                Section("Meal time") {
                    Text(record.mealTime.displayDateAndTime)
                    Text(record.mealTime.timeZoneIdentifier)
                }
                if !record.notes.isEmpty {
                    Section("Notes") { CopyableMealText(value: record.notes) }
                }
                if let provenance = record.estimateProvenance {
                    Section("Estimate") { Text(provenance.reviewLabel) }
                }
                Section("Meal nutrient totals") {
                    NutrientTotalRows(totals: record.nutrientTotals)
                }
                ForEach(record.items) { item in
                    Section {
                        Text(item.originLabel).font(.footnote).foregroundStyle(.secondary)
                        if !item.description.isEmpty { CopyableMealText(value: item.description) }
                        if !item.portion.servingDescription.isEmpty {
                            CopyableMealText(value: item.portion.servingDescription)
                        }
                        ItemAmountRows(portion: item.portion, nutrients: item.nutrients)
                        if item.isCorrected == true, let original = item.originalEstimate {
                            OriginalEstimateDisclosure(original: original)
                        }
                    } header: {
                        CopyableMealText(value: item.portionTitle)
                    }
                }
                Section {
                    Button("Delete meal", role: .destructive) { confirmDeletion = true }
                    if deleteFailed {
                        Text("Couldn’t delete this meal. Unlock your iPhone and try again.")
                            .foregroundStyle(.red)
                    }
                }
            } else {
                ContentUnavailableView("Meal unavailable", systemImage: "fork.knife")
            }
        }
        .navigationTitle("Logged meal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let meal {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink("Edit") { LoggedMealEditor(workflow: workflow, meal: meal) }
                }
            }
        }
        .confirmationDialog("Delete this meal?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete meal", role: .destructive) {
                do {
                    try workflow.deleteLoggedMeal(id)
                    dismiss()
                } catch { deleteFailed = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the meal from your history and updates your daily totals.")
        }
    }
}

private struct CopyableMealText: View {
    let value: String

    var body: some View {
        Text(value)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Label("Copy", systemImage: "document.on.document")
                }
            }
    }
}

private struct LoggedMealEditor: View {
    let workflow: MealWorkflow
    let meal: LoggedMeal
    @Environment(\.dismiss) private var dismiss
    @State private var time: MealTime
    @State private var notes: String
    @State private var items: [MealItem]
    @State private var saveFailed = false

    init(workflow: MealWorkflow, meal: LoggedMeal) {
        self.workflow = workflow
        self.meal = meal
        _time = State(initialValue: meal.record.mealTime)
        _notes = State(initialValue: meal.record.notes)
        _items = State(initialValue: meal.record.items)
    }

    var body: some View {
        Form {
            Section("Meal time") { MealTimeFields(time: $time) }
            Section("Optional context") {
                TextField("Ingredients, servings, or other notes", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section("Meal items") {
                if let provenance = meal.record.estimateProvenance {
                    Text(provenance.reviewLabel).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    NavigationLink {
                        MealItemEditor(initialItem: item, isNew: false, save: saveItem)
                    } label: {
                        MealItemReviewLabel(item: item)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { items.removeAll { $0.id == item.id } }
                    }
                }
                NavigationLink {
                    MealItemEditor(initialItem: MealItem(name: ""), isNew: true, save: saveItem)
                } label: {
                    Label("Add food or drink", systemImage: "plus")
                }
            }
            Section("Meal nutrient totals") { NutrientTotalRows(totals: NutrientTotals(items: items)) }
            if saveFailed {
                Text("Couldn’t save this meal. Unlock your iPhone and try again.").foregroundStyle(.red)
            }
        }
        .navigationTitle("Edit meal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try workflow.updateLoggedMeal(meal.id, mealTime: time, notes: notes, items: items)
                        dismiss()
                    } catch { saveFailed = true }
                }
                .disabled(items.isEmpty)
            }
        }
    }

    private func saveItem(_ item: MealItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
    }
}

private struct MealSyncStatus: View {
    let workflow: MealWorkflow
    let id: UUID

    var body: some View {
        Group {
            if workflow.pendingMealChanges.contains(where: { $0.id == id }) {
                Label("Pending sync", systemImage: "arrow.trianglehead.clockwise")
            } else {
                Label("Synced", systemImage: "checkmark.icloud")
            }
        }
        .accessibilityIdentifier("meal-sync-status")
    }
}

extension EstimateProvenance {
    var reviewLabel: String {
        "Estimated by \(provider.displayName) · \(model)"
    }
}

extension Nutrient {
    var title: String { self == .addedSugar ? "Added sugar" : rawValue.capitalized }

    fileprivate func display(_ value: Double?) -> String {
        guard let value else { return "Unknown" }
        return "\(value.formatted(.number.precision(.significantDigits(1...6)))) \(unit)"
    }
}

private struct ItemAmountRows: View {
    let portion: ConsumedPortion
    let nutrients: NutrientAmounts

    var body: some View {
        LabeledContent("Consumed weight", value: portion.grams.map { "\($0.formatted()) g" } ?? "Unknown")
        ForEach(Nutrient.allCases, id: \.self) { nutrient in
            LabeledContent(nutrient.title, value: nutrient.display(nutrients[nutrient]))
        }
    }
}

private struct OriginalEstimateDisclosure: View {
    let original: OriginalItemEstimate

    var body: some View {
        DisclosureGroup("Original item estimate") {
            Text(original.name)
            if !original.description.isEmpty { Text(original.description) }
            if !original.portion.servingDescription.isEmpty { Text(original.portion.servingDescription) }
            if let count = original.portion.count {
                LabeledContent("Count", value: count.formatted())
            }
            ItemAmountRows(portion: original.portion, nutrients: original.nutrients)
        }
    }
}

struct MealItemReviewLabel: View {
    let item: MealItem
    var purchasedQuantity: Double?

    var body: some View {
        VStack(alignment: .leading) {
            Text(item.portionTitle)
            if let purchasedQuantity {
                Text("Purchased quantity \(purchasedQuantity.formatted())")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(item.originLabel).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension MealItem {
    var portionTitle: String {
        guard let count = portion.count else { return name }
        return "\(name) × \(count.formatted())"
    }

    var originLabel: String {
        switch origin {
        case .ai: isCorrected == true ? "Corrected AI estimate" : "AI estimate"
        case .manual: "Manually added"
        case nil: "Source unknown"
        }
    }
}


extension MealTime {
    var displayDateAndTime: String { "\(localDate) · \(displayTime)" }

    var displayTime: String {
        let zone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return instant.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }
}
