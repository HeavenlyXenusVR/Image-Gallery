import SwiftUI

/// Three tappable icon-cards replacing the plain segmented `Picker` — same
/// visibility values ("public"/"unlisted"/"private") `UploadViewModel`
/// already sends, just a more legible presentation than three bare labels.
struct VisibilityCardPicker: View {
    @Binding var visibility: String

    private let options: [(value: String, label: String, icon: String)] = [
        ("public", "Public", "globe"),
        ("unlisted", "Unlisted", "eye.slash"),
        ("private", "Private", "lock.fill"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.value) { option in
                let isSelected = visibility == option.value
                Button {
                    visibility = option.value
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: option.icon).font(.system(size: 18))
                        Text(option.label).font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
