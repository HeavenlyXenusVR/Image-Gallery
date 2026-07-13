import SwiftUI

struct AuthContainerView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var showingRegister = false

    var body: some View {
        NavigationStack {
            Group {
                if showingRegister {
                    RegisterView(showingRegister: $showingRegister)
                } else {
                    LoginView(showingRegister: $showingRegister)
                }
            }
            .navigationTitle("Image Gallery")
            .safeAreaInset(edge: .top) {
                // Explains *why* the app dropped back to login — most
                // commonly an expired session, but also the only place a
                // suspended account's ban reason/expiry actually surfaces.
                if let lastError = session.lastError {
                    HStack {
                        Text(lastError).font(.footnote)
                        Spacer()
                        Button {
                            session.lastError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                    .padding(10)
                    .background(.red.opacity(0.15))
                }
            }
        }
    }
}
