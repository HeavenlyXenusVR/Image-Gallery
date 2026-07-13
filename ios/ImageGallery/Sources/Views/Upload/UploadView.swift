import PhotosUI
import SwiftUI
import UIKit

struct UploadView: View {
    @StateObject private var viewModel = UploadViewModel()
    @State private var showingSuccess = false

    var body: some View {
        Form {
            Section {
                PhotosPicker(selection: $viewModel.pickerItem, matching: .any(of: [.images, .videos])) {
                    if viewModel.pickedData != nil {
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
                } else if viewModel.pickedData != nil, viewModel.isVideo {
                    Label("Video selected", systemImage: "video.fill")
                }
            }

            Section("Details") {
                TextField("Title", text: $viewModel.title)
                TextField("Description", text: $viewModel.description, axis: .vertical)
                    .lineLimit(3...6)
                TextField("Category", text: $viewModel.categoryName)
                TextField("Tags (comma separated)", text: $viewModel.tags)
            }

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

            Section("Schedule") {
                Toggle("Schedule for later", isOn: $viewModel.scheduleEnabled)
                if viewModel.scheduleEnabled {
                    DatePicker("Publish at", selection: $viewModel.publishAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
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
                .disabled(viewModel.pickedData == nil || viewModel.title.isEmpty || viewModel.isUploading)
            }
        }
        .navigationTitle("Upload")
        .task { await viewModel.loadCategories() }
        .alert("Upload complete", isPresented: $showingSuccess) {
            Button("OK") { viewModel.reset() }
        }
    }
}
