#if os(macOS)
import AppKit
import ArkenalKit
import SwiftUI

/// What a Mac window (or tab) opens with. The main window has a fixed id,
/// so the menu bar's "Open Arkenal" brings it back instead of opening
/// another; every New Tab or New Window gets a new id.
struct WindowTarget: Codable, Hashable {
    var id: UUID
    /// A folder to open in this window, or nil for the usual start.
    var folder: RemoteItem?

    static let main = WindowTarget(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, folder: nil)

    static func new(_ folder: RemoteItem? = nil) -> WindowTarget { WindowTarget(id: UUID(), folder: folder) }
}

/// Opens Arkenal windows as tabs of the front window (File › New Tab,
/// Open in New Tab) or on their own (File › New Window).
@MainActor
enum WindowTabs {
    /// The window the next new window joins as a tab.
    private static weak var pendingParent: NSWindow?

    static func openTab(_ folder: RemoteItem? = nil, with openWindow: OpenWindowAction) {
        pendingParent = NSApp.keyWindow ?? NSApp.mainWindow
        openWindow(id: ArkenalApp.mainWindowID, value: WindowTarget.new(folder))
    }

    static func openWindow(_ folder: RemoteItem? = nil, with openWindow: OpenWindowAction) {
        pendingParent = nil
        openWindow(id: ArkenalApp.mainWindowID, value: WindowTarget.new(folder))
    }

    /// Called when a new window appears: joins the front window as a tab
    /// if that's how it was opened.
    static func attach(_ window: NSWindow) {
        window.tabbingMode = .automatic
        guard let parent = pendingParent, parent !== window, parent.isVisible else { return }
        pendingParent = nil
        parent.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Finds the NSWindow a view is in, once it's on screen.
struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: @MainActor (NSWindow) -> Void
        init(onWindow: @escaping @MainActor (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

/// File › New Window (⌘N) and New Tab (⌘T).
struct WindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { WindowTabs.openWindow(with: openWindow) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") { WindowTabs.openTab(with: openWindow) }
                .keyboardShortcut("t", modifiers: .command)
        }
    }
}
#endif
