import BiteLensCore
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let sharedAt = Date()
        let share = Result {
            #if BITELENS_BETA
            let inbox = SharedMealImageInbox.appGroup(requiresAccount: true)
            #else
            let inbox = SharedMealImageInbox.appGroup()
            #endif
            guard let inbox else { throw DraftIssue.storageUnavailable }
            return try inbox.beginShare(at: sharedAt)
        }
        let host = UIHostingController(rootView: ShareMealImageView(context: extensionContext, share: share) { [weak self] in
            await self?.openBiteLens()
        })
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func openBiteLens() async {
        // iOS can refuse to open an app from a Share extension. The caller
        // has already saved the image, so returning to BiteLens still works.
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, let url = SharedMealImageInbox.reviewURL {
                _ = await application.open(url)
                return
            }
            responder = current.next
        }
    }
}

private struct ShareMealImageView: View {
    let context: NSExtensionContext?
    let share: Result<SharedMealImageInbox.Share, Error>
    let openBiteLens: @MainActor () async -> Void
    @State private var saving = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                if saving {
                    ProgressView("Saving draft…")
                } else {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    if case .success = share {
                        Button("Try again") { saving = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .navigationTitle(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Save to BiteLens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
            }
        }
        .tint(.orange)
        .task(id: saving) {
            if saving { await save() }
        }
    }

    private func close() { context?.completeRequest(returningItems: nil) }

    private func save() async {
        defer { saving = false }
        errorMessage = nil
        let destination: SharedMealImageInbox.Share
        do { destination = try share.get() }
        catch WorkflowIssue.signInRequired {
            errorMessage = "Sign in to BiteLens Beta, then share this image again."
            return
        } catch {
            errorMessage = "BiteLens storage is unavailable. Open BiteLens and try again."
            return
        }
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let images = providers.compactMap { provider -> (NSItemProvider, String)? in
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true })
            else { return nil }
            return (provider, type)
        }
        guard images.count == 1, let (provider, type) = images.first else {
            errorMessage = "Share one image to start a draft."
            return
        }
        do {
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? DraftIssue.invalidPhoto) }
                }
            }
            try Task.checkCancellation()
            try destination.enqueue(data)
            await openBiteLens()
            close()
        } catch is CancellationError {
        } catch {
            errorMessage = "Couldn’t save this image. Try again or share another image."
        }
    }
}
