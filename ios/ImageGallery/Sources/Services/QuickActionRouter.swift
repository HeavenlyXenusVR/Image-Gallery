import Combine
import Foundation
import UIKit

/// Bridges UIKit home-screen quick actions (handled by `AppDelegate`, which
/// has no direct line to SwiftUI's view state) into the tab selection
/// `RootTabView` owns. `AppDelegate` posts into `QuickActionRouter.shared`;
/// `RootTabView` observes it via the environment.
@MainActor
final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()

    /// Tab indices matching `RootTabView`'s `.tag` values.
    enum Destination: Int {
        case discover = 0
        case messages = 1
        case upload = 3
    }

    @Published var pendingDestination: Destination?

    func handle(shortcutType: String) {
        switch shortcutType {
        case "com.imagegallery.ios.upload": pendingDestination = .upload
        case "com.imagegallery.ios.messages": pendingDestination = .messages
        default: break
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            Task { @MainActor in QuickActionRouter.shared.handle(shortcutType: shortcutItem.type) }
        }
        return true
    }

    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in QuickActionRouter.shared.handle(shortcutType: shortcutItem.type) }
        completionHandler(true)
    }
}
