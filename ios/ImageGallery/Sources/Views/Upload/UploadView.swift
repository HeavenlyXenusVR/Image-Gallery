import PhotosUI
import SwiftUI
import UIKit

struct UploadView: View {
    @StateObject private var viewModel = UploadViewModel()
    @State private var showingSuccess = false

    // The backend (app/config.py's max_tags_per_upload/max_tag_length,
    // defaults 12/32) silently truncates instead of rejecting an
    // over-the-limit submission — surface a heads-up client-side instead of
    // letting tags quietly disappear with no explanation.
    private var tagsWarning: String? {
        let parsed = viewModel.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parsed.count > 12 {
            return "Only the first 12 tags will be kept."
        }
        if parsed.contains(where: { $0.count > 32 }) {
            return "Tags longer than 32 characters will be truncated."
        }
        return nil
    }

    private var hasPickedFile: Bool {
        viewModel.pickedData != nil || viewModel.pickedFileURL != nil
    }

    private var canSubmit: Bool {
        hasPickedFile && !viewModel.title.isEmpty && !viewModel.isUploading
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MediaPickerHeroCard(
                    pickerItem: $viewModel.pickerItem,
                    pickedData: viewModel.pickedData,
                    pickedFileURL: viewModel.pickedFileURL,
                    isVideo: viewModel.isVideo,
                    isUploading: viewModel.isUploading
                )
                .onChange(of: viewModel.pickerItem) { _ in
                    Task { await viewModel.handlePickerSelection() }
                }

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if hasPickedFile {
                    UploadCardSection("Details", "text.alignleft") {
                        TextField("Title", text: $viewModel.title)
                            .onChange(of: viewModel.title) { newValue in
                                if newValue.count > 160 { viewModel.title = String(newValue.prefix(160)) }
                            }
                        Divider()
                        TextField("Description", text: $viewModel.description, axis: .vertical)
                            .lineLimit(3...6)
                            .onChange(of: viewModel.description) { newValue in
                                if newValue.count > 2000 { viewModel.description = String(newValue.prefix(2000)) }
                            }
                    }

                    UploadCardSection("Category", "square.grid.2x2") {
                        UploadCategoryChipsRow(categories: viewModel.categories, selectedName: $viewModel.categoryName)
                        TextField("Category", text: $viewModel.categoryName)
                            .onChange(of: viewModel.categoryName) { newValue in
                                if newValue.count > 80 { viewModel.categoryName = String(newValue.prefix(80)) }
                            }
                    }

                    UploadCardSection("Tags", "tag") {
                        TagChipsField(tags: $viewModel.tags)
                        if let tagsWarning {
                            Text(tagsWarning).font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    UploadCardSection("Visibility", "eye") {
                        VisibilityCardPicker(visibility: $viewModel.visibility)
                    }

                    UploadCardSection("Settings", "slider.horizontal.3") {
                        Toggle("18+", isOn: $viewModel.isAdult)
                        Toggle("Comments enabled", isOn: $viewModel.commentsEnabled)
                        Toggle("Downloads enabled", isOn: $viewModel.downloadsEnabled)
                        Toggle("AI metadata", isOn: $viewModel.autoAI)
                    }

                    UploadCardSection("Schedule", "clock") {
                        Toggle("Schedule for later", isOn: $viewModel.scheduleEnabled)
                        if viewModel.scheduleEnabled {
                            DatePicker("Publish at", selection: $viewModel.publishAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        }
                    }

                    if !viewModel.possibleDuplicates.isEmpty {
                        UploadCardSection("Similar to posts you already have", "sparkle.magnifyingglass") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(viewModel.possibleDuplicates) { match in
                                        duplicateThumbnail(match)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .animation(.easeOut(duration: 0.25), value: hasPickedFile)
        }
        .disabled(viewModel.isUploading)
        .safeAreaInset(edge: .bottom) {
            publishBar
        }
        .navigationTitle("Upload")
        .task { await viewModel.loadCategories() }
        .alert("Upload complete", isPresented: $showingSuccess) {
            Button("OK") { viewModel.reset() }
        } message: {
            if !viewModel.possibleDuplicates.isEmpty {
                Text("Heads up — this looked similar to \(viewModel.possibleDuplicates.count) post\(viewModel.possibleDuplicates.count == 1 ? "" : "s") already in your library.")
            }
        }
    }

    private var publishBar: some View {
        Button {
            Task {
                if await viewModel.submit() {
                    showingSuccess = true
                }
            }
        } label: {
            Group {
                if viewModel.isUploading {
                    ProgressView().tint(.white)
                } else {
                    Text("Publish").font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canSubmit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.3)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func duplicateThumbnail(_ match: DuplicateMatch) -> some View {
        VStack(spacing: 2) {
            if let urlString = match.thumbUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(.secondary.opacity(0.15))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(match.title?.nilIfEmpty ?? "Untitled")
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 56)
        }
    }
}
