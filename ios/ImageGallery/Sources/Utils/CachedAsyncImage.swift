import SwiftUI

/// Shared decoded-image memory cache backing `CachedAsyncImage` below.
/// `NSCache` (not a plain `Dictionary`) auto-evicts under memory pressure
/// the same way UIKit's own image caches do, with no manual eviction logic
/// needed. `countLimit` is a rough backstop, not a tuned budget -- NSCache
/// already responds to system memory-pressure notifications on its own.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

/// Drop-in `AsyncImage` replacement with a real cache -- same
/// `url:content:` phase-based signature, so every existing call site
/// (`AsyncImage(url:) { phase in ... }`) only needs the type name changed,
/// nothing else.
///
/// Plain `AsyncImage` has no cache of its own: every layer SwiftUI creates
/// (a feed cell scrolling back on screen, a view rebuilding from unrelated
/// state changes, revisiting the same avatar/thumbnail somewhere else in
/// the app) re-fetches AND re-decodes the same bytes from scratch. That
/// repeated decode work is the actual cause of "scrolling the feed/detail
/// view feels laggy" reported live 2026-08-31 -- not a video/GPU problem,
/// a missing-cache problem. `ImageCache` above keeps already-decoded
/// `UIImage`s keyed by URL, so a repeat appearance is a synchronous cache
/// hit instead of a network round trip + decode.
///
/// No request de-duplication for two views loading the same brand-new URL
/// at the exact same moment (each would still fetch independently) --
/// scrolling re-visits an already-cached image far more often than two
/// cells race to cold-load the identical URL simultaneously, so the memory
/// cache alone addresses the reported symptom; coalescing concurrent
/// in-flight loads would be a real but separate refinement.
@MainActor
struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    private let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        if let cached = ImageCache.shared.image(for: url) {
            phase = .success(Image(uiImage: cached))
            return
        }
        phase = .empty
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            guard let uiImage = UIImage(data: data) else {
                phase = .failure(URLError(.cannotDecodeContentData))
                return
            }
            ImageCache.shared.store(uiImage, for: url)
            phase = .success(Image(uiImage: uiImage))
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
        }
    }
}
