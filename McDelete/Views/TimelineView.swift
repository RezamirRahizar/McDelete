import SwiftUI
import Photos

/// Vertical thumbnail strip showing previous, current, and upcoming assets.
/// Tapping any thumbnail navigates to it; skipped assets (jumped past without a decision) are shown with a distinct style.
struct TimelineView: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(library.assets.enumerated()), id: \.element.localIdentifier) { i, asset in
                        let isSkipped = i < library.index && library.decision(for: i) == nil
                        TimelineThumbnail(
                            asset: asset,
                            imageManager: library.imageManager,
                            decision: library.decision(for: i),
                            isSkipped: isSkipped,
                            isCurrent: i == library.index
                        )
                        .id(asset.localIdentifier)
                        .onTapGesture { library.jumpTo(assetIndex: i) }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
            .onChange(of: library.index) { _, _ in scrollToCurrent(proxy) }
            .onAppear { scrollToCurrent(proxy) }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let asset = library.currentAsset else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(asset.localIdentifier, anchor: .center)
        }
    }
}

// MARK: - Thumbnail cell

private struct TimelineThumbnail: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager
    let decision: PhotoLibrary.Decision?
    let isSkipped: Bool
    let isCurrent: Bool

    @State private var image: NSImage?

    private var size: CGFloat { isCurrent ? 72 : 58 }
    private var radius: CGFloat { isCurrent ? 10 : 8 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(borderOverlay)
            .opacity(isSkipped ? 0.5 : 1)
            .shadow(color: isCurrent ? .black.opacity(0.22) : .clear, radius: 6, y: 3)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isCurrent)

            badge
        }
        .task(id: asset.localIdentifier) { loadThumbnail() }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if isCurrent {
            shape.strokeBorder(Color.accentColor, lineWidth: 3)
        } else if let decision {
            shape.strokeBorder(
                decision == .kept ? Color.green.opacity(0.85) : Color.red.opacity(0.85),
                lineWidth: 1.5
            )
        } else if isSkipped {
            shape.strokeBorder(
                Color.orange.opacity(0.7),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let decision {
            Image(systemName: decision == .kept ? "checkmark.circle.fill" : "trash.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(decision == .kept ? Color.green : Color.red)
                .background(Circle().fill(.background).padding(-2))
                .padding(3)
        } else if isSkipped {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)
                .background(Circle().fill(.background).padding(-2))
                .padding(3)
        }
    }

    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: 144, height: 144),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            if let result { self.image = result }
        }
    }
}


