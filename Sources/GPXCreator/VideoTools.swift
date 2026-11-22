import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct VideoToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ToolVideo {
    let url: URL
    let streams: [[String: Any]]
    let format: [String: Any]
    let video: [String: Any]
    var chapters: [[String: Any]] = []
    var duration: Double { Double(format["duration"] as? String ?? "") ?? 0 }
    var size: Int64 { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }
    var fps: Double { VideoEngine.rate(video["avg_frame_rate"] as? String ?? "0") }
    var pixelFormat: String { video["pix_fmt"] as? String ?? "" }
    var depth: Int { let raw = Int(video["bits_per_raw_sample"] as? String ?? "") ?? 0; return raw > 0 ? raw : VideoEngine.depth(pixelFormat) }
    func estimate(_ fps: Double) -> Int64 {
        let audio = streams.filter { $0["codec_type"] as? String != "video" }.reduce(0.0) { $0 + (Double($1["bit_rate"] as? String ?? "") ?? 0) } * duration / 8
        return Int64(max(0, audio + max(0, Double(size)-audio) * min(1, fps / max(self.fps, 0.001))))
    }
}

enum VideoEngine {
    static func rate(_ value: String) -> Double {
        let parts = value.split(separator: "/").compactMap { Double($0) }
        return parts.count == 2 ? (parts[1] == 0 ? 0 : parts[0]/parts[1]) : parts.first ?? 0
    }
    static func depth(_ format: String) -> Int {
        if format.contains("14") { return 14 }
        if format.contains("9le") || format.contains("9be") { return 9 }
        if format.contains("16") || format.contains("48") || format.contains("64") { return 16 }
        if format.contains("12") { return 12 }
        if format.contains("10") || format == "p010le" { return 10 }
        return 8
    }
    static func executable(_ name: String) throws -> URL {
        let paths = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw VideoToolError(message: "\(name) is required. Install FFmpeg (including ffprobe) and try again.") }
        return URL(fileURLWithPath: path)
    }
    @discardableResult static func run(_ name: String, _ arguments: [String], job: VideoExportJob? = nil, onTime: ((Double) -> Void)? = nil) throws -> Data {
        try job?.check()
        let process = Process()
        process.executableURL = try executable(name)
        process.arguments = onTime == nil ? arguments : ["-progress", "pipe:1", "-stats_period", "0.5"] + arguments
        // Files prevent pipe deadlocks and unbounded diagnostic memory during long exports.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("stdout"), err = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        let progressPipe = onTime == nil ? nil : Pipe()
        process.standardOutput = progressPipe ?? (stdout as Any)
        process.standardError = stderr
        if let job { try job.start(process) } else { try process.run() }
        defer { job?.finished(process) }
        if let progressPipe {
            var pending = Data()
            while true {
                let chunk = progressPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(data: pending.prefix(upTo: newline), encoding: .utf8) ?? ""
                    pending.removeSubrange(...newline)
                    if line.hasPrefix("out_time_us="), let microseconds = Double(line.dropFirst(12)) {
                        onTime?(max(0, microseconds / 1_000_000))
                    }
                }
            }
            try? progressPipe.fileHandleForReading.close()
        }
        process.waitUntilExit()
        try job?.check()
        guard process.terminationStatus == 0 else {
            let handle = try FileHandle(forReadingFrom: err)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            try handle.seek(toOffset: length > 12000 ? length-12000 : 0)
            let detail = String(data: try handle.readToEnd() ?? Data(), encoding: .utf8) ?? "Unknown error"
            throw VideoToolError(message: "\(name) failed:\n\(detail)")
        }
        return try Data(contentsOf: out)
    }
    static func probe(_ url: URL, job: VideoExportJob? = nil) throws -> ToolVideo {
        let data = try run("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-show_chapters", "-of", "json", url.path], job: job)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let video = streams.first(where: { $0["codec_type"] as? String == "video" && (($0["disposition"] as? [String: Int])?["attached_pic"] ?? 0) == 0 }),
              let format = json["format"] as? [String: Any] else { throw VideoToolError(message: "No readable video stream was found.") }
        let result = ToolVideo(url: url, streams: streams, format: format, video: video, chapters: json["chapters"] as? [[String: Any]] ?? [])
        guard result.duration > 0, result.fps > 0, !result.pixelFormat.isEmpty else { throw VideoToolError(message: "The video has invalid duration, frame rate, or pixel format.") }
        return result
    }
    static func validateMetadata(source: ToolVideo, output: ToolVideo) throws {
        // Muxer bookkeeping is regenerated; user, location, camera, and spherical tags must survive.
        let generated: Set<String> = ["encoder", "major_brand", "minor_version", "compatible_brands", "vendor_id", "handler_name", "duration", "NUMBER_OF_FRAMES", "NUMBER_OF_BYTES", "BPS", "DURATION"]
        func tags(_ before: [String: Any], _ after: [String: Any]) throws {
            let old = before["tags"] as? [String: String] ?? [:]
            let new = after["tags"] as? [String: String] ?? [:]
            for (key, value) in old where !generated.contains(key) && !key.hasPrefix("_STATISTICS_") {
                // FFmpeg can expose the same MP4 timestamp from both native and mdta fields.
                let repeatedTimestamp = key == "creation_time" && new[key]?.components(separatedBy: ";").allSatisfy { $0 == value } == true
                guard new[key] == value || repeatedTimestamp else { throw VideoToolError(message: "The output container could not preserve metadata ‘\(key)’ (source: \(value), output: \(new[key] ?? "missing")). No export was saved. Try another container, such as MOV or MKV.") }
            }
        }
        guard source.chapters.count == output.chapters.count else { throw VideoToolError(message: "The output container could not preserve chapters. No export was saved.") }
        for (before, after) in zip(source.chapters, output.chapters) {
            try tags(before, after)
            for key in ["start_time", "end_time"] {
                let first = Double(before[key] as? String ?? "") ?? 0
                let second = Double(after[key] as? String ?? "") ?? 0
                guard abs(first-second) < 0.01 else { throw VideoToolError(message: "Chapter timing changed. No export was saved.") }
            }
        }
        try tags(source.format, output.format)
        for (before, after) in zip(source.streams, output.streams) { try tags(before, after) }
        for key in ["color_range", "color_space", "color_transfer", "color_primaries", "chroma_location"] {
            if let value = source.video[key] as? String, value != "unknown", value != "unspecified", output.video[key] as? String != value {
                throw VideoToolError(message: "The encoder could not preserve \(key). No export was saved.")
            }
        }
        let oldSide = source.video["side_data_list"] as? [[String: Any]] ?? []
        let newSide = output.video["side_data_list"] as? [[String: Any]] ?? []
        for data in oldSide {
            guard newSide.contains(where: { NSDictionary(dictionary: $0).isEqual(to: data) }) else {
                throw VideoToolError(message: "The encoder could not preserve video side metadata (\(data["side_data_type"] as? String ?? "unknown")). No export was saved.")
            }
        }
    }
    static func validateApplePlayback(_ url: URL) throws {
        let asset = AVURLAsset(url: url)
        guard asset.isPlayable, let track = asset.tracks(withMediaType: .video).first else {
            throw VideoToolError(message: "macOS cannot open the exported video. No export was saved.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        guard reader.startReading(), output.copyNextSampleBuffer() != nil else {
            throw VideoToolError(message: "macOS cannot decode the exported video: \(reader.error?.localizedDescription ?? "No readable frame"). No export was saved.")
        }
        reader.cancelReading()
    }
    static func export(_ source: ToolVideo, fps: Double, destination: URL, job: VideoExportJob = VideoExportJob(), progress: @escaping (VideoExportProgress) -> Void = { _ in }) throws {
        try job.check()
        func update(phase: String, base: Double, weight: Double, started: Date, time: Double) {
            let fraction = min(1, max(0, time / source.duration))
            let overall = base + weight * fraction
            let elapsed = Date().timeIntervalSince(started)
            let remaining = fraction > 0.005 && elapsed >= 1 ? elapsed / fraction * (1-fraction) : nil
            progress(VideoExportProgress(fraction: overall, phase: phase, secondsRemaining: remaining))
        }
        func encode(_ arguments: [String]) throws {
            try job.check()
            let started = Date()
            progress(VideoExportProgress(fraction: 0, phase: "Encoding video", secondsRemaining: nil))
            try run("ffmpeg", arguments, job: job) { time in
                update(phase: "Encoding video", base: 0, weight: 0.85, started: started, time: time)
            }
        }
        guard fps.isFinite, fps > 0, fps < source.fps else { throw VideoToolError(message: "Choose a frame rate greater than zero and lower than the source frame rate.") }
        guard destination.standardizedFileURL.resolvingSymlinksInPath() != source.url.standardizedFileURL.resolvingSymlinksInPath() else { throw VideoToolError(message: "The export cannot replace the source video.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw VideoToolError(message: "A file already exists at the export path. Choose a new name.") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".video-export-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let index = source.video["index"] as? Int ?? 0
        let videoIndex = source.streams.prefix { ($0["index"] as? Int ?? -1) != index }.filter { $0["codec_type"] as? String == "video" }.count
        let spec = "v:\(videoIndex)"
        var common = ["-hide_banner", "-loglevel", "error", "-xerror", "-nostdin", "-noautorotate", "-i", source.url.path, "-map", "0", "-map_metadata", "0", "-map_chapters", "0", "-copy_unknown", "-c", "copy", "-filter:\(spec)", "fps=\(fps)"]
        let isMP4 = ["mov", "mp4", "m4v"].contains(destination.pathExtension.lowercased())
        let restoreMP4 = isMP4 && (source.format["format_name"] as? String ?? "").components(separatedBy: ",").contains("mov")
        if isMP4 {
            // FFmpeg treats camera tmcd as codec "none" and cannot stream-copy it.
            // Keep its original sample and track structure in the MP4 restoration pass.
            for stream in source.streams where stream["codec_tag_string"] as? String == "tmcd" {
                common += ["-map", "-0:\(stream["index"] as? Int ?? 0)"]
            }
            common += ["-write_tmcd", "0"]
        }
        var outputIndex = 0
        for stream in source.streams {
            if isMP4 && stream["codec_tag_string"] as? String == "tmcd" { continue }
            for (key, value) in stream["tags"] as? [String: String] ?? [:] where key != "encoder" {
                common += ["-metadata:s:\(outputIndex)", "\(key)=\(value)"]
            }
            outputIndex += 1
        }
        let bitrate = max(250_000, (Double(source.video["bit_rate"] as? String ?? "") ?? Double(source.size)*8/source.duration) * fps/source.fps)
        var hardware: [String]? = nil
        #if arch(arm64)
        if ["yuv420p", "yuvj420p", "yuv420p10le", "p010le", "nv12"].contains(source.pixelFormat) {
            hardware = ["-c:\(spec)", (source.depth > 8 || source.video["codec_name"] as? String == "hevc" || (source.video["width"] as? Int ?? 0) > 4096) ? "hevc_videotoolbox" : "h264_videotoolbox", "-pix_fmt:\(spec)", source.depth > 8 ? "p010le" : "yuv420p", "-b:\(spec)", String(Int(bitrate)), "-allow_sw", "0"]
        }
        #endif
        let software = ["-c:\(spec)", "libx265", "-preset", "ultrafast", "-crf", "18", "-pix_fmt:\(spec)", source.pixelFormat]
        var color: [String] = []
        for key in ["color_range", "color_space", "color_transfer", "color_primaries", "chroma_location"] {
            if let value = source.video[key] as? String, value != "unknown", value != "unspecified" {
                let option = key == "chroma_location" ? "chroma_sample_location" : key == "color_space" ? "colorspace" : key == "color_transfer" ? "color_trc" : key
                color += ["-\(option):\(spec)", value]
            }
        }
        let container = isMP4 ? ["-movflags", "+use_metadata_tags"] : []
        if isMP4 {
            common += ["-tag:\(spec)", (hardware?.contains("hevc_videotoolbox") ?? true) ? "hvc1" : "avc1"]
        }
        let softwareContainer = isMP4 ? container + ["-tag:\(spec)", "hvc1"] : container
        if let hardware {
            do {
                try encode(common + hardware + color + container + ["-n", temporary.path])
                if restoreMP4 { try MP4Metadata.restore(source: source.url, output: temporary) }
                let hardwareOutput = try probe(temporary, job: job)
                try validateMetadata(source: source, output: hardwareOutput)
            }
            catch { try job.check(); try? FileManager.default.removeItem(at: temporary); try encode(common + software + color + softwareContainer + ["-n", temporary.path]); if restoreMP4 { try MP4Metadata.restore(source: source.url, output: temporary) } }
        } else { try encode(common + software + color + softwareContainer + ["-n", temporary.path]); if restoreMP4 { try MP4Metadata.restore(source: source.url, output: temporary) } }
        try job.check()
        progress(VideoExportProgress(fraction: 0.85, phase: "Checking metadata", secondsRemaining: nil))
        let output = try probe(temporary, job: job)
        guard output.video["width"] as? Int == source.video["width"] as? Int,
              output.video["height"] as? Int == source.video["height"] as? Int,
              output.depth == source.depth, output.streams.count == source.streams.count,
              abs(output.fps-fps) < 0.01,
              abs(output.duration-source.duration) <= max(1, 2/fps) else {
            throw VideoToolError(message: "Export validation failed: resolution, bit depth, streams, duration, or frame rate changed unexpectedly.")
        }
        try validateMetadata(source: source, output: output)
        // Decode the entire result before publishing it; damaged or truncated results stay temporary.
        let verificationStarted = Date()
        progress(VideoExportProgress(fraction: 0.85, phase: "Verifying video", secondsRemaining: nil))
        try run("ffmpeg", ["-hide_banner", "-v", "error", "-xerror", "-err_detect", "explode", "-nostdin", "-i", temporary.path, "-map", "0:v?", "-map", "0:a?", "-f", "null", "-"], job: job) { time in
            update(phase: "Verifying video", base: 0.85, weight: 0.14, started: verificationStarted, time: time)
        }
        try job.check()
        if isMP4 { try validateApplePlayback(temporary) }
        try job.check()
        try job.publish(temporary, to: destination)
        progress(VideoExportProgress(fraction: 1, phase: "Complete", secondsRemaining: 0))
    }
}

@MainActor final class VideoToolsModel: ObservableObject {
    @Published var videos: [VideoQueueItem] = []
    @Published var requests: [VideoExportRequest] = []
    @Published var selectedID: UUID?
    @Published var settings = VideoExportSettings.saved() {
        didSet {
            guard !selecting else { return }
            if let index = videos.firstIndex(where: { $0.id == selectedID }) { videos[index].settings = settings }
            settings.save()
        }
    }
    @Published var loading = false
    @Published var status = ""
    @Published var error: String?
    @Published var exportProgress: VideoExportProgress?
    @Published var stoppingExport = false
    @Published private(set) var activeRequestID: UUID?
    private var selecting = false
    private var jobs: [UUID: (VideoExportJob, UUID)] = [:]
    private var started: Date?
    private var secondsPerMediaSecond: Double? = UserDefaults.standard.object(forKey: "videoToolsExportTimeRatio") as? Double
    var video: ToolVideo? { videos.first { $0.id == selectedID }?.video }
    var busy: Bool { activeRequestID != nil }
    var unfinishedCount: Int { requests.filter { !$0.terminal }.count }
    var estimatedQueueTime: Double? {
        guard unfinishedCount > 0 else { return 0 }
        let active = requests.first(where: { $0.id == activeRequestID })
        let elapsed = started.map { Date().timeIntervalSince($0) } ?? 0
        var ratio = secondsPerMediaSecond ?? 1
        if let active, let progress = exportProgress, progress.fraction > 0.01, elapsed > 1 {
            ratio = elapsed / progress.fraction / active.video.duration
        }
        let waiting = requests.filter { $0.state == "Waiting" }.reduce(0.0) { $0 + $1.video.duration * ratio }
        guard let active else { return waiting }
        if let progress = exportProgress, progress.fraction > 0.01, elapsed > 1 {
            return waiting + elapsed / progress.fraction * (1-progress.fraction)
        }
        return waiting + active.video.duration * ratio
    }
    var hasMeasuredEstimate: Bool { secondsPerMediaSecond != nil || (exportProgress?.fraction ?? 0) > 0.01 }
    func select(_ id: UUID) {
        guard let item = videos.first(where: { $0.id == id }) else { return }
        selecting = true; selectedID = id; settings = item.settings; selecting = false
    }
    func commitFPS(_ value: Double, videoID: UUID?) {
        guard value.isFinite, value > 0 else { return }
        if videoID == selectedID { settings.fps = value }
        else if let index = videos.firstIndex(where: { $0.id == videoID }) {
            videos[index].settings.fps = value
            videos[index].settings.save()
        }
    }
    func removeVideo(_ id: UUID) {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        videos.remove(at: index)
        if selectedID == id {
            if videos.isEmpty { selectedID = nil }
            else { select(videos[min(index, videos.count - 1)].id) }
        }
    }
    func add(_ video: ToolVideo) {
        let inherited = (videos.last?.settings ?? settings).transferred(to: video)
        let item = VideoQueueItem(video: video, settings: inherited)
        videos.append(item); select(item.id)
    }
    func stopAllExports() {
        // Remove waiting work first so the worker cannot start another export.
        let waiting = requests.filter { $0.state == "Waiting" }.map(\.id)
        for id in waiting { cancelRequest(id) }
        stopExport()
    }
    func stopExport() {
        guard let id = activeRequestID else { return }
        stoppingExport = true; jobs[id]?.0.cancel(); status = "Stopping export…"
    }
    func cancelRequest(_ id: UUID) {
        if id == activeRequestID { stopExport(); return }
        guard let index = requests.firstIndex(where: { $0.id == id && $0.state == "Waiting" }) else { return }
        jobs[id]?.0.cancel()
        requests[index].state = "Stopped"
        if let (_, registration) = jobs.removeValue(forKey: id) { ExportLifecycle.shared.finished(registration) }
    }
    func choose() {
        guard !loading else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        loading = true
        Task {
            defer { loading = false }
            var failures: [String] = []
            for url in urls {
                do { let info = try await Task.detached(priority: .userInitiated) { try VideoEngine.probe(url) }.value; add(info) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !failures.isEmpty { error = failures.joined(separator: "\n\n") }
        }
    }
    func availableDestination(_ proposed: URL) -> URL {
        var result = proposed; var suffix = 2
        while FileManager.default.fileExists(atPath: result.path) || requests.contains(where: { !$0.terminal && $0.destination.standardizedFileURL == result.standardizedFileURL }) {
            result = proposed.deletingLastPathComponent().appendingPathComponent(proposed.deletingPathExtension().lastPathComponent + "-\(suffix)." + proposed.pathExtension)
            suffix += 1
        }
        return result
    }
    @discardableResult func enqueue(videoID: UUID, settings: VideoExportSettings, destination: URL, start: Bool = true) -> UUID? {
        guard !ExportLifecycle.shared.quitPending, let item = videos.first(where: { $0.id == videoID }), settings.fps.isFinite, settings.fps > 0, settings.fps < item.video.fps else { return nil }
        guard destination.standardizedFileURL.resolvingSymlinksInPath() != item.video.url.standardizedFileURL.resolvingSymlinksInPath() else { error = "Choose a destination different from the original video."; return nil }
        let request = VideoExportRequest(videoID: videoID, video: item.video, settings: settings, destination: availableDestination(destination))
        let job = VideoExportJob()
        jobs[request.id] = (job, ExportLifecycle.shared.register(job))
        requests.append(request)
        if start { startNext() }
        return request.id
    }
    func export(fps: Double, original: Bool, custom: Bool, path: String) {
        guard let video, let selectedID else { return }
        let snapshot = VideoExportSettings(fps: fps, original: original, custom: custom, path: path)
        let name = video.url.deletingPathExtension().lastPathComponent + "-\(fps)fps." + video.url.pathExtension
        let destination: URL
        if original { destination = video.url.deletingLastPathComponent().appendingPathComponent(name) }
        else if custom {
            guard path.hasPrefix("/") else { error = "Enter an absolute export file path."; return }
            destination = URL(fileURLWithPath: path)
        } else {
            let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.directoryURL = video.url.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else { return }; destination = url
        }
        enqueue(videoID: selectedID, settings: snapshot, destination: destination)
    }
    func exportAll() {
        let selection = selectedID
        for item in videos {
            select(item.id)
            let value = item.settings
            export(fps: value.fps, original: value.original, custom: value.custom, path: value.path)
        }
        if let selection { select(selection) }
    }
    func startNext() {
        guard activeRequestID == nil else { return }
        // Quit cancels both pending and active jobs, and waits for every registration.
        if ExportLifecycle.shared.quitPending {
            for request in requests where request.state == "Waiting" { cancelRequest(request.id) }
            return
        }
        guard let request = requests.first(where: { $0.state == "Waiting" }), let (job, registration) = jobs[request.id], let index = requests.firstIndex(where: { $0.id == request.id }) else { return }
        activeRequestID = request.id; requests[index].state = "Exporting"
        started = Date(); stoppingExport = false
        exportProgress = VideoExportProgress(fraction: 0, phase: "Preparing export", secondsRemaining: nil)
        status = "Exporting \(request.video.url.lastPathComponent)…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try VideoEngine.export(request.video, fps: request.settings.fps, destination: request.destination, job: job) { progress in
                        Task { @MainActor in
                            if self.activeRequestID == request.id { self.exportProgress = progress }
                        }
                    }
                }.value
                requests[index].state = "Saved"; status = "Saved: \(request.destination.path)"
                if let started {
                    let ratio = Date().timeIntervalSince(started) / request.video.duration
                    secondsPerMediaSecond = secondsPerMediaSecond.map { ($0 + ratio)/2 } ?? ratio
                    UserDefaults.standard.set(secondsPerMediaSecond, forKey: "videoToolsExportTimeRatio")
                }
            } catch is CancellationError {
                requests[index].state = "Stopped"; status = "Export stopped. No partial video was saved."
            } catch {
                requests[index].state = "Failed"; requests[index].detail = error.localizedDescription
                self.error = error.localizedDescription; status = "Export failed. No completed export was saved."
            }
            activeRequestID = nil; exportProgress = nil; stoppingExport = false; started = nil
            jobs.removeValue(forKey: request.id)
            // Cancel pending registrations before allowing the quit reply.
            if ExportLifecycle.shared.quitPending {
                for pending in requests where pending.state == "Waiting" { cancelRequest(pending.id) }
            }
            ExportLifecycle.shared.finished(registration)
            startNext()
        }
    }
}

struct VideoToolsView: View {
    @ObservedObject var model: VideoToolsModel
    private var fps: Double { get { model.settings.fps } nonmutating set { model.settings.fps = newValue } }
    private var original: Bool { get { model.settings.original } nonmutating set { model.settings.original = newValue } }
    private var custom: Bool { get { model.settings.custom } nonmutating set { model.settings.custom = newValue } }
    private var path: String { get { model.settings.path } nonmutating set { model.settings.path = newValue } }
    @AppStorage("videoToolsMetric") private var metric = true
    @State private var speed = 1.0
    @State private var unit = "m/s"
    @State private var fpsDraft = ""
    @State private var fpsDraftVideoID: UUID?
    @State private var fpsInputError: String?
    @FocusState private var fpsFocused: Bool
    private func syncFPSDraft() {
        fpsDraft = fps.formatted(.number.grouping(.never))
        fpsDraftVideoID = model.selectedID
    }
    private func commitFPSDraft() {
        let value = try? Double(fpsDraft.trimmingCharacters(in: .whitespacesAndNewlines), format: .number.locale(.current))
        if let value, value.isFinite, value > 0 {
            model.commitFPS(value, videoID: fpsDraftVideoID)
            fpsInputError = nil
        } else {
            fpsInputError = "Enter a number greater than zero. The previous frame rate was kept."
        }
    }
    private func finishFPSEdit() {
        commitFPSDraft()
        fpsFocused = false
    }
    private var validFPS: Bool { fps.isFinite && fps > 0 }
    static func spacing(speed: Double, unit: String, fps: Double, metric: Bool) -> Double {
        let meters = speed * (unit == "ft/s" ? 0.3048 : unit == "mph" ? 0.44704 : 1)
        return meters / fps / (metric ? 1 : 0.3048)
    }
    private var canExport: Bool {
        model.video != nil && validFPS && fps < (model.video?.fps ?? 0) && (!custom || path.hasPrefix("/"))
    }
    private let accent = Color(red: 0.85, green: 0.39, blue: 0.08)

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Video Tools").font(.system(size: 27, weight: .bold))
                            Text("Reduce frame rate. Plan the distance between frames.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label("LOCAL PROCESSING", systemImage: "desktopcomputer")
                            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(.secondary).padding(.top, 10)
                    }
                    queueCard
                    if model.video != nil { sourceCard }
                    if geometry.size.width >= 880 {
                        HStack(alignment: .top, spacing: 20) {
                            exportCard.frame(maxWidth: .infinity)
                            calculatorCard.frame(width: 310)
                        }
                    } else {
                        exportCard
                        calculatorCard
                    }

                }.padding(28).frame(maxWidth: 1160).frame(maxWidth: .infinity)

            }.background(Color(red: 0.965, green: 0.97, blue: 0.98))
        }.modifier(WorkspaceGlassPanel())
            .onAppear { syncFPSDraft() }
            .onChange(of: fps) { _, _ in if !fpsFocused { syncFPSDraft() } }
            .onChange(of: model.selectedID) { _, _ in
                if fpsFocused { commitFPSDraft() }; fpsFocused = false; fpsInputError = nil; syncFPSDraft()
            }
            .onChange(of: fpsFocused) { _, focused in
                if focused { fpsDraftVideoID = model.selectedID; fpsInputError = nil }
                else { commitFPSDraft(); syncFPSDraft() }
            }
            .tint(accent)
            .alert("Video processing error", isPresented: Binding(get: { !AppRuntime.isRunningTests && model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }

    private var visibleExportHistory: [VideoExportRequest] { model.requests.filter { $0.state != "Stopped" } }

    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle("Videos", subtitle: "Select a video to adjust its next export.", icon: "film.stack")
                Spacer()
                Button { model.choose() } label: { Label("Add videos…", systemImage: "plus") }.disabled(model.loading)
                if model.unfinishedCount > 0 {
                    Button { model.stopAllExports() } label: { Label("Stop all", systemImage: "stop.fill") }
                        .help("Stop the active export and cancel all waiting exports")
                        .disabled(model.stoppingExport && model.unfinishedCount <= 1)
                }
                Button("Export all") { if fpsFocused { finishFPSEdit() }; model.exportAll() }.disabled(model.videos.isEmpty)
            }
            if model.loading { ProgressView("Inspecting videos…").controlSize(.small) }
            if model.videos.isEmpty {
                Text("Add one or more videos to get started. Original files stay in place.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.videos) { item in videoQueueRow(item) }
                    }
                }.frame(height: min(260, CGFloat(model.videos.count) * 50 + (model.busy ? 50 : 0)))
            }
            if let active = model.requests.first(where: { $0.id == model.activeRequestID }),
               !model.videos.contains(where: { $0.id == active.videoID }), let progress = model.exportProgress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(active.video.url.lastPathComponent).lineLimit(1)
                        Spacer()
                        Text(progress.fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        requestAction(active)
                    }
                    ProgressView(value: progress.fraction).progressViewStyle(.linear)
                    Text(model.stoppingExport ? "Stopping export…" : "\(progress.phase) · \(remainingText(progress))")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.unfinishedCount > 0 {
                Divider()
                HStack {
                    Label("\(model.unfinishedCount) exports remaining", systemImage: "arrow.triangle.2.circlepath").font(.caption.bold())
                    Spacer()
                    if let seconds = model.estimatedQueueTime {
                        Text("About \(queueDuration(seconds)) total\(model.hasMeasuredEstimate ? "" : " · preliminary")").font(.caption).foregroundStyle(.secondary)
                    }
                }.help("Exports run one at a time. Time estimates adapt to observed speed.")
            }
            if !visibleExportHistory.isEmpty {
                DisclosureGroup("Export history (\(visibleExportHistory.count))") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleExportHistory.reversed()) { request in
                            HStack(spacing: 10) {
                                Image(systemName: request.state == "Saved" ? "checkmark.circle.fill" : request.state == "Failed" ? "exclamationmark.circle" : "clock")
                                    .foregroundStyle(request.state == "Failed" ? Color.red : Color.secondary)
                                Text(request.destination.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text("\(request.settings.fps.formatted()) fps").foregroundStyle(.secondary)
                                Spacer()
                                Text(request.state).foregroundStyle(.secondary)
                                requestAction(request)
                            }.font(.caption).help(request.detail.isEmpty ? request.destination.path : request.detail)
                        }
                    }.padding(.top, 10)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).modifier(VideoToolCard())
    }

    private func videoQueueRow(_ item: VideoQueueItem) -> some View {
        let exports = model.requests.filter { $0.videoID == item.id }
        let active = exports.first { $0.id == model.activeRequestID }
        let waiting = exports.filter { $0.state == "Waiting" }.count
        let displayed = active ?? exports.last(where: { $0.state == "Waiting" }) ?? exports.last.flatMap { $0.state == "Stopped" ? nil : $0 }
        let selected = model.selectedID == item.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { model.select(item.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "film").foregroundStyle(selected ? accent : Color.secondary)
                        Text(item.video.url.lastPathComponent).fontWeight(selected ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text("\(item.settings.fps.formatted()) fps").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
                if let displayed {
                    HStack(spacing: 5) {
                        if displayed.state == "Saved" { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        Text(active != nil ? (model.stoppingExport ? "Stopping…" : "Exporting") : waiting > 0 ? "\(waiting) queued" : displayed.state)
                        if waiting > 0 && active != nil { Text("· \(waiting) waiting") }
                    }.font(.caption).foregroundStyle(displayed.state == "Failed" ? Color.red : Color.secondary)
                    requestAction(displayed)
                }
                if active == nil {
                Button { model.removeVideo(item.id) } label: {
                    Image(systemName: "xmark").frame(width: 20, height: 20)
                }.buttonStyle(.borderless)
                    .help("Remove from list. Original file and queued exports are kept.")
                    .accessibilityLabel("Remove \(item.video.url.lastPathComponent) from videos")
                }
            }
            if active != nil, let progress = model.exportProgress {
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
                HStack {
                    Text(model.stoppingExport ? "Discarding unfinished export…" : "\(progress.phase) · \(remainingText(progress))")
                    Spacer()
                    Text(progress.fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12)
            .background(selected ? accent.opacity(0.07) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) { if selected { RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3).padding(.vertical, 12) } }
            .help(item.video.url.path)
    }

    @ViewBuilder private func requestAction(_ request: VideoExportRequest) -> some View {
        if !request.terminal {
            Button { model.cancelRequest(request.id) } label: { Image(systemName: request.id == model.activeRequestID ? "stop.fill" : "xmark").frame(width: 20, height: 20) }
                .buttonStyle(.borderless).help(request.state == "Waiting" ? "Remove queued export" : "Stop export")
                .accessibilityLabel("Cancel export for \(request.video.url.lastPathComponent)")
                .disabled(request.id == model.activeRequestID && model.stoppingExport)
        } else if request.state == "Saved" {
            Button { NSWorkspace.shared.activateFileViewerSelecting([request.destination]) } label: { Image(systemName: "folder").frame(width: 20, height: 20) }
                .buttonStyle(.borderless).help("Show exported video in Finder").accessibilityLabel("Show exported video in Finder")
        } else if request.state == "Failed" {
            Button { model.error = request.detail } label: { Image(systemName: "info.circle").frame(width: 20, height: 20) }
                .buttonStyle(.borderless).help("Show export error").accessibilityLabel("Show export error")
        }
    }
    private func queueDuration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "Estimating…" }
        let value = max(0, Int(seconds.rounded(.up)))
        if value >= 3600 { return "\(value / 3600)h \(value % 3600 / 60)m" }
        if value >= 60 { return "\(value / 60)m \(value % 60)s" }
        return "\(value)s"
    }

    private func remainingText(_ progress: VideoExportProgress) -> String {
        guard let seconds = progress.secondsRemaining, seconds.isFinite else { return "Estimating time remaining…" }
        let value = max(1, Int(seconds.rounded(.up)))
        let duration = value >= 60 ? "\(value / 60)m \(value % 60)s" : "\(value)s"
        return "About \(duration) remaining in \(progress.phase == "Verifying video" ? "verification" : "encoding")"
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("SELECTED VIDEO DETAILS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            if let video = model.video {
                HStack(spacing: 0) {
                    statistic("ORIGINAL SIZE", value: ByteCountFormatter.string(fromByteCount: video.size, countStyle: .file))
                    statistic("ESTIMATED EXPORT", value: validFPS ? "≈ " + ByteCountFormatter.string(fromByteCount: video.estimate(fps), countStyle: .file) : "—")
                    statistic("SOURCE FORMAT", value: "\(video.video["width"] as? Int ?? 0) × \(video.video["height"] as? Int ?? 0)", detail: "\(video.fps.formatted()) fps · \(video.depth)-bit")
                }
                Text("Estimated size varies with video content and encoding.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).modifier(VideoToolCard())
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Export settings", subtitle: "Create a lower frame rate copy.", icon: "slider.horizontal.3")
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Frame rate").font(.system(size: 13, weight: .semibold))
                    Text("Applies to the selected video’s next export").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    TextField("FPS", text: $fpsDraft).textFieldStyle(.plain)
                        .focused($fpsFocused)
                        .onSubmit { finishFPSEdit() }

                        .font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit().frame(width: 66)
                        .accessibilityLabel("Export frame rate")
                    Text("fps").foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
                    .background(CommitOnOutsideClick(isEditing: fpsFocused, commit: finishFPSEdit))
            }
            if let fpsInputError { Text(fpsInputError).font(.caption).foregroundStyle(.red) }
            if let video = model.video, !validFPS || fps >= video.fps {
                Label("Choose a rate above 0 and below \(video.fps.formatted()) fps.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("SAVE LOCATION").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Toggle(isOn: Binding(get: { original }, set: { original = $0 })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Same folder as original").fontWeight(.medium)
                        Text("Saves a new file beside your video.").font(.caption).foregroundStyle(.secondary)
                    }
                }.onChange(of: original) { _, value in if value { custom = false } }
                Toggle("Use a custom file path", isOn: Binding(get: { custom }, set: { custom = $0 })).onChange(of: custom) { _, value in if value { original = false } }
                if custom {
                    HStack {
                        TextField("/path/to/export.mov", text: Binding(get: { path }, set: { path = $0 })).textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            let panel = NSSavePanel(); panel.nameFieldStringValue = "export.mov"
                            if panel.runModal() == .OK { path = panel.url?.path ?? "" }
                        }
                    }
                }
                if !original && !custom {
                    Label("You’ll choose a location when you export.", systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Label("Original resolution, bit depth & metadata", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
                .help("Exports are checked for metadata preservation and fully decoded before saving. Unsupported formats report an error. Your original is never overwritten.")
            Button { if fpsFocused { finishFPSEdit() }; model.export(fps: fps, original: original, custom: custom, path: path) } label: {
                HStack { Spacer(); Label(model.busy ? "Add export to queue" : "Export selected video", systemImage: "square.and.arrow.up"); Spacer() }.padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canExport)
            if model.video == nil { Text("Choose a video to enable export.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
        }.padding(22).modifier(VideoToolCard())
    }

    private var calculatorCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Frame spacing", subtitle: "Turn travel speed into distance.", icon: "ruler")
            VStack(alignment: .leading, spacing: 8) {
                Text("Travel speed").font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    TextField("Speed", value: $speed, format: .number).textFieldStyle(.roundedBorder).frame(minWidth: 60)
                    Picker("Speed unit", selection: $unit) {
                        Text("m/s").tag("m/s"); Text("ft/s").tag("ft/s"); Text("mph").tag("mph")
                    }.labelsHidden().frame(width: 90)
                }.controlSize(.large)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Show distance in").font(.system(size: 13, weight: .medium))
                Picker("Distance units", selection: $metric) { Text("Meters").tag(true); Text("Feet").tag(false) }.pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("DISTANCE BETWEEN FRAMES").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                if validFPS && speed.isFinite && speed >= 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(Self.spacing(speed: speed, unit: unit, fps: fps, metric: metric).formatted(.number.precision(.fractionLength(0...4))))
                            .font(.system(size: 36, weight: .semibold, design: .rounded)).minimumScaleFactor(0.45).lineLimit(1).monospacedDigit()
                        Text(metric ? "m" : "ft").font(.title3).foregroundStyle(.secondary)
                    }.foregroundStyle(accent)
                    Text("At \(fps.formatted()) frames per second").font(.caption).foregroundStyle(.secondary)
                } else { Text("Enter a valid speed and frame rate.").font(.callout).foregroundStyle(.red) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            Text("Uses the frame rate in Export settings. You can calculate spacing without opening a video.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).modifier(VideoToolCard())
    }

    private func sectionTitle(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func statistic(_ title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VideoToolCard: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.07)))
            .shadow(color: .black.opacity(0.025), radius: 8, y: 3)
    }
}
