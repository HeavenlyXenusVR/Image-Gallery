import SwiftUI

/// Shared between MediaDetailView's inline player and FullScreenMediaView --
/// previously only the inline view had a quality picker at all, so entering
/// fullscreen (the expand button) silently lost the ability to change
/// quality entirely, which is very likely what "can't select a quality...
/// with the custom video player" was actually reporting for the fullscreen
/// case specifically.
struct VideoQualityMenu: View {
    let options: [(String, String)]
    let current: String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button {
                    onSelect(value)
                } label: {
                    if current == value {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text(options.first { $0.0 == current }?.1 ?? "Original")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
        }
        .padding(8)
        .accessibilityLabel("Video quality")
    }
}
