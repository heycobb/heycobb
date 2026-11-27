import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
typealias PlatformViewController = UIViewController
#else
import AppKit
typealias PlatformViewController = NSViewController
#endif

/// Hosts the "Save to Arkenal" sheet in the system share sheet.
final class ShareViewController: PlatformViewController {
    #if os(macOS)
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))
    }
    #endif

    #if os(iOS)
    override func viewDidLoad() {
        super.viewDidLoad()
        embed()
    }
    #else
    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 460, height: 520)
        embed()
    }
    #endif

    private func embed() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let root = SaveView(providers: providers) { [weak self] cancelled in
            if cancelled {
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            } else {
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
        #if os(iOS)
        let host = UIHostingController(rootView: root)
        #else
        let host = NSHostingController(rootView: root)
        #endif
        addChild(host)
        host.view.frame = view.bounds
        #if os(iOS)
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        #else
        host.view.autoresizingMask = [.width, .height]
        view.addSubview(host.view)
        #endif
    }
}
