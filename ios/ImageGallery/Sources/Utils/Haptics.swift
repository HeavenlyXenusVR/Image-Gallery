import UIKit

/// Thin wrapper around UIKit's feedback generators — a native touch the web
/// app has no equivalent for. Kept to a handful of call sites (like, react,
/// follow, send, success/failure) rather than sprinkled everywhere, so it
/// stays meaningful instead of buzzy.
enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
