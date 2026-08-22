import Foundation

struct TimedOutError: Error {}

/// Races `operation` against a hard deadline, throwing `TimedOutError` if it
/// loses. Needed because GalleryAPIClient's shared URLSession is configured
/// with `waitsForConnectivity = true` (deliberately, so long-running uploads
/// survive a Wi-Fi/cellular handoff instead of failing immediately) -- but
/// per Apple's documented behavior, that setting means a request made while
/// the network is genuinely unreachable at that instant waits with NO
/// timeout ever firing, not even `timeoutIntervalForRequest`, until
/// connectivity resumes. That's fine for a backgrounded upload; it's a
/// permanent stuck-on-launch loading screen for SessionStore.bootstrap(),
/// which gates the entire app UI behind `isBootstrapping`. Confirmed via
/// Apple's docs, not empirically (no device available to reproduce "airplane
/// mode toggled right at launch" against) -- this is the one plausible root
/// cause that actually explains "sometimes," not "always": it only bites
/// when the network is truly unreachable at request time, not just slow.
func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimedOutError()
        }
        guard let result = try await group.next() else { throw TimedOutError() }
        group.cancelAll()
        return result
    }
}
