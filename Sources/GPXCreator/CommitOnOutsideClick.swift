import SwiftUI
import AppKit

/// Observes app-window clicks before controls handle them, including clicks in
/// sibling panels, the sidebar, and the toolbar. Events are never consumed.
struct CommitOnOutsideClick: NSViewRepresentable {
    var isEditing: Bool
    var commit: () -> Void

    final class Coordinator {
        weak var view: NSView?
        var isEditing = false
        var commit: () -> Void = {}
        var monitor: Any?
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, self.isEditing, let view = self.view else { return event }
                let inside = event.window === view.window && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                if !inside {
                    self.isEditing = false
                    self.commit()
                }
                return event
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { remove() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isEditing = isEditing
        context.coordinator.commit = commit
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }
}
