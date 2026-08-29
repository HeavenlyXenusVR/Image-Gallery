import SwiftUI

struct RegisterView: View {
    @EnvironmentObject private var session: SessionStore
    @Binding var showingRegister: Bool

    @State private var username = ""
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Mirrors the backend's actual rules (lua/src/routes.lua's M.register:
    // 3-40 chars, [%w_.%-] only, and an 8-char password minimum) so an
    // invalid submission fails instantly instead of after a round trip.
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isUsernameValid: Bool {
        let count = trimmedUsername.count
        guard count >= 3 && count <= 40 else { return false }
        return trimmedUsername.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }
    private var isPasswordValid: Bool { password.count >= 8 }

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !trimmedUsername.isEmpty && !isUsernameValid {
                    Text("3-40 characters: letters, numbers, \".\", \"_\", \"-\" only.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                TextField("Display name (optional)", text: $displayName)
                TextField("Email (optional)", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                SecureField("Password", text: $password)
                if !password.isEmpty && !isPasswordValid {
                    Text("At least 8 characters.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await register() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Create Account").frame(maxWidth: .infinity)
                    }
                }
                .disabled(!isUsernameValid || !isPasswordValid || isLoading)

                Button("Already have an account? Log in") {
                    showingRegister = false
                }
            }
        }
    }

    private func register() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await session.register(
                username: trimmedUsername,
                password: password,
                email: email.isEmpty ? nil : email,
                displayName: displayName.isEmpty ? nil : displayName
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
