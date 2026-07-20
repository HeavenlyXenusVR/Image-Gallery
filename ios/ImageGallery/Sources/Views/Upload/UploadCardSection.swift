import SwiftUI

/// Titled card wrapper used to group each stage of the upload form —
/// replaces the plain `Form` section headers with a self-contained visual
/// block, matching the card idiom used across the redesigned Discover tab.
struct UploadCardSection<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(_ title: String, _ systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
