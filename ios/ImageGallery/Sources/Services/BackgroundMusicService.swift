import AVFoundation
import Foundation

/// Admin-managed shuffled ambient soundtrack -- mirrors
/// frontend/src/components/BackgroundMusicPlayer.jsx exactly (same
/// shuffle/reshuffle/duck behavior), just built on AVPlayer instead of
/// `<audio>`. Ducks toward a low volume (not a full mute) whenever a video
/// with sound is playing anywhere in the app, via VideoPlayerController
/// posting `.nyxframeVideoPlaybackChanged` on every rate change -- see that
/// file's rateObservation. Started once from RootView.task after sign-in,
/// same lifecycle point session.bootstrap() already runs from.
@MainActor
final class BackgroundMusicService: ObservableObject {
    static let shared = BackgroundMusicService()

    private static let mutedDefaultsKey = "nyxframe_bg_music_muted"
    private static let normalVolume: Float = 0.35
    private static let duckVolume: Float = 0.06
    private static let fadeSteps = 12
    private static let fadeIntervalSeconds = 0.4 / Double(fadeSteps)

    @Published private(set) var isMuted: Bool
    @Published private(set) var hasTracks = false

    private var player: AVPlayer?
    private var queue: [BackgroundMusicTrack] = []
    private var allTracks: [BackgroundMusicTrack] = []
    private var endObservation: NSObjectProtocol?
    private var fadeTimer: Timer?
    private var isDucked = false
    private var started = false

    private init() {
        isMuted = UserDefaults.standard.bool(forKey: Self.mutedDefaultsKey)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleVideoPlaybackChanged(_:)),
            name: .nyxframeVideoPlaybackChanged, object: nil
        )
    }

    /// Idempotent -- safe to call every time RootView's .task fires (app
    /// foreground, not just cold launch).
    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task {
            guard let tracks = try? await GalleryAPIClient.shared.backgroundMusicTracks(), !tracks.isEmpty else { return }
            allTracks = tracks
            hasTracks = true
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            guard !isMuted else { return }
            playNext()
        }
    }

    func toggleMuted() {
        isMuted.toggle()
        UserDefaults.standard.set(isMuted, forKey: Self.mutedDefaultsKey)
        if isMuted {
            player?.pause()
        } else if hasTracks {
            if player == nil { playNext() } else { player?.play() }
        }
    }

    private func playNext() {
        if queue.isEmpty { queue = allTracks.shuffled() }
        guard let next = queue.popLast(), let url = URL(string: next.url) else { return }
        let item = AVPlayerItem(url: url)
        if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
        endObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.playNext() }
        }
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = isDucked ? Self.duckVolume : Self.normalVolume
        player = newPlayer
        newPlayer.play()
    }

    @objc private func handleVideoPlaybackChanged(_ notification: Notification) {
        let playing = (notification.userInfo?["playing"] as? Bool) ?? false
        isDucked = playing
        guard !isMuted else { return }
        fade(to: playing ? Self.duckVolume : Self.normalVolume)
    }

    private func fade(to target: Float) {
        guard let player else { return }
        fadeTimer?.invalidate()
        let start = player.volume
        let delta = (target - start) / Float(Self.fadeSteps)
        var step = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: Self.fadeIntervalSeconds, repeats: true) { [weak self] timer in
            Task { @MainActor in
                step += 1
                player.volume = max(0, min(1, start + delta * Float(step)))
                if step >= Self.fadeSteps { timer.invalidate(); self?.fadeTimer = nil }
            }
        }
    }
}

extension Notification.Name {
    static let nyxframeVideoPlaybackChanged = Notification.Name("nyxframeVideoPlaybackChanged")
}
