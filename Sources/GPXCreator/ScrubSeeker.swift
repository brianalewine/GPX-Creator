import Foundation

// Keep one decode/seek in flight and replace pending requests with the newest
// cursor position, so fast dragging cannot build a queue of obsolete frames.
@MainActor final class ScrubSeeker {
    typealias Perform = (Double,Bool,@escaping () -> Void) -> Void
    private let perform: Perform
    private var pending: (Double,Bool)?
    private(set) var busy = false

    init(perform: @escaping Perform) { self.perform = perform }
    func seek(_ time: Double, exact: Bool) {
        pending = (time,exact)
        drain()
    }
    private func drain() {
        guard !busy, let (time,exact) = pending else { return }
        pending = nil
        busy = true
        perform(time,exact) { [weak self] in
            guard let self else { return }
            self.busy = false
            self.drain()
        }
    }
}
