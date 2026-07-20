import SwiftUI

struct StudioView: View {
    @StateObject private var viewModel = StudioViewModel()
    @State private var filter: StudioFilter = .all
    @State private var showingBulkDeleteConfirm = false
    @State private var showingBulkTagPrompt = false
    @State private var bulkTagInput = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private var filteredItems: [MediaItem] {
        switch filter {
        case .all:
            return viewModel.items.filter { $0.deletedAt == nil }
        case .deleted:
            return viewModel.items.filter { $0.deletedAt != nil }
        case .scheduled:
            return viewModel.items.filter { item in
                guard item.deletedAt == nil, let publishAt = DateFormatting.parse(item.publishAt) else { return false }
                return publishAt > Date()
            }
        case .public, .unlisted, .private:
            return viewModel.items.filter { $0.deletedAt == nil && ($0.visibility ?? "public") == filter.rawValue }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StudioStatsHeader(items: viewModel.items)
                StudioFilterChipsRow(selected: $filter)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredItems) { item in
                        StudioItemCard(item: item, viewModel: viewModel)
                    }
                }
            }
            .padding()
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
        .safeAreaInset(edge: .bottom) {
            if viewModel.isSelecting && !viewModel.selectedIds.isEmpty {
                bulkActionBar
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
        .alert("Add tag to \(viewModel.selectedIds.count) item\(viewModel.selectedIds.count == 1 ? "" : "s")", isPresented: $showingBulkTagPrompt) {
            TextField("Tag", text: $bulkTagInput)
            Button("Add") {
                Task { await viewModel.bulkAddTag(bulkTagInput) }
                bulkTagInput = ""
            }
            Button("Cancel", role: .cancel) { bulkTagInput = "" }
        }
    }

    private var bulkActionBar: some View {
        HStack {
            Text("\(viewModel.selectedIds.count) selected").font(.footnote.weight(.semibold))
            Spacer()
            Menu {
                Button("Public") { Task { await viewModel.bulkSetVisibility("public") } }
                Button("Unlisted") { Task { await viewModel.bulkSetVisibility("unlisted") } }
                Button("Private") { Task { await viewModel.bulkSetVisibility("private") } }
            } label: {
                Label("Visibility", systemImage: "eye")
            }
            .accessibilityLabel("Set visibility for selected items")
            Button {
                showingBulkTagPrompt = true
            } label: {
                Label("Add tag", systemImage: "tag")
            }
            .accessibilityLabel("Add a tag to selected items")
            Button(role: .destructive) {
                Haptics.warning()
                showingBulkDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityLabel("Delete selected items")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal)
        .padding(.bottom, 8)
        .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
        .disabled(viewModel.isBulkWorking)
        .overlay {
            if viewModel.isBulkWorking { ProgressView() }
        }
    }
}
