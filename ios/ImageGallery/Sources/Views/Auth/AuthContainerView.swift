import SwiftUI

struct AuthContainerView: View {
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
        }
    }
}
