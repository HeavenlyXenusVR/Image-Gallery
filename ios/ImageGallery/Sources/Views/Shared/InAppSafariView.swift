import SafariServices
import SwiftUI

/// Wraps `SFSafariViewController` for the "inline" half of open_original_
/// in_new_tab: web's setting name is literal (new browser tab vs. staying
/// on the same page), which doesn't map to iOS 1:1 -- there's no "tab" to
/// stay on. The natural iOS equivalent of "don't leave to a new tab" is
/// "don't leave the app at all" (an embedded browser sheet), vs. "new tab"
/// meaning launch the system Safari app externally.
struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
