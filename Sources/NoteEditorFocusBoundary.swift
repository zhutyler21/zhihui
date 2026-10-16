import SwiftUI
import AppKit

/// Mac buttons and selectable text do not always take keyboard focus. This
/// window-scoped boundary finishes source editing on a genuine outside click.
struct NoteEditorFocusBoundary: NSViewRepresentable {
    let active: Bool
    let onLeave: () -> Void

    func makeNSView(context: Context) -> NoteEditorBoundaryView {
        let view = NoteEditorBoundaryView()
        view.active = active; view.onLeave = onLeave
        return view
    }
    func updateNSView(_ view: NoteEditorBoundaryView, context: Context) {
        view.active = active; view.onLeave = onLeave
    }
    static func dismantleNSView(_ view: NoteEditorBoundaryView, coordinator: ()) {
        view.stopObserving(); view.onLeave = nil
    }
}

final class NoteEditorBoundaryView: NSView {
    var active = false
    var onLeave: (() -> Void)?
    private var mouseMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.active, !self.bounds.isEmpty, event.window === self.window,
                  !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            // Let AppKit commit marked Chinese input and deliver the click first.
            self.leaveAfterEvent()
            return event
        }
    }
    private func leaveAfterEvent() {
        guard active else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.window != nil else { return }
            self.onLeave?()
        }
    }
    func stopObserving() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
}
