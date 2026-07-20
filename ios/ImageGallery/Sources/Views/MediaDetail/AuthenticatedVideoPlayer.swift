import AVFoundation
import AVKit
import Foundation
import SwiftUI

/// Wraps AVKit's `VideoPlayer` with an `AVURLAsset` built with the session's
/// Bearer token attached, so private/adult streaming endpoints
/// (`app/routers/media_streaming.py`) authenticate the same way `apiFetch`
/// does on the web.
///
/// AVPlayer does its own networking, entirely separate from
/// `GalleryAPIClient` — so unlike JSON/image requests, it never got the
/// "the tunnel had a hiccup, retry against a fresh connection" resilience
/// `GalleryAPIClient.sendWithRetry` already gives every other request. A
/// single dropped/slow connection to the tunnel just failed outright
/// ("The request timed out."). Mirror that same retry behavior here.
struct AuthenticatedVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var retryAttempt = 0

    private static let maxRetries = 2

    var body: some View {
        Group {
            if let errorMessage {
                // AVKit's own "can't play" glyph gives no indication of *why* —
                // surface the real AVPlayerItem error instead of leaving the
                // viewer to guess (network vs. auth vs. an unsupported codec
                // all look identical otherwise).
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                    Text("Couldn't play this video").font(.subheadline.weight(.semibold))
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Button("Try Again") {
                        retryAttempt = 0
                        errorMessage = nil
                        startPlayback()
                    }
                    .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else if let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else {
                Color.black.overlay(ProgressView())
            }
        }
        .onAppear {
            guard player == nil, errorMessage == nil else { return }
            startPlayback()
        }
        .onDisappear {
            statusObservation?.invalidate()
            statusObservation = nil
        }
    }

    private func startPlayback() {
        statusObservation?.invalidate()
        var headers: [String: String] = [:]
        if let token = GalleryAPIClient.shared.authToken {
            headers["Authorization"] = "Bearer \(token)"
        }
        // Using the literal key string rather than the `AVURLAssetHTTPHeaderFieldsKey`
        // symbol — it wasn't resolving in scope in CI even with AVFoundation
        // imported, and the options dictionary is untyped ([String: Any]) so the
        // literal (Apple's documented constant value) works identically.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status, options: [.new]) { observedItem, _ in
            guard observedItem.status == .failed else { return }
            let failure = observedItem.error
            DispatchQueue.main.async {
                handleFailure(failure)
            }
        }
        player = AVPlayer(playerItem: item)
    }

    private func handleFailure(_ error: Error?) {
        guard isTransientNetworkError(error), retryAttempt < Self.maxRetries else {
            errorMessage = error?.localizedDescription ?? "Unknown error."
            return
        }
        retryAttempt += 1
        player = nil
        let delay = 0.5 * Double(retryAttempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            startPlayback()
        }
    }

    // Walks the NSError's underlying-error chain looking for a plain
    // networking failure — AVFoundation sometimes wraps the real
    // NSURLErrorDomain error inside an AVFoundationErrorDomain one, so a
    // single top-level domain check isn't reliable.
    private func isTransientNetworkError(_ error: Error?) -> Bool {
        guard let error else { return false }
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.domain == NSURLErrorDomain {
                switch candidate.code {
                case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                     NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                     NSURLErrorSecureConnectionFailed:
                    return true
                default:
                    return false
                }
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
