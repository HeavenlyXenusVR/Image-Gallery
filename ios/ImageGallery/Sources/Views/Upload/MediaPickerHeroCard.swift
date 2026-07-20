import PhotosUI
import SwiftUI
import UIKit

/// Large picker card replacing the old plain `PhotosPicker` row + tiny
/// inline preview — the whole card is a single `PhotosPicker` tap target, so
/// the "Change photo" badge is decorative only (a nested `Button` inside an
/// already-interactive `PhotosPicker` label would create an ambiguous tap
/// target).
struct MediaPickerHeroCard: View {
    @Binding var pickerItem: PhotosPickerItem?
    let pickedData: Data?
    let pickedFileURL: URL?
    let isVideo: Bool
    let isUploading: Bool

    private var hasPickedFile: Bool { pickedData != nil || pickedFileURL != nil }

    var body: some View {
        PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos])) {
            ZStack(alignment: .bottomTrailing) {
                content
                if hasPickedFile {
                    Label("Change photo", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isUploading)
    }

    @ViewBuilder
    private var content: some View {
        if let data = pickedData, !isVideo, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 240)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if pickedFileURL != nil, isVideo {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 240)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "video.fill").font(.system(size: 34))
                        Text("Video selected").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 240)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "plus.square.on.square").font(.system(size: 34))
                        Text("Choose photo or video").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
        }
    }
}
