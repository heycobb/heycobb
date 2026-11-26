#if os(iOS)
import PDFKit
import SwiftUI
import UIKit
import VisionKit

/// The system document scanner. Scanned pages become one PDF in the upload
/// staging folder (removed after upload); nothing is kept on the device.
struct DocumentScanner: UIViewControllerRepresentable {
    /// The PDF, or nil if the scan was cancelled or failed.
    let onFinish: (URL?) -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    /// "Scan 2026-11-26 14.32".
    static var defaultName: String {
        "Scan " + Date.now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)", timeZone: .current, calendar: .current))
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: (URL?) -> Void
        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish(Self.makePDF(scan))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish(nil)
        }

        private static func makePDF(_ scan: VNDocumentCameraScan) -> URL? {
            let document = PDFDocument()
            for index in 0..<scan.pageCount {
                if let page = PDFPage(image: scan.imageOfPage(at: index)) {
                    document.insert(page, at: document.pageCount)
                }
            }
            guard document.pageCount > 0 else { return nil }
            let folder = UploadQueue.stagingDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "Scan.pdf")
            return document.write(to: url) ? url : nil
        }
    }
}
#endif
