import SwiftUI

struct StudioView: View {
    @StateObject private var viewModel = StudioViewModel()

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(viewModel.items) { item in
                StudioItemRow(item: item, viewModel: viewModel)
            }
        }
        .navigationTitle("Studio")
        .overlay {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView()
            } else if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableCompat(title: "No uploads yet", systemImage: "photo.stack")
            }
        }
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
    }
}

struct StudioItemRow: View {
    let item: MediaItem
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
            HStack {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title?.isEmpty == false ? item.title! : "Untitled").bold()
                    Text(item.visibility ?? "public").font(.caption).foregroundStyle(.secondary)
                    if let publishAt = item.publishAt {
                        Text("Scheduled for \(publishAt)").font(.caption2).foregroundStyle(.orange)
                    }
                    if item.deletedAt != nil {
                        Text("Deleted").font(.caption2).foregroundStyle(.red)
                    }
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if item.deletedAt != nil {
                Button("Restore") { Task { await viewModel.restore(item) } }.tint(.green)
            } else {
                Button("Delete", role: .destructive) { Task { await viewModel.delete(item) } }
            }
        }
        .contextMenu {
            Button(item.pinnedAt != nil ? "Unpin" : "Pin") { Task { await viewModel.togglePinned(item) } }
            Menu("Set visibility") {
                Button("Public") { Task { await viewModel.updateVisibility(item, visibility: "public") } }
                Button("Unlisted") { Task { await viewModel.updateVisibility(item, visibility: "unlisted") } }
                Button("Private") { Task { await viewModel.updateVisibility(item, visibility: "private") } }
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let urlString = item.thumbUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.2)).frame(width: 56, height: 56)
        }
    }
}
