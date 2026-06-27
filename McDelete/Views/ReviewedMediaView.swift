import SwiftUI
import Photos

struct ReviewedMediaView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var deletionFailed = false
    @State private var selectedItem: AssetSelection?

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 2)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabPicker
            Divider()
            content
            if selectedTab == 1 && !library.pendingDeletion.isEmpty {
                Divider()
                deleteBar
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .sheet(item: $selectedItem) { item in
            AssetPreviewSheet(assets: item.allAssets, startIndex: item.index, imageManager: library.imageManager)
        }
        .alert("Couldn't delete items", isPresented: $deletionFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The deletion was cancelled or failed. Your photos are unchanged.")
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("Reviewed Media")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            Label("Kept (\(library.keptCount))", systemImage: "checkmark.circle.fill").tag(0)
            Label("To Delete (\(library.pendingDeletion.count))", systemImage: "trash.fill").tag(1)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        let assets = selectedTab == 0 ? library.keptAssets : library.pendingDeletion
        if assets.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: selectedTab == 0 ? "checkmark.circle" : "trash")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(selectedTab == 0 ? "No items kept yet" : "No items marked for deletion")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                        Button {
                            selectedItem = AssetSelection(asset, index: idx, in: assets)
                        } label: {
                            ReviewedAssetCell(asset: asset, imageManager: library.imageManager)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                }
            }
        }
    }

    private var deleteBar: some View {
        HStack {
            if library.pendingDeletionBytes > 0 {
                Label(library.pendingDeletionSize, systemImage: "internaldrive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if library.isDeleting { ProgressView().padding(.trailing, 8) }
            Button {
                Task {
                    let ok = await library.confirmDeletions()
                    if ok { dismiss() } else { deletionFailed = true }
                }
            } label: {
                let count = library.pendingDeletion.count
                Label("Delete \(count) item\(count == 1 ? "" : "s")", systemImage: "trash.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(library.isDeleting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Identifiable wrapper for sheet(item:)

private struct AssetSelection: Identifiable {
    let id: String
    let asset: PHAsset
    let index: Int
    let allAssets: [PHAsset]

    init(_ asset: PHAsset, index: Int, in assets: [PHAsset]) {
        id = asset.localIdentifier
        self.asset = asset
        self.index = index
        allAssets = assets
    }
}

// MARK: - Full-size preview sheet with left/right navigation

private struct AssetPreviewSheet: View {
    let assets: [PHAsset]
    let imageManager: PHCachingImageManager
    @State private var currentIndex: Int
    @Environment(\.dismiss) private var dismiss

    init(assets: [PHAsset], startIndex: Int, imageManager: PHCachingImageManager) {
        self.assets = assets
        self.imageManager = imageManager
        _currentIndex = State(initialValue: startIndex)
    }

    private var asset: PHAsset { assets[currentIndex] }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            MediaCardView(asset: asset, imageManager: imageManager)
                .id(asset.localIdentifier)
                .padding(20)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            // Prev/next navigation
            HStack(spacing: 2) {
                Button {
                    currentIndex -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 32, height: 28)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(currentIndex == 0)

                Button {
                    currentIndex += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 32, height: 28)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(currentIndex == assets.count - 1)
            }
            .buttonStyle(.borderless)

            Text("\(currentIndex + 1) of \(assets.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.leading, 10)

            Spacer()

            // Metadata
            HStack(spacing: 6) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                }
                if let date = asset.creationDate {
                    Label(date.formatted(date: .abbreviated, time: .shortened),
                          systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Thumbnail cell

private struct ReviewedAssetCell: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager
    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.mediaType == .video {
                    Image(systemName: "video.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .clipped()
            .task(id: asset.localIdentifier) { loadThumbnail() }
    }

    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: 256, height: 256),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            if let result { self.image = result }
        }
    }
}
