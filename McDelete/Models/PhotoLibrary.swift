import SwiftUI
import Photos

/// Owns access to the system photo library and the keep/delete review state.
@MainActor
@Observable
final class PhotoLibrary {

    enum Decision { case kept, deleted }

    /// Order in which assets are presented for review.
    enum SortOrder: String, CaseIterable, Identifiable {
        case oldestFirst = "Oldest first"
        case newestFirst = "Newest first"
        case random = "Shuffle"
        var id: String { rawValue }
    }

    /// Which media types to include in the review session.
    enum MediaFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case photos = "Photos"
        case videos = "Videos"
        case screenshots = "Screenshots"
        case livePhotos = "Live Photos"
        case duplicates = "Duplicates"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .all: return "photo.stack"
            case .photos: return "photo"
            case .videos: return "video"
            case .screenshots: return "camera.viewfinder"
            case .livePhotos: return "livephoto"
            case .duplicates: return "square.on.square"
            }
        }
    }

    private(set) var status: PHAuthorizationStatus
    /// Only unreviewed assets; previously reviewed ones are restored from Core Data.
    private(set) var assets: [PHAsset] = []
    private(set) var index = 0
    private(set) var keptCount = 0
    private(set) var keptAssets: [PHAsset] = []
    private(set) var pendingDeletion: [PHAsset] = []
    private(set) var pendingDeletionBytes: Int64 = 0
    /// Total photos matching the current filter, including already-reviewed ones.
    private(set) var libraryTotalCount = 0
    private(set) var reviewedPhotoCount = 0
    private(set) var reviewedVideoCount = 0
    private(set) var activeReviewSeconds: Int = 0

    var isLoading = false
    var isDeleting = false
    var sortOrder: SortOrder = .oldestFirst
    var mediaFilter: MediaFilter = .all
    var dateRangeEnabled: Bool = false
    var startDate: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var endDate: Date = Date()
    /// Local identifier of the album to restrict review to; empty string means all photos.
    var selectedAlbumID: String = ""
    /// All available albums (smart + user), populated after authorization.
    private(set) var albums: [PHAssetCollection] = []

    private var hasLoaded = false
    private var sessionStartDate: Date? = nil
    private(set) var sessionEndDate: Date? = nil
    /// (asset index, decision made) so the most recent choice can be undone.
    private var history: [(index: Int, decision: Decision)] = []

    let imageManager = PHCachingImageManager()

    private static let activeReviewSecondsKey = "activeReviewSeconds"

    init() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        activeReviewSeconds = UserDefaults.standard.integer(forKey: PhotoLibrary.activeReviewSecondsKey)
    }

    func incrementActiveTime() {
        activeReviewSeconds += 1
        UserDefaults.standard.set(activeReviewSeconds, forKey: PhotoLibrary.activeReviewSecondsKey)
    }

    func resetActiveTime() {
        activeReviewSeconds = 0
        UserDefaults.standard.removeObject(forKey: PhotoLibrary.activeReviewSecondsKey)
    }

    /// Human-readable elapsed active-review time (e.g. "3:07", "1:02:09", "2d 4h 11m").
    var formattedElapsedTime: String {
        let total = activeReviewSeconds
        let weeks   = total / 604800
        let days    = (total % 604800) / 86400
        let hours   = (total % 86400)  / 3600
        let minutes = (total % 3600)   / 60
        let seconds = total % 60
        if weeks > 0  { return "\(weeks)w \(days)d \(hours)h" }
        if days > 0   { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0  { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Derived state

    var currentAsset: PHAsset? {
        assets.indices.contains(index) ? assets[index] : nil
    }

    var hasStarted: Bool { hasLoaded }
    var isFinished: Bool { hasLoaded && index >= assets.count }
    var reviewedCount: Int { index }
    var totalCount: Int { assets.count }
    var totalReviewed: Int { keptCount + pendingDeletion.count }
    var canUndo: Bool { !history.isEmpty }
    var pendingDeletionSize: String {
        ByteCountFormatter.string(fromByteCount: pendingDeletionBytes, countStyle: .file)
    }

    var sessionDuration: TimeInterval? {
        guard let start = sessionStartDate, let end = sessionEndDate else { return nil }
        return end.timeIntervalSince(start)
    }

    /// Returns the session decision for the asset at the given index, if any.
    func decision(for assetIndex: Int) -> Decision? {
        history.last(where: { $0.index == assetIndex })?.decision
    }

    /// Navigates to the asset at the given index, undoing any session decisions that come after it.
    func jumpTo(assetIndex: Int) {
        guard assets.indices.contains(assetIndex) else { return }
        if assetIndex <= index {
            while index > assetIndex {
                guard let last = history.last, last.index >= assetIndex else { break }
                undo()
            }
            index = assetIndex
        } else {
            index = assetIndex
        }
    }

    var progress: Double {
        assets.isEmpty ? 0 : Double(min(index, assets.count)) / Double(assets.count)
    }

    // MARK: - Authorization & loading

    func requestAccess() async {
        let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        status = newStatus
        if newStatus == .authorized || newStatus == .limited {
            await loadAssets()
        }
    }

    func loadAssets() async {
        isLoading = true
        defer { isLoading = false }

        fetchAlbums()

        let options = PHFetchOptions()
        let ascending = sortOrder == .oldestFirst
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
        options.predicate = buildPredicate()

        let fetchResult: PHFetchResult<PHAsset>
        if !selectedAlbumID.isEmpty {
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [selectedAlbumID], options: nil)
            if let collection = collections.firstObject {
                fetchResult = PHAsset.fetchAssets(in: collection, options: options)
            } else {
                // Album was deleted; reset and fetch everything
                selectedAlbumID = ""
                fetchResult = PHAsset.fetchAssets(with: options)
            }
        } else {
            fetchResult = PHAsset.fetchAssets(with: options)
        }

        var collected: [PHAsset] = []
        collected.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in collected.append(asset) }
        if sortOrder == .random { collected.shuffle() }
        if mediaFilter == .duplicates { collected = extractDuplicates(from: collected) }

        libraryTotalCount = collected.count

        let saved = PersistenceController.shared.fetchAllDecisions()
        var kept = 0
        var keptList: [PHAsset] = []
        var toDelete: [PHAsset] = []
        var unreviewed: [PHAsset] = []

        for asset in collected {
            if let markedForDeletion = saved[asset.localIdentifier] {
                if markedForDeletion { toDelete.append(asset) } else { kept += 1; keptList.append(asset) }
            } else {
                unreviewed.append(asset)
            }
        }

        assets = unreviewed
        pendingDeletion = toDelete
        pendingDeletionBytes = toDelete.reduce(0) { $0 + fileSize(for: $1) }
        keptCount = kept
        keptAssets = keptList
        index = 0
        history = []
        reviewedPhotoCount = 0
        reviewedVideoCount = 0
        sessionStartDate = Date()
        sessionEndDate = nil
        hasLoaded = true
    }

    /// Clears all saved decisions and reloads the full library from scratch.
    func resetAndLoadAssets() async {
        PersistenceController.shared.deleteAllDecisions()
        await loadAssets()
    }

    // MARK: - Decisions

    func keep() {
        guard let asset = currentAsset else { return }
        history.append((index, .kept))
        keptCount += 1
        keptAssets.append(asset)
        trackMediaType(asset)
        PersistenceController.shared.saveDecision(localIdentifier: asset.localIdentifier, markedForDeletion: false)
        advance()
    }

    func markForDeletion() {
        guard let asset = currentAsset else { return }
        history.append((index, .deleted))
        pendingDeletion.append(asset)
        pendingDeletionBytes += fileSize(for: asset)
        trackMediaType(asset)
        PersistenceController.shared.saveDecision(localIdentifier: asset.localIdentifier, markedForDeletion: true)
        advance()
    }

    func undo() {
        guard let last = history.popLast(), assets.indices.contains(last.index) else { return }
        index = last.index
        let asset = assets[index]
        PersistenceController.shared.removeDecision(for: asset.localIdentifier)
        untrackMediaType(asset)
        switch last.decision {
        case .kept:
            keptCount = max(0, keptCount - 1)
            if let pos = keptAssets.lastIndex(of: asset) { keptAssets.remove(at: pos) }
        case .deleted:
            if let pos = pendingDeletion.lastIndex(of: asset) {
                pendingDeletion.remove(at: pos)
            }
            pendingDeletionBytes = max(0, pendingDeletionBytes - fileSize(for: asset))
        }
    }

    private func trackMediaType(_ asset: PHAsset) {
        switch asset.mediaType {
        case .image: reviewedPhotoCount += 1
        case .video: reviewedVideoCount += 1
        default: break
        }
    }

    private func untrackMediaType(_ asset: PHAsset) {
        switch asset.mediaType {
        case .image: reviewedPhotoCount = max(0, reviewedPhotoCount - 1)
        case .video: reviewedVideoCount = max(0, reviewedVideoCount - 1)
        default: break
        }
    }

    private func advance() {
        index = min(index + 1, assets.count)
        if isFinished, sessionEndDate == nil {
            sessionEndDate = Date()
        }
    }

    // MARK: - Committing deletions

    /// Moves every asset marked for deletion to the system "Recently Deleted" album.
    @discardableResult
    func confirmDeletions() async -> Bool {
        guard !pendingDeletion.isEmpty else { return true }
        isDeleting = true
        defer { isDeleting = false }

        let toDelete = pendingDeletion
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
            }
            let deletedIDs = Set(toDelete.map(\.localIdentifier))
            PersistenceController.shared.removeDecisions(for: deletedIDs)
            pendingDeletion = []
            pendingDeletionBytes = 0
            history = []
            resetActiveTime()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private helpers

    private func fileSize(for asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset)
            .compactMap { $0.value(forKey: "fileSize") as? Int64 }
            .reduce(0, +)
    }

    /// Populates `albums` with smart albums (curated order) followed by user albums (sorted by name).
    private func fetchAlbums() {
        var result: [PHAssetCollection] = []

        let smartSubtypes: [PHAssetCollectionSubtype] = [
            .smartAlbumFavorites, .smartAlbumRecentlyAdded, .smartAlbumVideos,
            .smartAlbumSlomoVideos, .smartAlbumTimelapses, .smartAlbumLivePhotos,
            .smartAlbumSelfPortraits, .smartAlbumScreenshots, .smartAlbumBursts,
            .smartAlbumAnimated, .smartAlbumLongExposures, .smartAlbumCinematic
        ]
        for subtype in smartSubtypes {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
                .enumerateObjects { col, _, _ in result.append(col) }
        }

        var userAlbums: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { col, _, _ in userAlbums.append(col) }
        userAlbums.sort { ($0.localizedTitle ?? "") < ($1.localizedTitle ?? "") }
        result.append(contentsOf: userAlbums)

        albums = result
    }

    private func buildPredicate() -> NSPredicate? {
        var predicates: [NSPredicate] = []

        switch mediaFilter {
        case .all, .duplicates:
            // Duplicates are post-filtered; fetch all media types first
            break
        case .photos:
            predicates.append(NSPredicate(format: "mediaType == %d",
                PHAssetMediaType.image.rawValue))
        case .videos:
            predicates.append(NSPredicate(format: "mediaType == %d",
                PHAssetMediaType.video.rawValue))
        case .screenshots:
            predicates.append(NSPredicate(format: "mediaType == %d AND (mediaSubtype & %d) != 0",
                PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue))
        case .livePhotos:
            predicates.append(NSPredicate(format: "mediaType == %d AND (mediaSubtype & %d) != 0",
                PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoLive.rawValue))
        }

        if dateRangeEnabled {
            let cal = Calendar.current
            let start = cal.startOfDay(for: startDate)
            var comps = cal.dateComponents([.year, .month, .day], from: endDate)
            comps.hour = 23; comps.minute = 59; comps.second = 59
            let end = cal.date(from: comps) ?? endDate
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
            predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate))
        }

        switch predicates.count {
        case 0: return nil
        case 1: return predicates[0]
        default: return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
    }

    /// Returns assets that belong to groups of 2 or more near-identical items.
    private func extractDuplicates(from assets: [PHAsset]) -> [PHAsset] {
        let duplicateIDs = Set(duplicateGroups(from: assets).flatMap { $0 }.map(\.localIdentifier))
        return assets.filter { duplicateIDs.contains($0.localIdentifier) }
    }

    /// Groups near-identical assets into clusters of 2 or more.
    /// Groups by burst identifier first, then by same creation second + same pixel dimensions.
    private func duplicateGroups(from assets: [PHAsset]) -> [[PHAsset]] {
        var groups: [[PHAsset]] = []

        // Burst groups
        var burstGroups: [String: [PHAsset]] = [:]
        for asset in assets {
            if let burstID = asset.burstIdentifier {
                burstGroups[burstID, default: []].append(asset)
            }
        }
        for (_, group) in burstGroups where group.count > 1 {
            groups.append(group)
        }

        // Same-second + same-dimension groups (non-burst assets only)
        let cal = Calendar.current
        var timestampGroups: [String: [PHAsset]] = [:]
        for asset in assets where asset.burstIdentifier == nil {
            guard let date = asset.creationDate else { continue }
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let key = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)-\(c.hour ?? 0)-\(c.minute ?? 0)-\(c.second ?? 0)-\(asset.pixelWidth)x\(asset.pixelHeight)"
            timestampGroups[key, default: []].append(asset)
        }
        for (_, group) in timestampGroups where group.count > 1 {
            groups.append(group)
        }

        return groups
    }

    // MARK: - Auto-merge duplicates

    /// Number of unreviewed assets that auto-merge would mark for deletion,
    /// i.e. duplicates that aren't the chosen keeper of their group (favorites excluded).
    var autoMergeCandidateCount: Int {
        duplicateGroups(from: assets).reduce(0) { $0 + deletableMembers(in: $1).count }
    }

    /// Resolves every remaining duplicate group by keeping its best copy and marking the
    /// rest for deletion. Favorites are never marked. Decisions flow through the normal
    /// pending-deletion pipeline, so they're reversible until the user confirms.
    /// Returns the number of assets marked for deletion.
    @discardableResult
    func autoMergeDuplicates() -> Int {
        let deleteIDs = Set(
            duplicateGroups(from: assets)
                .flatMap { deletableMembers(in: $0) }
                .map(\.localIdentifier)
        )
        guard !deleteIDs.isEmpty else { return 0 }

        var marked = 0
        // Reuse the per-asset decision path so counts, history (undo) and persistence stay consistent.
        while let asset = currentAsset {
            if deleteIDs.contains(asset.localIdentifier) {
                markForDeletion()
                marked += 1
            } else {
                keep()
            }
        }
        return marked
    }

    /// The members of a duplicate group that should be marked for deletion:
    /// everything except the chosen keeper, never including favorites.
    private func deletableMembers(in group: [PHAsset]) -> [PHAsset] {
        guard group.count > 1 else { return [] }
        let keeper = bestKeeper(in: group)
        return group.filter { $0.localIdentifier != keeper.localIdentifier && !$0.isFavorite }
    }

    /// Picks the copy to keep from a duplicate group: favorite first, then most pixels,
    /// then the earliest capture (most likely the original).
    private func bestKeeper(in group: [PHAsset]) -> PHAsset {
        group.max { a, b in
            if a.isFavorite != b.isFavorite { return !a.isFavorite }   // favorite wins
            let pa = a.pixelWidth * a.pixelHeight
            let pb = b.pixelWidth * b.pixelHeight
            if pa != pb { return pa < pb }                              // more pixels wins
            let da = a.creationDate ?? .distantFuture
            let db = b.creationDate ?? .distantFuture
            return da > db                                             // earlier capture wins
        } ?? group[0]
    }
}
