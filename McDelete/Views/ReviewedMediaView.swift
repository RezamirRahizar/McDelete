import SwiftUI
import Photos

struct ReviewedMediaView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var deletionFailed = false

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
                    ForEach(assets, id: \.localIdentifier) { asset in
                        ReviewedAssetCell(asset: asset, imageManager: library.imageManager)
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

// MARK: - Thumbnail cell

private struct ReviewedAssetCell: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.18)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()

            if asset.mediaType == .video {
                Image(systemName: "video.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(5)
            }
        }
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
