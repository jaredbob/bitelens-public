import BiteLensCore
import Observation
import SwiftUI

struct OnboardingRoot: View {
    let workflow: MealWorkflow

    var body: some View {
        if workflow.access == .owner, workflow.selectedProvider != nil {
            CaptureNavigation(workflow: workflow)
                .id(workflow.accountActivationID)
        } else {
            NavigationStack {
                if workflow.access == .owner {
                    ProviderChoiceView(workflow: workflow)
                } else {
                    SignInView(workflow: workflow)
                }
            }
        }
    }
}

@MainActor
@Observable
final class CameraControlLaunch {
    static let shared = CameraControlLaunch()
    private(set) var request = UUID()

    private init() {}

    func requestCamera() {
        request = UUID()
    }
}

enum CaptureDestination: Hashable {
    case settings
}

private struct CaptureNavigation: View {
    let workflow: MealWorkflow
    @State private var path: [CaptureDestination] = []

    var body: some View {
        let cameraRequest = CameraControlLaunch.shared.request
        NavigationStack(path: $path) {
            CaptureHome(workflow: workflow, cameraRequest: cameraRequest)
                .navigationDestination(for: CaptureDestination.self) { destination in
                    switch destination {
                    case .settings: SettingsView(workflow: workflow)
                    }
                }
        }
        .onChange(of: cameraRequest) { _, _ in path.removeAll() }
        .onChange(of: workflow.sharedDraftToOpen) { _, id in
            if id != nil { path.removeAll() }
        }
    }
}

struct SignInView: View {
    let workflow: MealWorkflow
    var reauthenticating = false
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(reauthenticating ? "Welcome back" : workflow.isBeta ? "BiteLens Beta" : "BiteLens")
                    .font(.largeTitle.bold())
                Text("Sign in with your existing email account.")
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            Section("Your account") {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button {
                    Task {
                        await workflow.signIn(email: email, password: password)
                        password = ""
                        if workflow.access == .owner, workflow.issue == nil, reauthenticating { dismiss() }
                    }
                } label: {
                    HStack {
                        Text("Sign in")
                        Spacer()
                        if workflow.isAuthenticating { ProgressView() }
                    }
                }
                .disabled(workflow.isAuthenticating || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
            if let issue = workflow.issue {
                Section {
                    Text(issue == .accessDenied && workflow.isBeta
                         ? "This account isn't approved for BiteLens Beta. Contact the beta admin for help."
                         : issue.userMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("sign-in-error")
                }
            }
            Section {
                if workflow.isBeta {
                    Text("A BiteLens admin manages beta accounts and password resets.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let email = AppConfiguration.betaSupportEmail,
                       let url = URL(string: "mailto:\(email)"), !email.isEmpty {
                        Link(email, destination: url)
                    } else {
                        Text("Contact the BiteLens Beta team through Send Beta Feedback in TestFlight.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let url = AppConfiguration.betaPrivacyPolicyURL {
                        Link("Privacy Policy", destination: url)
                            .accessibilityIdentifier("sign-in-privacy-policy")
                    }
                } else {
                    Text("BiteLens is a private app for its approved owner.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(reauthenticating ? "Sign in again" : "")
        .toolbar {
            if reauthenticating {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct ProviderChoiceView: View {
    let workflow: MealWorkflow

    var body: some View {
        List {
            Section {
                Text("Choose your AI provider").font(.title.bold())
                Text("Your meal photos will be sent to the provider you select for analysis. You can change this in Settings.")
                    .foregroundStyle(.secondary)
            }.listRowBackground(Color.clear)
            Section("Use for meal estimates") {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Button { workflow.selectProvider(provider) } label: {
                        Label(provider.displayName, systemImage: "sparkles")
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }
                }
            }
            Section {
                Text("AI estimates need your review. Standard provider retention policies apply to cloud analysis.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Set up BiteLens")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sign out") { Task { await workflow.signOut() } }
            }
        }
    }
}

struct SettingsView: View {
    let workflow: MealWorkflow
    @State private var showSignIn = false
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section {
                Picker("AI provider", selection: Binding(get: { workflow.selectedProvider }, set: {
                    if let provider = $0 { workflow.selectProvider(provider) }
                })) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(Optional(provider))
                    }
                }
            } footer: {
                Text("Changes apply to future analyses. Previous meals keep their original provider.")
            }
            if workflow.isBeta {
                Section("AI sharing permissions") {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        if workflow.hasAnalysisPermission(for: provider) {
                            Button("Withdraw permission for \(provider.displayName)", role: .destructive) {
                                workflow.setAnalysisPermission(for: provider, allowed: false)
                            }
                        } else {
                            LabeledContent(provider.displayName, value: "Permission needed")
                        }
                    }
                }
            }
            AppleHealthSharingSettings(workflow: workflow, activation: workflow.accountActivationID)
            Section("Account") {
                Button("Sign in again") { showSignIn = true }
                Button("Sign out", role: .destructive) { confirmSignOut = true }
            }
            if workflow.isBeta, let url = AppConfiguration.betaPrivacyPolicyURL {
                Section {
                    Link("Privacy Policy", destination: url)
                }
            }
            if let issue = workflow.issue { Section { Text(issue.userMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showSignIn) {
            NavigationStack { SignInView(workflow: workflow, reauthenticating: true) }
        }
        .confirmationDialog("Sign out of BiteLens?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await workflow.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your local work stays on this iPhone.") }
    }
}

private struct AppleHealthSharingSettings: View {
    private enum Feature {
        case meals, symptoms
    }

    let workflow: MealWorkflow
    let activation: UUID
    @State private var confirmConnection = false
    @State private var pendingOptIn: Feature?

    var body: some View {
        switch workflow.appleHealthConnectionStatus {
        case .unavailable:
            if workflow.isBeta {
                Section("Apple Health") { Text("Apple Health settings are unavailable.") }
            }
        case .connectedToAnotherAccount:
            Section("Apple Health") {
                Text("Another BiteLens account is connected to Apple Health in this installation.")
            }
        case .readyToConnect, .connected:
            AppleHealthSettings(workflow: workflow, syncEnabled: Binding(
                get: { workflow.appleHealthSyncEnabled },
                set: { setEnabled($0, for: .meals) }
            ))
            Section {
                Toggle("Share symptoms with Apple Health", isOn: Binding(
                    get: { workflow.appleHealthSymptomSharingEnabled },
                    set: { setEnabled($0, for: .symptoms) }
                ))
            } footer: {
                Text("Applies to symptoms first saved while sharing is on. Manage write access for each symptom type in the Health app.")
            }
            .alert("Connect to Apple Health?", isPresented: $confirmConnection, presenting: pendingOptIn) { feature in
                Button("Connect") { updateSharing(true, for: feature) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Connect only if this is your Health record. This BiteLens account will be the only account that can share with Apple Health from this installation.")
            }
        }
    }

    private func setEnabled(_ enabled: Bool, for feature: Feature) {
        if enabled, workflow.appleHealthConnectionStatus == .readyToConnect {
            pendingOptIn = feature
            confirmConnection = true
        } else {
            updateSharing(enabled, for: feature)
        }
    }

    private func updateSharing(_ enabled: Bool, for feature: Feature) {
        Task {
            guard workflow.accountActivationID == activation else { return }
            switch feature {
            case .meals: await workflow.setAppleHealthSyncEnabled(enabled)
            case .symptoms: await workflow.setAppleHealthSymptomSharingEnabled(enabled)
            }
        }
    }
}

private struct AppleHealthSettings: View {
    let workflow: MealWorkflow
    let syncEnabled: Binding<Bool>
    @State private var backfillInProgress = false
    @State private var backfillMessage: String?

    var body: some View {
        let status = workflow.appleHealthSyncStatus
        Section {
            Toggle("Apple Health Sync", isOn: syncEnabled)
            if workflow.appleHealthConnectionStatus == .connected {
                LabeledContent("Sync status", value: syncSummary(status))
                Button("Retry Sync") {
                    Task { await workflow.retryAppleHealthSync() }
                }
                .disabled(!workflow.appleHealthSyncEnabled || !status.hasPendingWork)
                Button("Sync Last 30 Days", action: backfill)
                    .disabled(!workflow.appleHealthSyncEnabled || backfillInProgress)
                if let backfillMessage {
                    Text(backfillMessage).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("BiteLens shares nutrition and alcohol intake from eligible meals. Turning sync off keeps entries already in Health.")
        }
        if workflow.appleHealthConnectionStatus == .connected {
            Section {
                ForEach(Nutrient.allCases.filter(AppleHealthSample.supportedNutrients.contains), id: \.self) { nutrient in
                    LabeledContent(nutrient == .fat ? "Total fat" : nutrient.title,
                                   value: writeAccessLabel(status.writeAccess, for: nutrient))
                }
            } header: {
                Text("Apple Health write access")
            } footer: {
                Text("Manage write access in the Health app.")
            }
        }
    }

    private func backfill() {
        backfillMessage = nil
        backfillInProgress = true
        Task {
            defer { backfillInProgress = false }
            do {
                let count = try await workflow.backfillAppleHealth()
                switch count {
                case 0: backfillMessage = "No meals from the last 30 days on this iPhone."
                case 1: backfillMessage = "1 meal selected for sync."
                default: backfillMessage = "\(count) meals selected for sync."
                }
            } catch AppleHealthBackfillError.writeAccessRequired {
                backfillMessage = "Allow BiteLens to write at least one data type in the Health app, then try again."
            } catch AppleHealthBackfillError.unavailable {
                backfillMessage = "Apple Health is unavailable."
            } catch AppleHealthBackfillError.paused {
                backfillMessage = "Turn on Apple Health Sync to backfill meals."
            } catch {
                backfillMessage = "Couldn't start Apple Health backfill. Try again."
            }
        }
    }

    private func syncSummary(_ status: AppleHealthSyncStatus) -> String {
        if status.hasFailedWork { return "Some changes failed" }
        if status.hasPendingWork { return "Changes pending" }
        return "No changes pending"
    }

    private func writeAccessLabel(_ access: AppleHealthSyncStatus.WriteAccess, for nutrient: Nutrient) -> String {
        switch access {
        case .checking: "Checking…"
        case .unavailable: "Unavailable"
        case .available(let allowed): allowed.contains(nutrient) ? "Allowed" : "No access"
        }
    }
}

extension AIProvider {
    var displayName: String { self == .openAI ? "OpenAI" : "Grok" }
}

extension WorkflowIssue {
    var userMessage: String {
        switch self {
        case .invalidCredentials: "The email or password wasn't accepted. Please try again."
        case .authenticationUnavailable: "Couldn't connect to sign in. Check your connection and try again."
        case .storageUnavailable: "Couldn't access your saved local data securely. Unlock your iPhone and try again."
        case .accessDenied: "This account isn't approved for BiteLens. Sign in with the owner's account."
        case .signInRequired: "Please sign in again to reconnect. Your local work stays here."
        }
    }
}
