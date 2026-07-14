import SwiftUI

struct TotpEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var secret: String?
    @State private var code = ""
    @State private var recoveryCodes: [String]?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Form {
                if let recoveryCodes {
                    Section("Save these recovery codes") {
                        Text("Each works once if you lose access to your authenticator app. They won't be shown again.")
                            .font(.footnote)
                        ForEach(recoveryCodes, id: \.self) { code in
                            Text(code).font(.system(.body, design: .monospaced))
                        }
                    }
                    Section {
                        Button("Done") { dismiss() }
                    }
                } else if let secret {
                    Section {
                        Text("Enter this secret into your authenticator app (Google Authenticator, Authy, etc.), then confirm with the 6-digit code it shows.")
                        Text(secret).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        TextField("Confirm code", text: $code).keyboardType(.numberPad)
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                    Section {
                        Button("Confirm and enable") { Task { await confirm() } }
                            .disabled(code.isEmpty || isLoading)
                    }
                } else {
                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                    Section {
                        Button {
                            Task { await enroll() }
                        } label: {
                            if isLoading {
                                ProgressView()
                            } else {
                                Text(errorMessage == nil ? "Start enrollment" : "Try again")
                            }
                        }
                        .disabled(isLoading)
                    }
                }
            }
            .navigationTitle("Two-Factor Setup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { if secret == nil { await enroll() } }
        }
    }

    private func enroll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await GalleryAPIClient.shared.beginTotpEnrollment()
            secret = response.secret
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirm() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await GalleryAPIClient.shared.confirmTotpEnrollment(code: code)
            recoveryCodes = response.recoveryCodes ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
