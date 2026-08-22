import SwiftUI

struct BiometricLockView: View {
    @EnvironmentObject private var biometricLock: BiometricLockService

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 48))
            Text("Nyxframe Locked").font(.title3).bold()
            Button {
                Task { await biometricLock.attemptUnlock() }
            } label: {
                Label("Unlock with \(biometricLock.biometryLabel)", systemImage: "faceid")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
