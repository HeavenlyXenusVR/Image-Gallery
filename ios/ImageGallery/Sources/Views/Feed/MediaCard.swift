import SwiftUI

struct MediaCard: View {
    let item: MediaItem

    @EnvironmentObject private var session: SessionStore
    @StateObject private var previewController = GridPreviewController()
    @State private var isOnScreen = false

    private var settings: UserSettings? { session.currentUser?.userSettings }

    // Mirrors media.jsx's `liveVideoPreview` gate exactly: video items only,
    // never a locked (age-gated, not-yet-verified) post, only when the
    // viewer has actually turned previews on, and only once this card is
    // actually on screen (LazyVGrid already defers instantiating off-screen
    // cells, but onAppear/onDisappear is what tells this specific card
    // instance to start/stop its own player rather than every card in the
    // grid starting one the moment the view model's `items` array loads).
    private var previewEligible: Bool {
        item.isVideo && item.locked != true && (settings?.autoplayPreviews ?? false) && item.url != nil
    }

    // "Muted previews" governs autoplay itself, not just the audio track --
    // mirrors media.jsx's `autoPlay={mutedPreview}` exactly: with sound-on
    // previews requested, this falls back to the static thumbnail (tap
    // through to MediaDetailView for real, controllable playback) rather
    // than autoplaying WITH sound in a scrolling feed, which every mobile
    // browser blocks outright and would be startling even where allowed.
    private var previewMuted: Bool { settings?.mutedPreviews ?? true }
    private var shouldShowLivePreview: Bool { previewEligible && previewMuted && isOnScreen }

    private var previewURL: URL? {
        guard let urlString = item.url, var components = URLComponents(string: urlString) else { return nil }
        var queryItems = (components.queryItems ?? []).filter { $0.name != "quality" }
        queryItems.append(URLQueryItem(name: "quality", value: "low"))
        components.queryItems = queryItems
        return components.url
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(thumbnail)
            .overlay { if shouldShowLivePreview, let player = previewController.player {
                GridPreviewVideoView(player: player)
                    .modifier(VideoPreviewBlur(active: settings?.blurVideoPreviews ?? false))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } }
            .overlay(alignment: .bottom) { scrim }
            .overlay(alignment: .bottom) { footer }
            .overlay(alignment: .topTrailing) { kindBadge }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.md, style: .continuous))
            .cardShadow()
            .onAppear { isOnScreen = true }
            .onDisappear {
                isOnScreen = false
                previewController.stop()
            }
            // `.task(id:)` cancels its previous Task the moment the id
            // changes (or the view disappears) -- exactly the debounce this
            // needs: fast-scrolling past a card flips shouldShowLivePreview
            // true-then-false before the sleep ever finishes, so the
            // cancellation check below stops it from ever starting a real
            // AVPlayer for a card the viewer never actually stopped on.
            .task(id: shouldShowLivePreview) {
                guard shouldShowLivePreview, let url = previewURL else {
                    previewController.stop()
                    return
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                previewController.start(url: url, muted: previewMuted)
            }
    }

    // A dark gradient anchored to the bottom edge so the title/stat footer
    // stays legible over busy thumbnails without a solid overlay flattening
    // the whole card.
    private var scrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.65), .black.opacity(0)],
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(height: 56)
        .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(item.title?.nilIfEmpty ?? "Untitled")
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            if let likeCount = item.likeCount, likeCount > 0 {
                Label("\(likeCount)", systemImage: "heart.fill")
                    .labelStyle(.compactStat)
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var kindBadge: some View {
        if item.locked == true {
            badgeIcon("lock.fill")
        } else if item.isVideo {
            badgeIcon("play.fill")
        }
    }

    private func badgeIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.caption2)
            .padding(6)
            .background(.black.opacity(0.55), in: Circle())
            .foregroundStyle(.white)
            .padding(6)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.locked == true {
            Rectangle()
                .fill(.secondary.opacity(0.3))
                .overlay(Image(systemName: "eye.slash").foregroundStyle(.secondary))
        } else if let urlString = item.thumbUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Rectangle().fill(.secondary.opacity(0.2)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                default:
                    Rectangle().fill(.secondary.opacity(0.1))
                }
            }
        } else {
            Rectangle().fill(.secondary.opacity(0.2)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}

/// Mirrors web's `.blurred-video-thumb` CSS class (`filter: blur(3px)
/// saturate(0.86) brightness(0.84); transform: scale(1.035)`) -- the slight
/// scale-up hides the blur radius's edge falloff at the card's clipped
/// corners, same reason the web version scales too. SwiftUI's `.brightness`
/// is additive, not the multiplicative darkening CSS's brightness(0.84)
/// does, so -0.16 is a visual approximation, not a pixel-identical match.
private struct VideoPreviewBlur: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .blur(radius: 3)
                .saturation(0.86)
                .brightness(-0.16)
                .scaleEffect(1.035)
        } else {
            content
        }
    }
}

private struct CompactStatLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private extension LabelStyle where Self == CompactStatLabelStyle {
    static var compactStat: CompactStatLabelStyle { CompactStatLabelStyle() }
}
