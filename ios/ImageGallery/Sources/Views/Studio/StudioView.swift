import SwiftUI

struct StudioView: View {
    @StateObject private var viewModel = StudioViewModel()
    @State private var showingBulkDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isSelecting && !viewModel.selectedIds.isEmpty {
                bulkActionBar
            }

            List {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(viewModel.items) { item in
                    StudioItemRow(item: item, viewModel: viewModel)
                }
            }
        }
        .navigationTitle("Studio")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(viewModel.isSelecting ? "Done" : "Select") {
                    viewModel.toggleSelectionMode()
                }
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView()
            } else if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableCompat(title: "No uploads yet", systemImage: "photo.stack")
            }
        }
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
        .confirmationDialog(
            "Delete \(viewModel.selectedIds.count) item\(viewModel.selectedIds.count == 1 ? "" : "s")?",
            isPresented: $showingBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.bulkDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can restore deleted items later from this screen.")
        }
    }

    private var bulkActionBar: some View {
        HStack {
            Text("\(viewModel.selectedIds.count) selected").font(.footnote)
            Spacer()
            Menu {
                Button("Public") { Task { await viewModel.bulkSetVisibility("public") } }
                Button("Unlisted") { Task { await viewModel.bulkSetVisibility("unlisted") } }
                Button("Private") { Task { await viewModel.bulkSetVisibility("private") } }
            } label: {
                Label("Visibility", systemImage: "eye")
            }
            .accessibilityLabel("Set visibility for selected items")
            Button(role: .destructive) {
                Haptics.warning()
                showingBulkDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityLabel("Delete selected items")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.1))
        .disabled(viewModel.isBulkWorking)
        .overlay {
            if viewModel.isBulkWorking { ProgressView() }
        }
    }
}

struct StudioItemRow: View {
    let item: MediaItem
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        Group {
            if viewModel.isSelecting {
                Button {
                    viewModel.toggleSelected(item)
                } label: {
                    HStack {
                        Image(systemName: viewModel.selectedIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(viewModel.selectedIds.contains(item.id) ? Color.accentColor : .secondary)
                        rowContent
                    }
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                    rowContent
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
        }
    }

    private var rowContent: some View {
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
