#if os(macOS)
import AppKit
import ArkenalKit
import SwiftUI

/// What a Mac window opens with. The main window has a fixed id, so the
/// menu bar's "Open Arkenal" brings it back instead of opening another;
/// File › New Window gets a new id.
struct WindowTarget: Codable, Hashable {
    var id: UUID
    /// A folder to open in this window, or nil for the usual start.
    var folder: RemoteItem?

    static let main = WindowTarget(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, folder: nil)

    static func new(_ folder: RemoteItem? = nil) -> WindowTarget { WindowTarget(id: UUID(), folder: folder) }
}

/// A window's tabs. Each tab is its own Browse screen (sidebar item and
/// folder stack); the tabs are drawn as chips in the toolbar row.
@MainActor @Observable
final class WindowTabsModel {
    let id = UUID()
    var tabs: [BrowserState]
    var currentID: BrowserState.ID

    init(initialFolder: RemoteItem?) {
        let first = BrowserState(initialFolder: initialFolder)
        tabs = [first]
        currentID = first.id
    }

    var current: BrowserState { tabs.first { $0.id == currentID } ?? tabs[0] }

    func newTab(_ folder: RemoteItem? = nil) {
        let tab = BrowserState(initialFolder: folder)
        let index = tabs.firstIndex { $0.id == currentID }.map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(tab, at: index)
        currentID = tab.id
    }

    func close(_ id: BrowserState.ID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if currentID == id { currentID = tabs[min(index, tabs.count - 1)].id }
    }

    func step(_ offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == currentID }) else { return }
        currentID = tabs[(index + offset + tabs.count) % tabs.count].id
    }
}

extension FocusedValues {
    @Entry var windowTabs: WindowTabsModel?
}

/// A Mac window: the current tab's Browse screen, with the tabs in the
/// toolbar once there are two or more.
struct TabHost: View {
    @State private var model: WindowTabsModel

    init(initialFolder: RemoteItem?) {
        _model = State(initialValue: WindowTabsModel(initialFolder: initialFolder))
    }

    var body: some View {
        BrowserView(externalState: model.current)
            // A fresh view per tab, so one tab's folder views don't carry over.
            .id(model.currentID)
            .environment(\.openInNewTab, TabOpener(window: model.id) { [model] in model.newTab($0) })
            .toolbar {
                if model.tabs.count > 1 {
                    // Centered, like Safari's tabs: the item stretches over the
                    // free space and centers the tabs in it; the folder's
                    // buttons and Search stay trailing.
                    // An empty anchor first: a leading flexible space only
                    // takes effect with an item before it.
                    ToolbarItem { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                        .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible)
                    ToolbarItem { TabChips(model: model) }
                        .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible)
                }
            }
            // The chips say where each tab is; the window title would repeat it.
            .toolbar(removing: model.tabs.count > 1 ? .title : nil)
            .navigationTitle(model.current.title)
            .focusedSceneValue(\.windowTabs, model)
    }
}

/// The tabs as chips: folder symbol and name, the current one lifted, ×
/// to close (on the current tab and on hover), drag to reorder, + to add.
private struct TabChips: View {
    @Bindable var model: WindowTabsModel

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(model.tabs) { tab in
                    TabChip(tab: tab, selected: tab.id == model.currentID,
                            select: { model.currentID = tab.id },
                            close: { model.close(tab.id) })
                }
                .reorderable()
            }
            .reorderContainer(for: BrowserState.self) { difference in
                difference.apply(to: &model.tabs)
            }
            // Its full width: the toolbar would otherwise squeeze the names.
            .fixedSize(horizontal: true, vertical: false)
            Button { model.newTab() } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Tab")
            .accessibilityLabel("New Tab")
        }
    }
}

private struct TabChip: View {
    let tab: BrowserState
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            // A real button (not a tap gesture), so VoiceOver and keyboard
            // access can switch tabs too.
            Button(action: select) {
                HStack(spacing: 5) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.leading, 12)
                .frame(height: 30)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            // The × is hidden until hover, so VoiceOver gets it as an action.
            .accessibilityAction(named: "Close Tab", close)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Shown on hover only; its space stays, so tabs don't shift.
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityHidden(true)
            .padding(.trailing, 6)
            .help("Close Tab")
            .accessibilityLabel("Close \(tab.title)")
        }
        .font(.body)
        .foregroundStyle(selected ? .primary : .secondary)
        .background {
            Capsule()
                .fill(.primary.opacity(selected ? 0.13 : hovering ? 0.06 : 0))
                .overlay { Capsule().strokeBorder(.primary.opacity(selected ? 0.12 : 0), lineWidth: 0.5) }
        }
        .onHover { hovering = $0 }
    }
}

extension ReorderDifference where CollectionID == ReorderableSingleCollectionIdentifier {
    /// Moves the dragged items to their new place in `collection`.
    func apply<C>(to collection: inout C)
        where C: RangeReplaceableCollection, C.Element: Identifiable, C.Element.ID == ItemID
    {
        let moving = Set(sources)
        guard !moving.isEmpty else { return }
        var moved: [C.Element] = []
        collection.removeAll { element in
            guard moving.contains(element.id) else { return false }
            moved.append(element)
            return true
        }
        switch destination.position {
        case let .before(id):
            let index = collection.firstIndex { $0.id == id } ?? collection.endIndex
            collection.insert(contentsOf: moved, at: index)
        case .end:
            collection.append(contentsOf: moved)
        }
    }
}

/// Native macOS window tabs are off: Arkenal draws its own in the toolbar.
@MainActor
enum WindowTabs {
    static func attach(_ window: NSWindow) {
        window.tabbingMode = .disallowed
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

/// File › New Window (⌘N), New Tab (⌘T), Close Tab (⌘W with two or more
/// tabs), and Window › Show Next / Previous Tab (⌃⇥ / ⌃⇧⇥).
struct WindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.windowTabs) private var tabs

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: ArkenalApp.mainWindowID, value: WindowTarget.new()) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") {
                if let tabs { tabs.newTab() } else { openWindow(id: ArkenalApp.mainWindowID, value: WindowTarget.new()) }
            }
            .keyboardShortcut("t", modifiers: .command)
            // Before File › Close, so ⌘W closes a tab while there are several.
            Button("Close Tab") { tabs.map { $0.close($0.currentID) } }
                .keyboardShortcut("w", modifiers: .command)
                .disabled((tabs?.tabs.count ?? 0) < 2)
        }
        CommandGroup(before: .windowList) {
            Button("Show Next Tab") { tabs?.step(1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled((tabs?.tabs.count ?? 0) < 2)
            Button("Show Previous Tab") { tabs?.step(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled((tabs?.tabs.count ?? 0) < 2)
            Divider()
        }
    }
}
#endif
