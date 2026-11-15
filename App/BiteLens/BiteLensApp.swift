import BiteLensCore
import Network
import SwiftUI

@main
@MainActor
struct BiteLensApp: App {
    @State private var workflow: MealWorkflow?

    init() {
        let workflow = AppConfiguration.makeWorkflow()
        #if DEBUG
        if let workflow, UITestMode.isEnabled {
            UITestMode.prepareLaunch(workflow: workflow)
        }
        #endif
        _workflow = State(initialValue: workflow)
    }

    var body: some Scene {
        WindowGroup {
            if let workflow {
                BiteLensRoot(workflow: workflow)
            } else {
                ContentUnavailableView(
                    "BiteLens needs setup",
                    systemImage: "gearshape",
                    description: Text("Configure a Supabase project in Local.xcconfig, then rebuild the app.")
                )
            }
        }
    }
}

@MainActor
private struct BiteLensRoot: View {
    let workflow: MealWorkflow
    @State private var isNetworkAvailable = false
    @State private var imageOpenFailed = false
    @Environment(\.scenePhase) private var scenePhase

    private var shouldSync: Bool {
        scenePhase == .active && isNetworkAvailable &&
            (!workflow.pendingMealChanges.isEmpty || !workflow.pendingObservationChanges.isEmpty)
    }

    var body: some View {
        let syncAccount = shouldSync ? workflow.accountActivationID : nil
        let foregroundPhotoExpiration = scenePhase == .active ? workflow.nextPhotoExpiration : nil
        OnboardingRoot(workflow: workflow)
            .tint(.orange)
            .onOpenURL { url in
                if url == SharedMealImageInbox.reviewURL {
                    workflow.resumeLocalWork()
                } else if url.isFileURL {
                    Task { await openSharedImage(url, receivedAt: .now, timeZone: .current) }
                }
            }
            .alert("Couldn't open this image", isPresented: $imageOpenFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(workflow.isBeta
                     ? "Choose BiteLens Beta from the Share Sheet, or add an image from Photos in BiteLens Beta."
                     : "Share one photo or screenshot and try again.")
            }
            .task {
                workflow.restoreSession()
                if workflow.access == .owner { _ = try? await workflow.accessToken() }
            }
            .task {
                for await available in connectivityUpdates() { isNetworkAvailable = available }
            }
            .task(id: foregroundPhotoExpiration) {
                if let foregroundPhotoExpiration {
                    await workflow.waitForPhotoExpiry(at: foregroundPhotoExpiration)
                }
            }
            .task(id: syncAccount) {
                guard let syncAccount else { return }
                while !Task.isCancelled, shouldSync, workflow.accountActivationID == syncAccount {
                    await workflow.syncPendingMealChanges()
                    guard !Task.isCancelled, workflow.accountActivationID == syncAccount else { return }
                    await workflow.syncPendingObservationChanges()
                    // Connectivity may stay available during a service outage.
                    if shouldSync { try? await Task.sleep(for: .seconds(15)) }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    workflow.resumeLocalWork()
                    if workflow.access == .owner { Task { _ = try? await workflow.accessToken() } }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                workflow.restoreSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                if scenePhase == .active { workflow.resumeLocalWork() }
            }
    }

    private func openSharedImage(_ url: URL, receivedAt: Date, timeZone: TimeZone) async {
        guard !workflow.isBeta else {
            imageOpenFailed = true
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                guard let inbox = SharedMealImageInbox.appGroup() else { throw DraftIssue.storageUnavailable }
                _ = try inbox.enqueueDocument(at: url, receivedAt: receivedAt, timeZone: timeZone)
            }.value
            workflow.resumeLocalWork()
        } catch {
            imageOpenFailed = true
        }
    }

    private func connectivityUpdates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "BiteLens.MealSyncConnectivity"))
        return stream
    }
}
