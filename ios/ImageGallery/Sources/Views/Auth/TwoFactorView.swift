import SwiftUI

struct TwoFactorView: View {
    @EnvironmentObject private var session: SessionStore
    let pendingToken: String
    var onCancel: () -> Void

    @State private var code = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Enter the 6-digit code from your authenticator app.")
                TextField("Code", text: $code)
                    .keyboardType(.numberPad)
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
                .disabled(code.isEmpty || isLoading)

                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .navigationTitle("Two-Factor Authentication")
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
