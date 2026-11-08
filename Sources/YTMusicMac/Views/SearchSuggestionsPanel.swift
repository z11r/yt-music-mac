import AppKit
import SwiftUI
import YouTubeMusic

/// Shows search suggestions in a list under the toolbar search field. While the
/// list is open, ↓ and ↑ move the highlight, Return searches for the highlighted
/// suggestion and Esc closes the list. Every other key, including Return with
/// nothing highlighted, goes to the field, so its editing shortcuts keep working.
struct SearchSuggestionsAttachment: View {
    let session: AppSession

    var body: some View {
        let suggestions = session.searchSuggestions
        SearchSuggestionsBridge(session: session, count: suggestions.items.count,
                                highlightedIndex: suggestions.highlightedIndex,
                                highlighted: suggestions.highlighted)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

private struct SearchSuggestionsBridge: NSViewRepresentable {
    let session: AppSession
    let count: Int
    let highlightedIndex: Int?
    let highlighted: MusicSearchSuggestion?

    func makeNSView(context: Context) -> SearchSuggestionsAnchorView {
        SearchSuggestionsAnchorView(session: session)
    }

    func updateNSView(_ view: SearchSuggestionsAnchorView, context: Context) {
        view.update(count: count, highlightedIndex: highlightedIndex, highlighted: highlighted)
    }

    static func dismantleNSView(_ view: SearchSuggestionsAnchorView, coordinator: ()) {
        view.tearDown()
    }
}

private enum SuggestionLayout {
    static let rowHeight: CGFloat = 24
    static let padding: CGFloat = 5
    static let minimumWidth: CGFloat = 260
    static let gap: CGFloat = 4
}

final class SearchSuggestionsAnchorView: NSView {
    private let session: AppSession
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var panel: SearchSuggestionsWindow?
    private var announcedIndex: Int?

    init(session: AppSession) {
        self.session = session
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tearDown()
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(closeSuggestions), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(closeSuggestions), name: NSWindow.willCloseNotification, object: window)
        center.addObserver(self, selector: #selector(reposition), name: NSWindow.didResizeNotification, object: window)
        center.addObserver(self, selector: #selector(editingEnded(_:)), name: NSControl.textDidEndEditingNotification, object: nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKey(event) else { return event }
            return nil
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handleClick(event)
            return event
        }
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        hidePanel()
    }

    func update(count: Int, highlightedIndex: Int?, highlighted: MusicSearchSuggestion?) {
        guard count > 0, let window, window.isKeyWindow, let field = editingSearchField() else {
            hidePanel()
            return
        }
        let wasVisible = panel?.isVisible == true
        showPanel(below: field, count: count, in: window)
        if !wasVisible {
            announcedIndex = nil
            announce(count == 1 ? "1 suggestion" : "\(count) suggestions", priority: .medium)
        }
        if highlightedIndex != announcedIndex {
            announcedIndex = highlightedIndex
            if let highlightedIndex, let highlighted {
                announce("\(highlighted.query), \(highlightedIndex + 1) of \(count)", priority: .high)
            }
        }
    }

    // MARK: Keys and clicks

    private func handleKey(_ event: NSEvent) -> Bool {
        let suggestions = session.searchSuggestions
        guard suggestions.isVisible, panel?.isVisible == true, let window, event.window === window,
              let editor = window.firstResponder as? NSTextView, editor.delegate is NSSearchField,
              !editor.hasMarkedText() else { return false }
        // Arrow keys carry the function and numeric-pad flags; any other modifier is an editing shortcut.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125: return suggestions.moveHighlight(by: 1)
        case 126: return suggestions.moveHighlight(by: -1)
        case 36, 76:
            guard suggestions.highlighted != nil else { return false }
            session.submitSearch()
            return true
        case 53:
            suggestions.close()
            return true
        default:
            return false
        }
    }

    private func handleClick(_ event: NSEvent) {
        guard session.searchSuggestions.isVisible, let window, event.window === window else { return }
        if let field = editingSearchField(),
           field.convert(field.bounds, to: nil).contains(event.locationInWindow) { return }
        session.searchSuggestions.close()
    }

    @objc private func closeSuggestions() {
        session.searchSuggestions.close()
    }

    @objc private func editingEnded(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field.window === window else { return }
        session.searchSuggestions.close()
    }

    @objc private func reposition() {
        guard let panel, panel.isVisible, let window, let field = editingSearchField() else { return }
        showPanel(below: field, count: session.searchSuggestions.items.count, in: window)
    }

    // MARK: Panel

    /// The toolbar search field, only while it is being edited.
    private func editingSearchField() -> NSSearchField? {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor.delegate as? NSSearchField
    }

    private func showPanel(below field: NSSearchField, count: Int, in window: NSWindow) {
        let panel = self.panel ?? makePanel()
        let fieldFrame = window.convertToScreen(field.convert(field.bounds, to: nil))
        let width = max(fieldFrame.width, SuggestionLayout.minimumWidth)
        let height = CGFloat(count) * SuggestionLayout.rowHeight + SuggestionLayout.padding * 2
        // The field sits at the trailing end of the toolbar, so align trailing edges.
        var x = fieldFrame.maxX - width
        if let screen = window.screen?.visibleFrame { x = min(max(x, screen.minX), screen.maxX - width) }
        panel.setFrame(NSRect(x: x, y: fieldFrame.minY - SuggestionLayout.gap - height, width: width, height: height),
                       display: true)
        if panel.parent !== window {
            window.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    private func hidePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        announcedIndex = nil
    }

    private func makePanel() -> SearchSuggestionsWindow {
        let list = SearchSuggestionList(suggestions: session.searchSuggestions) { [weak session] suggestion in
            session?.search(for: suggestion)
        }
        let panel = SearchSuggestionsWindow(content: FirstClickHostingView(rootView: list))
        self.panel = panel
        return panel
    }

    private func announce(_ text: String, priority: NSAccessibilityPriorityLevel) {
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }
}

/// A borderless child window that never becomes key, so typing stays in the search field.
private final class SearchSuggestionsWindow: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.blendingMode = .behindWindow
        background.maskImage = Self.roundedMask(radius: 8)
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        contentView = background
        setAccessibilityLabel("Search suggestions")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The list window never becomes key, so its first click must act at once.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SearchSuggestionList: View {
    let suggestions: SearchSuggestions
    let choose: (MusicSearchSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.items.enumerated()), id: \.element.id) { index, suggestion in
                SearchSuggestionRow(suggestion: suggestion, isHighlighted: index == suggestions.highlightedIndex) {
                    choose(suggestion)
                }
            }
        }
        .padding(SuggestionLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search suggestions")
    }
}

private struct SearchSuggestionRow: View {
    let suggestion: MusicSearchSuggestion
    let isHighlighted: Bool
    let action: () -> Void
    // Hovering only tints the row. Keyboard highlight changes only with the arrow keys,
    // so a pointer resting under the field never changes what Return searches for.
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(isHighlighted ? Color(nsColor: .selectedMenuItemTextColor) : .secondary)
                    .accessibilityHidden(true)
                Text(suggestion.query)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: SuggestionLayout.rowHeight)
            .foregroundStyle(isHighlighted ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHighlighted ? Color(nsColor: .selectedContentBackgroundColor)
                          : isHovered ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(suggestion.query)
        .accessibilityLabel(suggestion.query)
        .accessibilityHint("Searches for this suggestion")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
