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

    private(set) var status: PHAuthorizationStatus
    private(set) var assets: [PHAsset] = []
    private(set) var index = 0
    private(set) var keptCount = 0
    private(set) var pendingDeletion: [PHAsset] = []

    var isLoading = false
    var isDeleting = false
    var sortOrder: SortOrder = .oldestFirst

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

    var hasStarted: Bool { !assets.isEmpty }
    var isFinished: Bool { !assets.isEmpty && index >= assets.count }
    var reviewedCount: Int { index }
    var totalCount: Int { assets.count }
    var canUndo: Bool { !history.isEmpty }

    var progress: Double {
        assets.isEmpty ? 0 : Double(min(index, assets.count)) / Double(assets.count)
    }

    // MARK: - Authorization & loading

    func requestAccess() async {
        let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        status = newStatus
        print(status.rawValue)
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

        let result = PHAsset.fetchAssets(with: options)
        var collected: [PHAsset] = []
        collected.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in collected.append(asset) }
        if sortOrder == .random { collected.shuffle() }

        assets = collected
        index = 0
        keptCount = 0
        pendingDeletion = []
        history = []
    }

    // MARK: - Decisions

    func keep() {
        guard currentAsset != nil else { return }
        history.append((index, .kept))
        keptCount += 1
        advance()
    }

    func markForDeletion() {
        guard let asset = currentAsset else { return }
        history.append((index, .deleted))
        pendingDeletion.append(asset)
        advance()
    }

    func undo() {
        guard let last = history.popLast() else { return }
        index = last.index
        switch last.decision {
        case .kept:
            keptCount = max(0, keptCount - 1)
        case .deleted:
            if let asset = currentAsset, let pos = pendingDeletion.lastIndex(of: asset) {
                pendingDeletion.remove(at: pos)
            }
        }
    }

    private func advance() {
        index = min(index + 1, assets.count)
    }

    // MARK: - Committing deletions

    /// Moves every asset marked for deletion to the system "Recently Deleted" album.
    /// macOS shows its own confirmation dialog before the change is applied.
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
            // Drop the deleted assets and continue with whatever is left.
            let deletedIDs = Set(toDelete.map(\.localIdentifier))
            assets.removeAll { deletedIDs.contains($0.localIdentifier) }
            pendingDeletion = []
            history = []
            index = 0
            keptCount = 0
            return true
        } catch {
            return false
        }
    }
}
