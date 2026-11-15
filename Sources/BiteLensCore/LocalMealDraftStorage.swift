import Darwin
import Foundation

/// Atomic structured records live separately from private, short-lived photo files.
/// This is a concrete disk adapter; tests reopen it against actual temporary files.
public struct LocalMealDraftStorage: Sendable {
    public let directory: URL
    private var recordsURL: URL { directory.appendingPathComponent("drafts.json") }
    private var photosURL: URL { directory.appendingPathComponent("photos", isDirectory: true) }

    public init(directory: URL) { self.directory = directory }

    func load() throws -> LocalMealLibrary {
        let data: Data
        do { data = try Data(contentsOf: recordsURL) }
        catch CocoaError.fileReadNoSuchFile { return LocalMealLibrary() }
        let decoder = JSONDecoder()
        // Ticket #3 stored a top-level array. Its photo IDs and date encoding are unchanged.
        if let legacyDrafts = try? decoder.decode([MealDraft].self, from: data) {
            return LocalMealLibrary(drafts: legacyDrafts)
        }
        return try decoder.decode(LocalMealLibrary.self, from: data)
    }

    func save(_ meals: LocalMealLibrary) throws {
        try prepareDirectories()
        // Set protection and permissions before the atomic rename. Once the live
        // file is replaced, a caller must never see a write failure and roll back.
        let stagingURL = directory.appendingPathComponent(".drafts-next.json")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try writePrivate(try JSONEncoder().encode(meals), to: stagingURL)
        guard rename(stagingURL.path, recordsURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func writePhoto(_ data: Data, photo: StoredMealImage) throws {
        try prepareDirectories()
        let url = photoURL(photo)
        try writePrivate(data, to: url)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    func readPhoto(_ photo: StoredMealImage) throws -> Data { try Data(contentsOf: photoURL(photo)) }

    func removePhoto(_ photo: StoredMealImage) throws {
        let url = photoURL(photo)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Also removes incomplete/orphan captures left by an interrupted atomic commit.
    func cleanPhotos(retaining photos: [StoredMealImage], now: Date) throws {
        guard FileManager.default.fileExists(atPath: photosURL.path) else { return }
        let retainedNames = Set(photos.filter { now < $0.expiresAt }.map { photoURL($0).lastPathComponent })
        for url in try FileManager.default.contentsOfDirectory(at: photosURL, includingPropertiesForKeys: nil) {
            if !retainedNames.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
        }
    }

    private func photoURL(_ photo: StoredMealImage) -> URL {
        photosURL.appendingPathComponent(photo.id.uuidString).appendingPathExtension("photo")
    }

    private func prepareDirectories() throws {
        for directory in [directory, photosURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            #endif
        }
        var photos = photosURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try photos.setResourceValues(values)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
