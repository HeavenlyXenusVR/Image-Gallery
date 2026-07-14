import SwiftUI

struct TwoFactorView: View {
    @EnvironmentObject private var session: SessionStore
    let pendingToken: String
    var onCancel: () -> Void

    @State private var code = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    // Mirrors the backend's TOTP_PENDING_TTL_SECONDS (app/auth.py) — the
    // pending-login token this view is verifying against expires server-side
    // after 5 minutes, so this counts down to explain a stale attempt instead
    // of the code just mysteriously failing.
    @State private var remainingSeconds = 300

    private var countdownText: String {
        String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    var body: some View {
        Form {
            Section {
                Text("Enter the 6-digit code from your authenticator app.")
                TextField("Code", text: $code)
                    .keyboardType(.numberPad)
                Text(remainingSeconds > 0 ? "Expires in \(countdownText)" : "This sign-in attempt has expired — cancel and log in again.")
                    .font(.footnote)
                    .foregroundStyle(remainingSeconds > 0 ? .secondary : .red)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await verify() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Verify").frame(maxWidth: .infinity)
                    }
                }
                .disabled(code.isEmpty || isLoading || remainingSeconds <= 0)

                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .navigationTitle("Two-Factor Authentication")
        .task {
            while !Task.isCancelled && remainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                remainingSeconds -= 1
            }
        }
    }

    private func verify() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await session.completeTwoFactor(pendingToken: pendingToken, code: code)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
