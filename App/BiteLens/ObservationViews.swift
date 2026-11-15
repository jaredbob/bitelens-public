import BiteLensCore
import SwiftUI

struct ObservationLogButton: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 2) {
                Image(systemName: "clipboard")
                Image(systemName: "plus")
                    .font(.caption2.weight(.semibold))
            }
        }
        .accessibilityLabel("Log symptom")
        .accessibilityIdentifier("log-observation")
    }
}

struct NewObservationView: View {
    let workflow: MealWorkflow
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List(workflow.searchObservationTypes(search), id: \.self) { type in
            NavigationLink {
                switch type {
                case .symptom(let symptom):
                    ObservationForm(title: type.displayName, levelLabel: "Severity") { time, severity, notes in
                        try workflow.logSymptom(symptom, time: time, severity: severity, notes: notes)
                        dismiss()
                    }
                case .bingeEatingUrge:
                    NewUrgeView(workflow: workflow, finish: { dismiss() })
                }
            } label: {
                Label(type.displayName, systemImage: type.symbol)
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search symptoms")
        .navigationTitle("Log symptom")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

private struct NewUrgeView: View {
    let workflow: MealWorkflow
    let finish: () -> Void
    @State private var savedUrgeID: UUID?

    var body: some View {
        if let savedUrgeID {
            ObservationDetail(workflow: workflow, id: savedUrgeID, onDelete: finish)
                .navigationBarBackButtonHidden()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: finish).accessibilityIdentifier("finish-urge")
                    }
                }
        } else {
            ObservationForm(title: ObservationType.bingeEatingUrge.displayName, levelLabel: "Intensity",
                            showsAppetiteDisclosure: workflow.appleHealthSymptomSharingEnabled) { time, intensity, notes in
                savedUrgeID = try workflow.logUrge(time: time, intensity: intensity, notes: notes).id
            }
        }
    }
}

private struct ObservationForm: View {
    let title: String
    let levelLabel: String
    var showsAppetiteDisclosure = false
    @State var time = MealTime(instant: .now, timeZone: .current)
    @State var level: ObservationSeverity?
    @State var notes = ""
    let save: (MealTime, ObservationSeverity?, String?) throws -> Void
    @State private var error: String?

    var body: some View {
        Form {
            if showsAppetiteDisclosure {
                Section {
                    Text("Saving confirms increased appetite for Apple Health. BiteLens shares the urge time when write access is available.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                MealTimeFields(time: $time, title: "When it happened", latest: .now)
            }
            Section {
                Picker(levelLabel, selection: $level) {
                    Text("Not specified").tag(ObservationSeverity?.none)
                    ForEach([ObservationSeverity.mild, .moderate, .severe], id: \.self) { level in
                        Text(level.displayLabel).tag(Optional(level))
                    }
                }
                TextField("Optional notes", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("observation-notes")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try save(time, level, notes.isEmpty ? nil : notes)
                    } catch {
                        self.error = error.observationMessage
                    }
                }
                .accessibilityIdentifier("save-observation")
            }
        }
    }
}

struct ObservationChip: View {
    let observation: LoggedObservation

    var body: some View {
        let record = observation.record
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.type.displayName).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(record.time.displayTime)
                    if let level = record.severity { Text("· \(level.displayLabel)") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: record.type.symbol)
                .foregroundStyle(Color.accentColor)
                .padding(8)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ObservationDetail: View {
    let workflow: MealWorkflow
    let id: UUID
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeletion = false
    @State private var chooseMeal = false
    @State private var startMeal = false
    @State private var cameraRequest = UUID()
    @State private var error: String?

    private var record: ObservationRecord? {
        workflow.loggedObservations.first { $0.id == id }?.record
    }

    var body: some View {
        Group {
            if let record {
                Form {
                    Section {
                        LabeledContent("When", value: record.time.displayDateAndTime)
                        LabeledContent(record.levelLabel, value: record.severity?.displayLabel ?? "Not specified")
                    }
                    if let notes = record.notes, !notes.isEmpty {
                        Section("Notes") { Text(notes) }
                    }
                    if record.kind == .urge { mealLinkSection(record) }
                    Section {
                        NavigationLink("Edit") {
                            EditObservationView(workflow: workflow, record: record)
                        }
                        Button("Delete", role: .destructive) { confirmDeletion = true }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
            } else {
                ContentUnavailableView("Entry unavailable", systemImage: "clock")
            }
        }
        .navigationTitle(record?.type.displayName ?? "Observation")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this entry?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try workflow.deleteObservation(id)
                    if let onDelete { onDelete() } else { dismiss() }
                } catch { self.error = error.observationMessage }
            }
        }
        .sheet(isPresented: $chooseMeal) {
            NavigationStack {
                List(workflow.loggedMeals) { meal in
                    Button {
                        if setLink(meal.id) { chooseMeal = false }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meal.record.items.map(\.portionTitle).joined(separator: ", ")).lineLimit(2)
                            Text(meal.record.mealTime.displayDateAndTime)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Choose a logged meal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { chooseMeal = false }
                    }
                }
                .alert("Couldn't link the meal", isPresented: Binding(get: { error != nil }, set: {
                    if !$0 { error = nil }
                })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(error ?? "") }
            }
        }
        .fullScreenCover(isPresented: $startMeal) {
            NavigationStack {
                CaptureHome(workflow: workflow, cameraRequest: cameraRequest, linkedUrgeID: id)
            }
        }
    }

    private func mealLinkSection(_ record: ObservationRecord) -> some View {
        Section("Linked meal") {
            if let meal = workflow.loggedMeals.first(where: { $0.id == record.mealID }) {
                NavigationLink {
                    LoggedMealDetail(workflow: workflow, id: meal.id)
                } label: {
                    Text(meal.record.items.map(\.portionTitle).joined(separator: ", ")).lineLimit(2)
                }
                Button("Remove meal link", role: .destructive) { _ = setLink(nil) }
            }
            Button(record.mealID == nil ? "Link a logged meal" : "Choose a different meal") {
                error = nil
                chooseMeal = true
            }
            .disabled(workflow.loggedMeals.isEmpty)
            Button("Log a new meal") { startMeal = true }
        }
    }

    private func setLink(_ mealID: UUID?) -> Bool {
        do {
            _ = try workflow.linkUrge(id, to: mealID)
            error = nil
            return true
        } catch {
            self.error = error.observationMessage
            return false
        }
    }
}

private struct EditObservationView: View {
    let workflow: MealWorkflow
    let record: ObservationRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ObservationForm(title: "Edit \(record.type.displayName)", levelLabel: record.levelLabel,
                        time: record.time, level: record.severity, notes: record.notes ?? "") { time, level, notes in
            _ = try workflow.updateObservation(record.id, time: time, severity: level, notes: notes)
            dismiss()
        }
    }
}

private extension ObservationRecord {
    var levelLabel: String { kind == .symptom ? "Severity" : "Intensity" }
}

private extension ObservationSeverity {
    var displayLabel: String { rawValue.capitalized }
}

private extension Error {
    var observationMessage: String {
        if let issue = self as? ObservationIssue {
            switch issue {
            case .futureTime: return "Choose an observation time in the past."
            case .mealNotFound: return "That meal is no longer available."
            case .notFound, .urgeRequired: return "That entry is no longer available."
            case .storageUnavailable: return "Couldn't save this change on your iPhone. Try again."
            }
        }
        return (self as? WorkflowIssue)?.userMessage ?? "Couldn't save this change. Try again."
    }
}
