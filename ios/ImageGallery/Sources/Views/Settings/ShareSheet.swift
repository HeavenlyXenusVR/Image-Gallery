import SwiftUI
import UIKit

/// Thin `UIActivityViewController` wrapper — SwiftUI's `ShareLink` can't share
/// a freshly-written temporary file with a custom presentation trigger as
/// cleanly as this for the "download my data" export flow.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
