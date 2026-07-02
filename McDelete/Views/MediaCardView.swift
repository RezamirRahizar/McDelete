import SwiftUI
import Photos
import AVKit
import AppKit

/// Renders a single asset: a still image, or an auto-playing, looping video (muted by default).
struct MediaCardView: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager

    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var isMuted = true
    /// Card size in points, measured from layout; drives the image request size.
    @State private var displaySize: CGSize = .zero
    /// The asset the current `image` belongs to, so a resize doesn't clear a valid image.
    @State private var loadedAssetID: String?

    /// Identity for the load task: changes on a new asset or a meaningfully different
    /// card size, so we re-request a right-sized image. Videos don't depend on size.
    private var loadRequestID: String {
        guard asset.mediaType != .video else { return "v-\(asset.localIdentifier)" }
        guard displaySize.width > 0 else { return "\(asset.localIdentifier)-pending" }
        let w = Int((displaySize.width / 100).rounded(.up)) * 100
        let h = Int((displaySize.height / 100).rounded(.up)) * 100
        return "\(asset.localIdentifier)-\(w)x\(h)"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.06))

            if asset.mediaType == .video {
                if let player {
                    LoopingVideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    ProgressView()
                }
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                ProgressView()
            }

            metadataBadges
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            displaySize = newSize
        }
        .task(id: loadRequestID) {
            await load()
        }
        .onChange(of: isMuted) { _, muted in
            player?.isMuted = muted
        }
    }

    // MARK: - Overlay badges

    private var metadataBadges: some View {
        VStack {
            HStack {
                if let date = asset.creationDate {
                    badge(systemImage: "calendar", text: date.formatted(date: .abbreviated, time: .omitted))
                }
                Spacer()
                if asset.isFavorite {
                    badge(systemImage: "heart.fill", text: "Favorite", tint: .pink)
                }
            }
            Spacer()
            if asset.mediaType == .video {
                HStack {
                    Spacer()
                    Button {
                        isMuted.toggle()
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }

    private func badge(systemImage: String, text: String, tint: Color = .white) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: - Loading

    private func load() async {
        if asset.mediaType == .video {
            image = nil
            await loadVideo()
        } else {
            player = nil
            loadImage()
        }
    }

    private func loadImage() {
        // Wait until the card has been laid out so we can request a right-sized image.
        guard displaySize.width > 0, displaySize.height > 0 else { return }

        // Only clear when moving to a different asset; a pure resize keeps the current
        // image on screen until the newly-sized one arrives (no flash to a spinner).
        if loadedAssetID != asset.localIdentifier {
            image = nil
        }
        loadedAssetID = asset.localIdentifier

        // Request at the card's pixel size rather than a fixed 2400² — keeps memory low.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let target = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)

        // Opportunistic delivery hands back a cached/degraded image almost instantly and
        // then the sharp one — this is what makes rapid decisions feel loading-free.
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        imageManager.requestImage(for: asset,
                                  targetSize: target,
                                  contentMode: .aspectFit,
                                  options: options) { result, _ in
            if let result { self.image = result }
        }
    }

    private func loadVideo() async {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        let item: AVPlayerItem? = await withCheckedContinuation { continuation in
            imageManager.requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
                continuation.resume(returning: playerItem)
            }
        }
        guard let item else { return }
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = isMuted
        self.player = newPlayer
    }
}

/// Direct AVPlayerView wrapper — avoids the SwiftUI VideoPlayer NSViewRepresentable
/// path that crashes on macOS 26 due to internal ViewResponderFilter metadata failure.
private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

/// Auto-plays and loops the supplied player.
private struct LoopingVideoPlayer: View {
    let player: AVPlayer
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        AVPlayerViewRepresentable(player: player)
            .onAppear {
                player.actionAtItemEnd = .none
                player.seek(to: .zero)
                player.play()
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: player.currentItem,
                    queue: .main
                ) { _ in
                    player.seek(to: .zero)
                    player.play()
                }
            }
            .onDisappear {
                player.pause()
                if let endObserver {
                    NotificationCenter.default.removeObserver(endObserver)
                }
            }
    }
}
