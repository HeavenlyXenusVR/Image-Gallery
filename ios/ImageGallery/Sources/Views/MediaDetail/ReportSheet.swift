import SwiftUI

struct ReportSheet: View {
    @ObservedObject var viewModel: MediaDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var reason = ""
    @State private var details = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    TextField("Reason", text: $reason)
                }
                Section("Details") {
                    TextField("Details (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        isSubmitting = true
                        Task {
                            let success = await viewModel.report(reason: reason, details: details.isEmpty ? nil : details)
                            isSubmitting = false
                            if success { dismiss() }
                        }
                    }
                    .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                }
            }
        }
    }
}
