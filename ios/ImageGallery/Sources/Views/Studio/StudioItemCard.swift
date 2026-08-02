import SwiftUI

/// Grid card replacing the old skinny list row — same gradient-scrim/title
/// idiom as the redesigned `MediaCard`, plus owner-only visibility/status
/// badges `MediaCard` has no reason to carry.
///
/// The kebab menu and selection checkmark are siblings of the
/// NavigationLink/Button in the outer `ZStack`, not nested inside its
/// label — nesting an interactive control inside a NavigationLink's label
/// lets the NavigationLink's tap area swallow the inner control's taps, so
/// the corner controls are layered on top instead.
struct StudioItemCard: View {
    let item: MediaItem
    @ObservedObject var viewModel: StudioViewModel

    private var isSelected: Bool { viewModel.selectedIds.contains(item.id) }
    private var isScheduled: Bool {
        guard let publishAt = DateFormatting.parse(item.publishAt) else { return false }
        return publishAt > Date()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if viewModel.isSelecting {
                Button {
                    viewModel.toggleSelected(item)
                } label: {
                    cardFace
                }
                .buttonStyle(.plain)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .white)
                    .padding(4)
                    .background(.black.opacity(0.35), in: Circle())
                    .padding(8)
                    .allowsHitTesting(false)
            } else {
                NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                    cardFace
                }
                .buttonStyle(.plain)
                .contextMenu { menuActions }

                Menu {
                    menuActions
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .padding(8)
            }
        }
    }

    private var cardFace: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(thumbnail)
            .overlay(alignment: .bottom) { scrim }
            .overlay(alignment: .bottom) { titleFooter }
            .overlay(alignment: .topLeading) { leadingBadges }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.md, style: .continuous))
            .cardShadow()
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let urlString = item.thumbUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle().fill(.secondary.opacity(0.15))
                }
            }
        } else {
            Rectangle().fill(.secondary.opacity(0.15)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private var scrim: some View {
        LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0)], startPoint: .bottom, endPoint: .top)
            .frame(height: 56)
            .allowsHitTesting(false)
    }

    private var titleFooter: some View {
        Text(item.title?.nilIfEmpty ?? "Untitled")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var leadingBadges: some View {
        VStack(alignment: .leading, spacing: 4) {
            statusPill(visibilityLabel, color: visibilityColor)
            if item.deletedAt != nil {
                statusPill("Deleted", color: .red)
            } else if isScheduled {
                statusPill("Scheduled", color: .orange)
            }
        }
        .padding(8)
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private var menuActions: some View {
        Button(item.pinnedAt != nil ? "Unpin" : "Pin") { Task { await viewModel.togglePinned(item) } }
        Menu("Set visibility") {
            Button("Public") { Task { await viewModel.updateVisibility(item, visibility: "public") } }
            Button("Unlisted") { Task { await viewModel.updateVisibility(item, visibility: "unlisted") } }
            Button("Private") { Task { await viewModel.updateVisibility(item, visibility: "private") } }
        }
        if item.deletedAt != nil {
            Button("Restore") { Task { await viewModel.restore(item) } }
        } else {
            Button("Delete", role: .destructive) { Task { await viewModel.delete(item) } }
        }
    }

    private var visibilityLabel: String {
        switch item.visibility ?? "public" {
        case "unlisted": return "Unlisted"
        case "private": return "Private"
        default: return "Public"
        }
    }

    private var visibilityColor: Color {
        switch item.visibility ?? "public" {
        case "unlisted": return .orange
        case "private": return .gray
        default: return .green
        }
    }
}
