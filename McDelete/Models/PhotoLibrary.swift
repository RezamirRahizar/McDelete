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
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .all: return "photo.stack"
            case .photos: return "photo"
            case .videos: return "video"
            case .screenshots: return "camera.viewfinder"
            case .livePhotos: return "livephoto"
            }
        }
    }

    private(set) var status: PHAuthorizationStatus
    /// Only unreviewed assets; previously reviewed ones are restored from Core Data.
    private(set) var assets: [PHAsset] = []
    private(set) var index = 0
    private(set) var keptCount = 0
    private(set) var pendingDeletion: [PHAsset] = []
    /// Total photos matching the current filter, including already-reviewed ones.
    private(set) var libraryTotalCount = 0

    var isLoading = false
    var isDeleting = false
    var sortOrder: SortOrder = .oldestFirst
    var mediaFilter: MediaFilter = .all

    private var hasLoaded = false
    /// (asset index, decision made) so the most recent choice can be undone.
    private var history: [(index: Int, decision: Decision)] = []

    let imageManager = PHCachingImageManager()

    init() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: - Derived state

    var currentAsset: PHAsset? {
        assets.indices.contains(index) ? assets[index] : nil
    }

    var hasStarted: Bool { hasLoaded }
    var isFinished: Bool { hasLoaded && index >= assets.count }
    var reviewedCount: Int { index }
    var totalCount: Int { assets.count }
    var canUndo: Bool { !history.isEmpty }

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

        let options = PHFetchOptions()
        let ascending = sortOrder == .oldestFirst
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]

        switch mediaFilter {
        case .all:
            break
        case .photos:
            options.predicate = NSPredicate(format: "mediaType == %d",
                PHAssetMediaType.image.rawValue)
        case .videos:
            options.predicate = NSPredicate(format: "mediaType == %d",
                PHAssetMediaType.video.rawValue)
        case .screenshots:
            options.predicate = NSPredicate(format: "mediaType == %d AND (mediaSubtype & %d) != 0",
                PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue)
        case .livePhotos:
            options.predicate = NSPredicate(format: "mediaType == %d AND (mediaSubtype & %d) != 0",
                PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoLive.rawValue)
        }

        let result = PHAsset.fetchAssets(with: options)
        var collected: [PHAsset] = []
        collected.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in collected.append(asset) }
        if sortOrder == .random { collected.shuffle() }

        libraryTotalCount = collected.count

        let saved = PersistenceController.shared.fetchAllDecisions()
        var kept = 0
        var toDelete: [PHAsset] = []
        var unreviewed: [PHAsset] = []

        for asset in collected {
            if let markedForDeletion = saved[asset.localIdentifier] {
                if markedForDeletion { toDelete.append(asset) } else { kept += 1 }
            } else {
                unreviewed.append(asset)
            }
        }

        assets = unreviewed
        pendingDeletion = toDelete
        keptCount = kept
        index = 0
        history = []
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
        PersistenceController.shared.saveDecision(localIdentifier: asset.localIdentifier, markedForDeletion: false)
        advance()
    }

    func markForDeletion() {
        guard let asset = currentAsset else { return }
        history.append((index, .deleted))
        pendingDeletion.append(asset)
        PersistenceController.shared.saveDecision(localIdentifier: asset.localIdentifier, markedForDeletion: true)
        advance()
    }

    func undo() {
        guard let last = history.popLast(), assets.indices.contains(last.index) else { return }
        index = last.index
        let asset = assets[index]
        PersistenceController.shared.removeDecision(for: asset.localIdentifier)
        switch last.decision {
        case .kept:
            keptCount = max(0, keptCount - 1)
        case .deleted:
            if let pos = pendingDeletion.lastIndex(of: asset) {
                pendingDeletion.remove(at: pos)
            }
        }
    }

    private func advance() {
        index = min(index + 1, assets.count)
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
            history = []
            return true
        } catch {
            return false
        }
    }
}
