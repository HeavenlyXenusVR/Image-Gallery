import AVFoundation
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
        // Picture in Picture requires the audio session category to be
        // .playback (plus the "audio" UIBackgroundModes capability, see
        // Info.plist) -- without it, AVKit's PiP either never activates or
        // stops playback the moment the app is backgrounded, which is the
        // entire point of PiP. This was previously ONLY ever set as a side
        // effect of BackgroundMusicService.startIfNeeded() -- which only
        // runs, and only sets the category, when the admin has actually
        // uploaded at least one background-music track -- so PiP silently
        // had no reliable audio session at all on any install where that
        // feature happens to be unused. Set unconditionally, as early as
        // possible, independent of that unrelated feature.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

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
