import Foundation

extension Error {
    /// True for a cancelled `URLSession` task or a cancelled `Task` --
    /// neither is a real failure worth showing the user. Every view
    /// re-appearing (tab switch, pull-to-refresh interrupting an in-flight
    /// load, navigating away mid-request) cancels whatever `Task` was
    /// running, and without this check every `catch { errorMessage =
    /// error.localizedDescription }` site in the app was surfacing the
    /// literal string "cancelled" as if it were a server error — confirmed
    /// live on Discover, Studio, and elsewhere.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        let nsError = self as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
