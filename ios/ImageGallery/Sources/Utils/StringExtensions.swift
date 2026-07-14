import Foundation

extension String {
    /// `nil` if empty, otherwise `self` — for `title ?? "Untitled"`-style
    /// fallbacks without a force-unwrap coupled to a separate emptiness check.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
