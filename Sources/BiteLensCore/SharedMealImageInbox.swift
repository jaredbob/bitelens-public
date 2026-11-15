import Foundation

/// Holds incoming images until BiteLens moves them into its private draft store.
public struct SharedMealImageInbox: Sendable {
    private let directory: URL
    private let requiresAccount: Bool

    public init(directory: URL, requiresAccount: Bool = false) {
        self.directory = directory
        self.requiresAccount = requiresAccount
    }

    #if os(iOS)
    public static var reviewURL: URL? {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "BiteLensURLScheme") as? String else { return nil }
        return URL(string: "\(scheme)://shared-image")
    }

    public static func appGroup(requiresAccount: Bool = false) -> Self? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BiteLensAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            .map { Self(directory: $0.appendingPathComponent("IncomingMealImages", isDirectory: true),
                        requiresAccount: requiresAccount) }
    }
    #endif

    /// The extension snapshots the destination before it asks iOS for image data.
    public func beginShare(at sharedAt: Date = .now, timeZone: TimeZone = .current) throws -> Share {
        let accountID: UUID?
        if requiresAccount {
            let marker: String
            do { marker = try String(contentsOf: activeAccountURL, encoding: .utf8) }
            catch CocoaError.fileReadNoSuchFile { throw WorkflowIssue.signInRequired }
            guard let id = UUID(uuidString: marker) else { throw DraftIssue.storageUnavailable }
            accountID = id
        } else {
            accountID = nil
        }
        return Share(inbox: self, accountID: accountID, sharedAt: sharedAt, timeZone: timeZone)
    }

    public struct Share: Sendable {
        fileprivate let inbox: SharedMealImageInbox
        fileprivate let accountID: UUID?
        fileprivate let sharedAt: Date
        fileprivate let timeZone: TimeZone

        @discardableResult public func enqueue(_ data: Data) throws -> UUID {
            try inbox.enqueue(data, for: accountID, sharedAt: sharedAt, timeZone: timeZone)
        }
    }

    func setActiveAccount(_ accountID: UUID?) throws {
        guard requiresAccount else { return }
        guard let accountID else {
            try removeFile(activeAccountURL)
            return
        }
        try prepareDirectory()
        let marker = Data(accountID.uuidString.utf8)
        #if os(iOS)
        try marker.write(to: activeAccountURL, options: [.atomic, .completeFileProtection])
        #else
        try marker.write(to: activeAccountURL, options: .atomic)
        #endif
    }

    @discardableResult public func enqueueDocument(at url: URL, receivedAt: Date = .now, timeZone: TimeZone = .current) throws -> UUID {
        guard !requiresAccount, url.isFileURL else { throw DraftIssue.invalidPhoto }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        // When iOS delivers a copy, it belongs to this app's document inbox.
        // An open-in-place URL belongs to the source and is read-only here.
        let documentInbox = URL.documentsDirectory.appendingPathComponent("Inbox").resolvingSymlinksInPath()
        let isInboxCopy = url.deletingLastPathComponent().resolvingSymlinksInPath().path == documentInbox.path
        defer { if isInboxCopy { try? FileManager.default.removeItem(at: url) } }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var read: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
            read = Result { try Data(contentsOf: file) }
        }
        if let coordinationError { throw coordinationError }
        guard let read else { throw DraftIssue.photoUnavailable }
        return try enqueue(read.get(), sharedAt: receivedAt, timeZone: timeZone)
    }

    @discardableResult public func enqueue(_ data: Data, sharedAt: Date = .now, timeZone: TimeZone = .current) throws -> UUID {
        try beginShare(at: sharedAt, timeZone: timeZone).enqueue(data)
    }

    private func enqueue(_ data: Data, for accountID: UUID?, sharedAt: Date, timeZone: TimeZone) throws -> UUID {
        _ = try ImportedMealImage(data: data, timeZone: timeZone)
        let id = UUID()
        try prepareDirectory()
        _ = try pending(for: accountID, at: sharedAt)

        // Publish a complete entry only after its contents and retention timestamp are ready.
        let staging = directory.appendingPathComponent(".\(id.uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(Entry(data: data, sharedAt: sharedAt, timeZone: timeZone))
        #if os(iOS)
        try bytes.write(to: staging, options: [.completeFileProtection])
        #else
        try bytes.write(to: staging)
        #endif
        try FileManager.default.setAttributes([.modificationDate: sharedAt, .posixPermissions: 0o600],
                                              ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: url(for: id, accountID: accountID))
        return id
    }

    func pending(for accountID: UUID?, at now: Date) throws -> (ids: [UUID], expiresAt: Date?) {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) }
        catch CocoaError.fileReadNoSuchFile { return ([], nil) }

        let canImport = requiresAccount == (accountID != nil)
        let prefix = accountID.map { "\($0.uuidString)-" } ?? ""
        var ready: [(id: UUID, date: Date)] = []
        var nextExpiry: Date?
        for file in files where file.lastPathComponent != activeAccountURL.lastPathComponent {
            let values: URLResourceValues
            do { values = try file.resourceValues(forKeys: [.contentModificationDateKey]) }
            catch CocoaError.fileReadNoSuchFile { continue }
            guard let date = values.contentModificationDate else { continue }
            let expiresAt = date.addingTimeInterval(StoredMealImage.retentionInterval)
            if now >= expiresAt {
                try removeFile(file)
                continue
            }
            guard file.pathExtension == "plist" else { continue }
            nextExpiry = min(nextExpiry ?? expiresAt, expiresAt)
            let name = file.deletingPathExtension().lastPathComponent
            if canImport, date <= now, name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))) {
                ready.append((id, date))
            }
        }
        return (ready.sorted { $0.date < $1.date }.map(\.id), nextExpiry)
    }

    func read(_ id: UUID, for accountID: UUID?) throws -> Entry {
        try PropertyListDecoder().decode(Entry.self, from: Data(contentsOf: url(for: id, accountID: accountID)))
    }

    func remove(_ id: UUID, for accountID: UUID?) throws {
        try removeFile(url(for: id, accountID: accountID))
    }

    private var activeAccountURL: URL { directory.appendingPathComponent(".ActiveAccount") }

    private func url(for id: UUID, accountID: UUID?) -> URL {
        let prefix = accountID.map { "\($0.uuidString)-" } ?? ""
        return directory.appendingPathComponent("\(prefix)\(id.uuidString).plist")
    }

    private func prepareDirectory() throws {
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    private func removeFile(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
        catch CocoaError.fileReadNoSuchFile {}
    }

    struct Entry: Codable {
        let data: Data
        let sharedAt: Date
        let timeZone: TimeZone
    }
}
