import QuickLook
import SwiftUI

extension View {
    /// Quick Look preview of a local file, without editing tools.
    ///
    /// On iOS, SwiftUI's `quickLookPreview` shows a Markup button, but edits
    /// would only change Arkenal's temporary copy, never the file on the NAS.
    /// So iOS uses a `QLPreviewController` with editing turned off. The Mac's
    /// Quick Look panel has no such button, so it uses the standard modifier.
    func filePreview(_ url: Binding<URL?>) -> some View {
        #if os(iOS)
        background(QuickLookPresenter(url: url))
        #else
        quickLookPreview(url)
        #endif
    }
}

#if os(iOS)
/// Presents `QLPreviewController` from an invisible host view controller
/// whenever `url` is set, and clears `url` when the preview is dismissed.
private struct QuickLookPresenter: UIViewControllerRepresentable {
    @Binding var url: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.isHidden = true
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onDismiss = { url = nil }
        guard let url, host.presentedViewController == nil, host.view.window != nil else { return }
        coordinator.url = url
        let preview = QLPreviewController()
        preview.dataSource = coordinator
        preview.delegate = coordinator
        // A sheet can be swiped down to close; Quick Look's default full
        // screen presentation needs a tap, then the close button.
        preview.modalPresentationStyle = .pageSheet
        if let sheet = preview.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
        }
        host.present(preview, animated: true)
        preview.presentationController?.delegate = coordinator
    }

    // Quick Look calls its data source and delegate on the main thread.
    final class Coordinator: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate, UIAdaptivePresentationControllerDelegate {
        var url: URL?
        var onDismiss: () -> Void = {}

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            url == nil ? 0 : 1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            (url ?? URL(fileURLWithPath: "/")) as NSURL
        }

        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode {
            .disabled
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            finish()
        }

        /// Swiped down.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish()
        }

        private func finish() {
            guard url != nil else { return }
            url = nil
            onDismiss()
        }
    }
}
#endif
