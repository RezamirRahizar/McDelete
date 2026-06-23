import SwiftUI
import Photos
import AVKit

/// Renders a single asset: a still image, or an auto-playing, looping, muted video.
struct MediaCardView: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager

    @State private var image: NSImage?
    @State private var player: AVPlayer?

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
        .task(id: asset.localIdentifier) {
            await load()
        }
    }

    // MARK: - Overlay badges

    private var metadataBadges: some View {
        VStack {
            HStack {
                if let date = asset.creationDate {
                    badge(systemName: "calendar", text: date.formatted(date: .abbreviated, time: .omitted))
                }
                Spacer()
                if asset.isFavorite {
                    badge(systemName: "heart.fill", text: "Favorite", tint: .pink)
                }
            }
            Spacer()
            HStack {
                if asset.mediaType == .video {
                    badge(systemName: "play.fill", text: durationText)
                }
                Spacer()
            }
        }
        .padding(16)
    }

    private func badge(systemName: String, text: String, tint: Color = .white) -> some View {
        Label(text, systemImage: systemName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
    }

    private var durationText: String {
        let total = Int(asset.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Loading

    private func load() async {
        image = nil
        player = nil
        if asset.mediaType == .video {
            await loadVideo()
        } else {
            loadImage()
        }
    }

    private func loadImage() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic   // quick low-res, then sharp
        options.isNetworkAccessAllowed = true   // fetch from iCloud if needed
        options.resizeMode = .fast
        let target = CGSize(width: 2400, height: 2400)
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
        newPlayer.isMuted = true
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
        view.controlsStyle = .none
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
