import Combine
import Foundation
import LocalAuthentication

/// Optional Face ID/Touch ID gate on app launch/foreground — a native
/// security touch the web app has no equivalent for. Off by default; the
/// user opts in from Settings.
@MainActor
final class BiometricLockService: ObservableObject {
    @Published var isUnlocked = true

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "biometric_lock_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "biometric_lock_enabled") }
    }

    var biometryLabel: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Passcode"
        }
    }

    func lock() {
        guard isEnabled else { return }
        isUnlocked = false
    }

    func attemptUnlock() async {
        guard isEnabled, !isUnlocked else {
            isUnlocked = true
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics/passcode configured on the device — don't lock
            // the user out of their own app over a device capability gap.
            isUnlocked = true
            return
        }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Nyxframe")
            isUnlocked = success
        } catch {
            isUnlocked = false
        }
    }
}
