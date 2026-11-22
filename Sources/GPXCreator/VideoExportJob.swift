import AppKit
import Foundation

struct VideoExportProgress {
    let fraction: Double
    let phase: String
    let secondsRemaining: Double?
}

final class VideoExportJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        self.process = process
    }
    func finished(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if self.process === process { self.process = nil }
    }
    func cancel() {
        lock.lock(); cancelled = true
        let running = process
        if running?.isRunning == true { running?.terminate() }
        lock.unlock()
        // A stuck codec must not prevent quit and temporary-file cleanup indefinitely.
        if let running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                self.lock.lock(); defer { self.lock.unlock() }
                if self.process === running && running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
    }
    func publish(_ temporary: URL, to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

@MainActor final class ExportLifecycle {
    static let shared = ExportLifecycle()
    private var jobs: [UUID: VideoExportJob] = [:]
    private(set) var quitPending = false
    var onReadyToQuit: () -> Void = { NSApp.reply(toApplicationShouldTerminate: true) }
    var hasActiveExports: Bool { !jobs.isEmpty }
    func register(_ job: VideoExportJob) -> UUID {
        let id = UUID(); jobs[id] = job; return id
    }
    func finished(_ id: UUID) {
        jobs.removeValue(forKey: id)
        if quitPending && jobs.isEmpty {
            quitPending = false
            onReadyToQuit()
        }
    }
    func stopForQuit() {
        quitPending = true
        for job in jobs.values { job.cancel() }
    }
}

@MainActor final class GPXApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let lifecycle = ExportLifecycle.shared
        guard lifecycle.hasActiveExports else { return .terminateNow }
        if lifecycle.quitPending { return .terminateLater }
        // Tests exercise cancellation directly and never display desktop dialogs.
        guard !AppRuntime.isRunningTests else { return .terminateCancel }
        let alert = NSAlert()
        alert.messageText = "Stop the export and quit?"
        alert.informativeText = "Video exports are still active or queued. Quitting will stop the active export, discard its unfinished file, and cancel waiting exports. Original videos stay unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Exporting")
        alert.addButton(withTitle: "Stop Export and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        // Wait for the subprocess to exit and the export's defer cleanup to finish.
        guard lifecycle.hasActiveExports else { return .terminateNow }
        lifecycle.stopForQuit()
        return .terminateLater
    }
}
