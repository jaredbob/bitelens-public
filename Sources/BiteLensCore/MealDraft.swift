import Foundation
import ImageIO

/// The chosen meal time and local calendar day are independent of photo retention.
public struct MealTime: Codable, Equatable, Sendable {
    static let localDateFormat = Date.ISO8601FormatStyle(timeZone: .gmt)
        .year().month().day().dateSeparator(.dash)

    public let instant: Date
    public let localDate: String
    public let timeZoneIdentifier: String

    /// The recorded Gregorian date represented at midnight UTC.
    public var calendarDate: Date? { try? Self.localDateFormat.parse(localDate) }

    public init(instant: Date, timeZone: TimeZone) {
        self.instant = instant
        timeZoneIdentifier = timeZone.identifier
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        localDate = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    init?(localTimestamp: String, format: String, timeZone: TimeZone) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        guard let instant = formatter.date(from: localTimestamp), formatter.string(from: instant) == localTimestamp
        else { return nil }
        self.init(instant: instant, timeZone: timeZone)
    }
}

public struct StoredMealImage: Codable, Equatable, Sendable {
    static let retentionInterval: TimeInterval = 168 * 60 * 60
    public let id: UUID
    public let retentionStartedAt: Date
    public var expiresAt: Date { retentionStartedAt.addingTimeInterval(Self.retentionInterval) }

    public var capturedAt: Date { retentionStartedAt }

    private enum CodingKeys: String, CodingKey { case id, retentionStartedAt = "capturedAt" }
}

public typealias MealPhoto = StoredMealImage

/// Contains structured local data and an opaque image identity, never image bytes.
public struct MealDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public internal(set) var photo: StoredMealImage?
    public internal(set) var notes: String
    public internal(set) var mealTime: MealTime
    public internal(set) var review: MealReview? = nil
    var importedImage: ImportedMealImage? = nil
    var linkingUrgeID: UUID? = nil
    public var isImportedImage: Bool { importedImage != nil }
    public var needsMealTime: Bool { importedImage?.timeSelection == .required }
    public var hasSuggestedMealTime: Bool { importedImage?.timeSelection.isSuggested == true }
    public var usesImportDateForMealTime: Bool { importedImage?.timeSelection == .suggestedOnImportDate }
    public var canRetakePhoto: Bool { photo != nil && !isImportedImage && review?.originatingItemIDs == nil }

    mutating func applyImageTimeSuggestion(_ image: MealImageEstimate?, now: Date) {
        guard let photo, let importedImage, importedImage.timeSelection != .entered else { return }
        let suggestedTime: MealTime?
        var selection = ImportedMealImage.TimeSelection.suggested
        switch image {
        case .foodPhoto:
            suggestedTime = importedImage.photoTime
        case .receipt(let orderTime, _):
            let timeOnly = orderTime.map { $0.count < 16 } ?? false
            if timeOnly { selection = .suggestedOnImportDate }
            suggestedTime = orderTime.flatMap { timestamp in
                let localLength = timeOnly ? 5 : 16
                let offset = timestamp.dropFirst(localLength)
                let zone = offset.isEmpty ? importedImage.timeZone :
                    TimeZone(identifier: offset == "Z" ? "GMT" : "GMT\(offset)")
                guard let zone else { return nil }
                let localTime = String(timestamp.prefix(localLength))
                let importDay = MealTime(instant: photo.retentionStartedAt, timeZone: zone).localDate
                return MealTime(localTimestamp: timeOnly ? "\(importDay)T\(localTime)" : localTime,
                                format: "yyyy-MM-dd'T'HH:mm", timeZone: zone)
            }
        case nil:
            return
        }
        if let suggestedTime, suggestedTime.instant <= now {
            mealTime = suggestedTime
            self.importedImage?.timeSelection = selection
        } else if importedImage.timeSelection.isSuggested {
            mealTime = MealTime(instant: photo.retentionStartedAt, timeZone: importedImage.timeZone)
            self.importedImage?.timeSelection = .required
        }
    }
}

struct ImportedMealImage: Codable, Equatable, Sendable {
    enum TimeSelection: String, Codable, Sendable {
        case required, suggested, suggestedOnImportDate, entered

        var isSuggested: Bool { self == .suggested || self == .suggestedOnImportDate }
    }

    let photoTime: MealTime?
    let timeZone: TimeZone
    var timeSelection: TimeSelection = .required

    init(data: Data, timeZone: TimeZone) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { throw DraftIssue.invalidPhoto }
        self.timeZone = timeZone
        // Only a photo classified as showing food can use its original timestamp.
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
        let zone = offset.flatMap { TimeZone(identifier: "GMT\($0)") } ?? timeZone
        photoTime = (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap {
            MealTime(localTimestamp: $0, format: "yyyy:MM:dd HH:mm:ss", timeZone: zone)
        }
    }
}

public enum DraftIssue: Error, Equatable, Sendable {
    case storageUnavailable
    case draftNotFound
    case photoExpired
    case photoUnavailable
    case invalidPhoto
    case invalidCaptureTime
    case retakeAfterEstimate
    case retakeImportedImage
    case mealTimeRequired
}

extension MealWorkflow {
    public var drafts: [MealDraft] { access == .owner ? localMeals.drafts : [] }
    public var nextPhotoExpiration: Date? {
        [scheduledPhotoExpiration, inactivePhotoExpiration, sharedImageExpiration].compactMap { $0 }.min()
    }

    public func isPhotoExpired(_ photo: StoredMealImage) -> Bool {
        photo.expiresAt <= max(photoCleanupEvaluatedAt, now())
    }

    /// Called on launch/unlock and each return to the foreground. No network.
    /// Retention maintenance also runs signed out; only the owner sees restored records.
    public func resumeLocalWork() {
        resumeLocalWork(requestHealthAuthorization: true)
    }

    private func resumeLocalWork(requestHealthAuthorization: Bool) {
        let cleanupTime = now()
        if let accountDirectory {
            inactivePhotoExpiration = cleanInactivePhotos(in: accountDirectory, at: cleanupTime)
        }
        // Clean up unclaimed images even when this account has no open draft store.
        let pendingSharedImages: [UUID]
        var sharedStorageUnavailable = false
        do {
            if let sharedImageInbox {
                if isBeta, let activeAccountID { try sharedImageInbox.setActiveAccount(activeAccountID) }
                let pending = try sharedImageInbox.pending(for: sharedImageAccountID, at: cleanupTime)
                sharedImageExpiration = pending.expiresAt
                pendingSharedImages = pending.ids
            } else {
                pendingSharedImages = []
            }
        } catch {
            sharedImageExpiration = nil
            pendingSharedImages = []
            sharedStorageUnavailable = true
        }
        guard let draftStorage else { return }
        loadBetaAppleHealthAccount()
        localMealsLoaded = false
        let restored: LocalMealLibrary
        do { restored = try draftStorage.load() }
        catch {
            scheduledPhotoExpiration = nil
            if access == .owner { issue = .storageUnavailable }
            return
        }
        if access == .owner {
            localMeals = restored
            localMealsLoaded = true
        }
        let photos = restored.photos
        photoCleanupEvaluatedAt = cleanupTime
        schedulePhotoCleanup(retaining: photos)
        do {
            try draftStorage.cleanPhotos(retaining: photos, now: cleanupTime)
            try receiveSharedMealImages(pendingSharedImages, at: cleanupTime)
            if access == .owner {
                if sharedStorageUnavailable { issue = .storageUnavailable }
                else if issue == .storageUnavailable { issue = nil }
            }
        }
        catch { if access == .owner { issue = .storageUnavailable } }
        // Offer new data types after an explicit sync action for existing opt-ins.
        scheduleAppleHealthSync(requestAuthorization: requestHealthAuthorization &&
                                localMeals.appleHealthAuthorizationRequest != .completed)
        scheduleObservationAppleHealthSync()
    }

    private func cleanInactivePhotos(in directory: URL, at now: Date) -> Date? {
        guard let accounts = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        return accounts.compactMap { account -> Date? in
            guard let id = UUID(uuidString: account.lastPathComponent), id != activeAccountID else { return nil }
            let storage = LocalMealDraftStorage(directory: account)
            guard let library = try? storage.load() else { return nil }
            try? storage.cleanPhotos(retaining: library.photos, now: now)
            return library.photos.lazy.map(\.expiresAt).filter { $0 > now }.min()
        }.min()
    }

    /// The active scene owns this task. A changed deadline or inactive scene cancels it.
    public func waitForPhotoExpiry(at deadline: Date,
                                   sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        while !Task.isCancelled, nextPhotoExpiration == deadline {
            let remaining = deadline.timeIntervalSince(now())
            if remaining <= 0 {
                resumeLocalWork(requestHealthAuthorization: false)
                return
            }
            do { try await sleep(.seconds(remaining)) }
            catch { return }
        }
    }

    @discardableResult public func captureMeal(photoData: Data, capturedAt: Date? = nil,
                                               timeZone: TimeZone = .current,
                                               linkingUrgeID: UUID? = nil) throws -> MealDraft {
        try saveNewDraft(photoData: photoData, capturedAt: capturedAt, timeZone: timeZone, linkingUrgeID: linkingUrgeID)
    }

    public func startManualDraft(timeZone: TimeZone = .current, linkingUrgeID: UUID? = nil) throws -> MealDraft {
        if let linkingUrgeID { _ = try urgeIndex(for: linkingUrgeID) }
        let draft = MealDraft(id: UUID(), photo: nil, notes: "",
                              mealTime: MealTime(instant: now(), timeZone: timeZone), linkingUrgeID: linkingUrgeID)
        var updated = localMeals
        updated.drafts.append(draft)
        try saveLocalMeals(updated)
        return draft
    }

    @discardableResult public func importMealImage(_ data: Data, timeZone: TimeZone = .current,
                                                  linkingUrgeID: UUID? = nil) throws -> MealDraft {
        let importedImage = try ImportedMealImage(data: data, timeZone: timeZone)
        return try saveNewDraft(photoData: data, capturedAt: nil, timeZone: timeZone, importedImage: importedImage,
                                linkingUrgeID: linkingUrgeID)
    }

    private func saveNewDraft(photoData: Data, capturedAt: Date?, timeZone: TimeZone,
                              importedImage: ImportedMealImage? = nil, linkingUrgeID: UUID? = nil,
                              id: UUID = UUID()) throws -> MealDraft {
        let storage = try writableMealStorage()
        if let linkingUrgeID { _ = try urgeIndex(for: linkingUrgeID) }
        let photo = try validatedPhoto(data: photoData, capturedAt: capturedAt)
        let draft = MealDraft(id: id, photo: photo, notes: "",
                              mealTime: MealTime(instant: photo.retentionStartedAt, timeZone: timeZone),
                              importedImage: importedImage, linkingUrgeID: linkingUrgeID)
        var updated = localMeals
        updated.drafts.append(draft)
        try savePhoto(photoData, photo: photo, with: updated, using: storage)
        return draft
    }

    var sharedImageAccountID: UUID? { isBeta ? activeAccountID : nil }

    private func receiveSharedMealImages(_ ids: [UUID], at now: Date) throws {
        guard let inbox = sharedImageInbox, access == .owner, !ids.isEmpty else { return }
        let accountID = sharedImageAccountID
        for id in ids {
            // A previous import may have committed just before BiteLens stopped running.
            if !localMeals.drafts.contains(where: { $0.id == id }), !localMeals.loggedMeals.contains(where: { $0.id == id }) {
                do {
                    let entry = try inbox.read(id, for: accountID)
                    let image = try ImportedMealImage(data: entry.data, timeZone: entry.timeZone)
                    _ = try saveNewDraft(photoData: entry.data, capturedAt: entry.sharedAt, timeZone: entry.timeZone,
                                         importedImage: image, id: id)
                } catch DraftIssue.photoExpired {
                    // The inbox entry can cross its deadline between enumeration and import.
                } catch DraftIssue.invalidPhoto {
                    // Unreadable images can't become drafts.
                } catch is DecodingError {
                    // A damaged entry should not prevent other images from being imported.
                } catch CocoaError.fileReadNoSuchFile {
                    // A concurrent expiry cleanup already removed the entry.
                }
            }
            if localMeals.drafts.contains(where: { $0.id == id }) { sharedDraftToOpen = id }
            try inbox.remove(id, for: accountID)
        }
        sharedImageExpiration = try inbox.pending(for: accountID, at: now).expiresAt
    }

    public func didOpenSharedDraft(_ id: UUID) {
        if sharedDraftToOpen == id { sharedDraftToOpen = nil }
    }

    public func updateDraftNotes(_ id: UUID, notes: String) throws {
        let index = try draftIndex(for: id)
        var updated = localMeals
        updated.drafts[index].notes = notes
        try saveLocalMeals(updated)
    }

    public func setMealTime(_ id: UUID, instant: Date, timeZone: TimeZone) throws {
        let index = try draftIndex(for: id)
        var updated = localMeals
        updated.drafts[index].mealTime = MealTime(instant: instant, timeZone: timeZone)
        updated.drafts[index].importedImage?.timeSelection = .entered
        try saveLocalMeals(updated)
    }

    public func retakePhoto(for id: UUID, photoData: Data, capturedAt: Date? = nil) throws {
        let index = try draftIndex(for: id)
        guard let previous = localMeals.drafts[index].photo else { throw DraftIssue.photoUnavailable }
        guard !localMeals.drafts[index].isImportedImage else { throw DraftIssue.retakeImportedImage }
        guard localMeals.drafts[index].canRetakePhoto else { throw DraftIssue.retakeAfterEstimate }
        let storage = try writableMealStorage()
        let replacement = try validatedPhoto(data: photoData, capturedAt: capturedAt)
        var updated = localMeals
        updated.drafts[index].photo = replacement
        try savePhoto(photoData, photo: replacement, with: updated, using: storage)
        // Foreground cleanup removes the unreferenced file if interrupted.
        try? storage.removePhoto(previous)
    }

    public func discardDraft(_ id: UUID) throws {
        let index = try draftIndex(for: id)
        try sharedImageInbox?.remove(id, for: sharedImageAccountID)
        var updated = localMeals
        let discarded = updated.drafts.remove(at: index)
        try saveLocalMeals(updated)
        if let photo = discarded.photo { try? draftStorage?.removePhoto(photo) }
    }

    /// Draft previews and future analysis both use this guarded action.
    public func photoData(for id: UUID) throws -> Data {
        let index = try draftIndex(for: id)
        return try readPhoto(localMeals.drafts[index].photo)
    }

    func draftIndex(for id: UUID) throws -> Int {
        guard access == .owner else { throw WorkflowIssue.accessDenied }
        guard let index = localMeals.drafts.firstIndex(where: { $0.id == id }) else { throw DraftIssue.draftNotFound }
        return index
    }

    func readPhoto(_ photo: StoredMealImage?) throws -> Data {
        guard let photo else { throw DraftIssue.photoUnavailable }
        guard let draftStorage else { throw DraftIssue.storageUnavailable }
        guard !isPhotoExpired(photo) else {
            try? draftStorage.removePhoto(photo)
            throw DraftIssue.photoExpired
        }
        do { return try draftStorage.readPhoto(photo) }
        catch { throw DraftIssue.photoUnavailable }
    }

    func saveLocalMeals(_ updated: LocalMealLibrary) throws {
        let storage = try writableMealStorage()
        do { try storage.save(updated) }
        catch { throw DraftIssue.storageUnavailable }
        localMeals = updated
        schedulePhotoCleanup(retaining: updated.photos)
    }

    private func schedulePhotoCleanup(retaining photos: [StoredMealImage]) {
        // A save racing expiry must keep the deadline until cleanup has run.
        let cutoff = photoCleanupEvaluatedAt
        scheduledPhotoExpiration = photos.lazy.map(\.expiresAt).filter { $0 > cutoff }.min()
    }

    private func validatedPhoto(data: Data, capturedAt: Date?) throws -> StoredMealImage {
        guard !data.isEmpty else { throw DraftIssue.invalidPhoto }
        let currentTime = now()
        let instant = capturedAt ?? currentTime
        guard instant <= currentTime else { throw DraftIssue.invalidCaptureTime }
        let photo = StoredMealImage(id: UUID(), retentionStartedAt: instant)
        guard currentTime < photo.expiresAt else { throw DraftIssue.photoExpired }
        return photo
    }

    private func writableMealStorage() throws -> LocalMealDraftStorage {
        guard access == .owner else { throw WorkflowIssue.accessDenied }
        guard localMealsLoaded, let draftStorage else { throw DraftIssue.storageUnavailable }
        return draftStorage
    }

    private func savePhoto(_ data: Data, photo: StoredMealImage, with updated: LocalMealLibrary,
                           using storage: LocalMealDraftStorage) throws {
        do {
            try storage.writePhoto(data, photo: photo)
            try saveLocalMeals(updated)
        } catch {
            try? storage.removePhoto(photo)
            throw DraftIssue.storageUnavailable
        }
    }
}
