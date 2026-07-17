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

    var body: some View {
        Form {
            Section {
                PhotosPicker(selection: $viewModel.pickerItem, matching: .any(of: [.images, .videos])) {
                    if viewModel.pickedData != nil || viewModel.pickedFileURL != nil {
                        Label("Change file", systemImage: "photo.on.rectangle")
                    } else {
                        Label("Choose photo or video", systemImage: "plus.square.on.square")
                    }
                }
                .onChange(of: viewModel.pickerItem) { _ in
                    Task { await viewModel.handlePickerSelection() }
                }

                if let data = viewModel.pickedData, !viewModel.isVideo, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                } else if viewModel.pickedFileURL != nil, viewModel.isVideo {
                    Label("Video selected", systemImage: "video.fill")
                }
            }
            .disabled(viewModel.isUploading)

            Section("Details") {
                TextField("Title", text: $viewModel.title)
                    .onChange(of: viewModel.title) { newValue in
                        if newValue.count > 160 { viewModel.title = String(newValue.prefix(160)) }
                    }
                TextField("Description", text: $viewModel.description, axis: .vertical)
                    .lineLimit(3...6)
                    .onChange(of: viewModel.description) { newValue in
                        if newValue.count > 2000 { viewModel.description = String(newValue.prefix(2000)) }
                    }
                TextField("Category", text: $viewModel.categoryName)
                    .onChange(of: viewModel.categoryName) { newValue in
                        if newValue.count > 80 { viewModel.categoryName = String(newValue.prefix(80)) }
                    }
                TextField("Tags (comma separated)", text: $viewModel.tags)
                if let tagsWarning {
                    Text(tagsWarning).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(viewModel.isUploading)

            Section("Visibility") {
                Picker("Visibility", selection: $viewModel.visibility) {
                    Text("Public").tag("public")
                    Text("Unlisted").tag("unlisted")
                    Text("Private").tag("private")
                }
                Toggle("18+", isOn: $viewModel.isAdult)
                Toggle("Comments enabled", isOn: $viewModel.commentsEnabled)
                Toggle("Downloads enabled", isOn: $viewModel.downloadsEnabled)
                Toggle("AI metadata", isOn: $viewModel.autoAI)
            }
            .disabled(viewModel.isUploading)

            Section("Schedule") {
                Toggle("Schedule for later", isOn: $viewModel.scheduleEnabled)
                if viewModel.scheduleEnabled {
                    DatePicker("Publish at", selection: $viewModel.publishAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
            }
            .disabled(viewModel.isUploading)

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            if !viewModel.possibleDuplicates.isEmpty {
                Section("Similar to posts you already have") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.possibleDuplicates) { match in
                                duplicateThumbnail(match)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    Task {
                        if await viewModel.submit() {
                            showingSuccess = true
                        }
                    }
                } label: {
                    if viewModel.isUploading {
                        ProgressView()
                    } else {
                        Text("Upload").frame(maxWidth: .infinity)
                    }
                }
                .disabled((viewModel.pickedData == nil && viewModel.pickedFileURL == nil) || viewModel.title.isEmpty || viewModel.isUploading)
            }
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
