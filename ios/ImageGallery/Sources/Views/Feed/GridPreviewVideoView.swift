import AVFoundation
import SwiftUI

/// A muted, looping, chrome-less video layer for grid-card previews —
/// mirrors the web app's MediaCard hover/autoplay preview (`<video muted
/// autoPlay loop controls={false}>` in media.jsx). AVKit's SwiftUI
/// `VideoPlayer` always renders native transport controls with no API to
/// hide them, which is wrong for a decorative background-style preview
/// that's meant to be tapped-through to the real detail view, not
/// interacted with directly — so this wraps `AVPlayerLayer` (a plain
/// `CALayer`, no chrome at all) instead of using AVKit.
struct GridPreviewVideoView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Owns the muted/looping `AVPlayer` for exactly one grid card's preview.
/// Looping needs an `AVPlayerLooper` (a plain `player.actionAtItemEnd = .none`
/// + NotificationCenter observer works too, but the looper is the
/// documented, glitch-free way to do it) — that requires an
/// `AVQueuePlayer`, so this owns one of those instead of a plain `AVPlayer`.
@MainActor
final class GridPreviewController: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    func start(url: URL, muted: Bool) {
        guard currentURL != url || player == nil else {
            player?.isMuted = muted
            return
        }
        stop()
        currentURL = url
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = muted
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        queuePlayer.play()
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
        currentURL = nil
    }
}
