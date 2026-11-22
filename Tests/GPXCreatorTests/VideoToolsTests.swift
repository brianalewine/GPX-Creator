import XCTest
@testable import GPXCreator

final class VideoToolsTests: XCTestCase {
    func testSpacingConversions() {
        XCTAssertEqual(VideoToolsView.spacing(speed: 1, unit: "m/s", fps: 2, metric: true), 0.5)
        XCTAssertEqual(VideoToolsView.spacing(speed: 10, unit: "ft/s", fps: 2, metric: false), 5, accuracy: 0.000001)
        XCTAssertEqual(VideoToolsView.spacing(speed: 60, unit: "mph", fps: 2, metric: false), 44, accuracy: 0.000001)
    }
    func testRationalFrameRates() {
        XCTAssertEqual(VideoEngine.rate("30000/1001"), 29.97002997, accuracy: 0.000001)
        XCTAssertEqual(VideoEngine.rate("0/0"), 0)
        XCTAssertEqual(VideoEngine.depth("yuv420p10le"), 10)
        XCTAssertEqual(VideoEngine.depth("yuv422p12le"), 12)
    }
    func testProgressAndCancellationRemovePartialFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try VideoEngine.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96:rate=30:duration=4", "-c:v", "libx264", source.path])
        let info = try VideoEngine.probe(source)
        for phase in ["Encoding video", "Verifying video"] {
            let job = VideoExportJob()
            var sawProgress = false
            let destination = directory.appendingPathComponent(UUID().uuidString + ".mov")
            XCTAssertThrowsError(try VideoEngine.export(info, fps: 2, destination: destination, job: job) { progress in
                XCTAssertTrue((0...1).contains(progress.fraction))
                if progress.phase == phase && progress.fraction > (phase == "Encoding video" ? 0 : 0.85) {
                    sawProgress = true
                    job.cancel()
                }
            }) { error in XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertTrue(sawProgress)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".video-export-") })
        }
        let destination = directory.appendingPathComponent("complete.mov")
        var last = 0.0
        try VideoEngine.export(info, fps: 2, destination: destination) { progress in last = progress.fraction }
        XCTAssertEqual(last, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }
    func testCancelRunningProcess() throws {
        let job = VideoExportJob()
        XCTAssertThrowsError(try VideoEngine.run("ffmpeg", ["-v", "error", "-re", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=60", "-f", "null", "-"], job: job) { time in
            if time > 0 { job.cancel() }
        }) { error in XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testQuitWaitsForEveryExportCleanup() throws {
        let lifecycle = ExportLifecycle()
        var ready = false
        lifecycle.onReadyToQuit = { ready = true }
        let first = VideoExportJob(), second = VideoExportJob()
        let firstID = lifecycle.register(first), secondID = lifecycle.register(second)
        XCTAssertTrue(lifecycle.hasActiveExports)
        lifecycle.stopForQuit()
        XCTAssertThrowsError(try first.check())
        XCTAssertThrowsError(try second.check())
        XCTAssertFalse(ready)
        lifecycle.finished(firstID)
        XCTAssertFalse(ready)
        lifecycle.finished(secondID)
        XCTAssertTrue(ready)
        XCTAssertFalse(lifecycle.hasActiveExports)
    }
    @MainActor func testQueueSnapshotsSequentialExportsAndRepeatedDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try VideoEngine.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96:rate=30:duration=2", "-c:v", "libx264", source.path])
        let info = try VideoEngine.probe(source)
        let model = VideoToolsModel()
        model.add(info)
        model.settings = VideoExportSettings(fps: 3, original: false, custom: true, path: directory.appendingPathComponent("first.mp4").path)
        model.add(info)
        XCTAssertEqual(model.settings.fps, 3)
        XCTAssertTrue(model.settings.custom)
        let id = try XCTUnwrap(model.selectedID)
        let destination = directory.appendingPathComponent("repeat.mp4")
        let snapshot = model.settings
        let first = try XCTUnwrap(model.enqueue(videoID: id, settings: snapshot, destination: destination, start: false))
        model.settings.fps = 4
        let second = try XCTUnwrap(model.enqueue(videoID: id, settings: model.settings, destination: destination, start: false))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(model.requests[0].destination, model.requests[1].destination)
        XCTAssertEqual(model.requests[0].settings.fps, 3)
        XCTAssertEqual(model.requests[1].settings.fps, 4)
        XCTAssertGreaterThan(try XCTUnwrap(model.estimatedQueueTime), 0)
        model.startNext()
        model.settings.fps = 5
        for _ in 0..<1500 where model.unfinishedCount > 0 {
            XCTAssertLessThanOrEqual(model.requests.filter { $0.state == "Exporting" }.count, 1)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.unfinishedCount, 0)
        XCTAssertEqual(model.requests.map(\.state), ["Saved", "Saved"], "\(model.requests.map(\.detail))")
        XCTAssertEqual(model.requests[0].settings.fps, 3)
        XCTAssertEqual(try VideoEngine.probe(model.requests[0].destination).fps, 3, accuracy: 0.001)
        XCTAssertEqual(try VideoEngine.probe(model.requests[1].destination).fps, 4, accuracy: 0.001)
        XCTAssertEqual(model.settings.fps, 5)
        XCTAssertEqual(model.estimatedQueueTime, 0)
    }
    @MainActor func testWaitingExportCancellationDoesNotRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try VideoEngine.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96:rate=30:duration=2", "-c:v", "libx264", source.path])
        let model = VideoToolsModel()
        model.add(try VideoEngine.probe(source))
        let videoID = try XCTUnwrap(model.selectedID)
        let settings = VideoExportSettings(fps: 2)
        let cancelledDestination = directory.appendingPathComponent("cancelled.mp4")
        let cancelled = try XCTUnwrap(model.enqueue(videoID: videoID, settings: settings, destination: cancelledDestination, start: false))
        model.cancelRequest(cancelled)
        XCTAssertEqual(model.requests[0].state, "Stopped")
        let finalDestination = directory.appendingPathComponent("finished.mp4")
        model.enqueue(videoID: videoID, settings: settings, destination: finalDestination)
        for _ in 0..<1000 where model.unfinishedCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.requests.map(\.state), ["Stopped", "Saved"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalDestination.path))
        XCTAssertFalse(ExportLifecycle.shared.hasActiveExports)
    }
    @MainActor func testStopAllCancelsActiveAndWaitingExports() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try VideoEngine.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96:rate=30:duration=2", "-c:v", "libx264", source.path])
        let model = VideoToolsModel()
        model.add(try VideoEngine.probe(source))
        let id = try XCTUnwrap(model.selectedID)
        let first = directory.appendingPathComponent("first.mp4")
        let second = directory.appendingPathComponent("second.mp4")
        model.enqueue(videoID: id, settings: VideoExportSettings(), destination: first)
        model.enqueue(videoID: id, settings: VideoExportSettings(), destination: second)
        XCTAssertEqual(model.unfinishedCount, 2)
        model.stopAllExports()
        for _ in 0..<500 where model.unfinishedCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.requests.map(\.state), ["Stopped", "Stopped"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(ExportLifecycle.shared.hasActiveExports)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".video-export-") })
    }
    func testSettingsTransferClampsUnsupportedFPS() {
        let video = ToolVideo(url: URL(fileURLWithPath: "/tmp/new.mp4"), streams: [], format: ["duration": "5"], video: ["avg_frame_rate": "1/1", "pix_fmt": "yuv420p"])
        let inherited = VideoExportSettings(fps: 2, original: false, custom: true, path: "/tmp/previous.mov").transferred(to: video)
        XCTAssertEqual(inherited.fps, 0.5)
        XCTAssertTrue(inherited.custom)
        XCTAssertEqual(inherited.path, "/tmp/new-0.5fps.mov")
    }
    func testCameraTimecodeExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("camera.mp4")
        if let camera = ProcessInfo.processInfo.environment["GPX_CAMERA_TEST_VIDEO"] {
            try VideoEngine.run("ffmpeg", ["-v", "error", "-nostdin", "-i", camera, "-t", "2", "-map", "0:v", "-map", "0:a?", "-c", "copy", "-map_metadata", "0", source.path])
        } else {
            try VideoEngine.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96:rate=30000/1001:duration=2", "-c:v", "libx264", "-timecode", "14:32:03:26", source.path])
        }
        let info = try VideoEngine.probe(source)
        XCTAssertTrue(info.streams.contains { $0["codec_tag_string"] as? String == "tmcd" })
        let destination = directory.appendingPathComponent("reduced.mp4")
        try VideoEngine.export(info, fps: 2, destination: destination)
        let result = try VideoEngine.probe(destination)
        XCTAssertEqual(result.streams.count, info.streams.count)
        XCTAssertEqual((result.video["tags"] as? [String: String])?["timecode"], (info.video["tags"] as? [String: String])?["timecode"])
        XCTAssertEqual(result.fps, 2, accuracy: 0.001)
        XCTAssertEqual(result.video["codec_tag_string"] as? String, result.video["codec_name"] as? String == "hevc" ? "hvc1" : "avc1")
        try VideoEngine.validateApplePlayback(destination)
        try VideoEngine.validateMetadata(source: info, output: result)
    }
    func testTenBitExportWithAudio() throws {
        guard (try? VideoEngine.executable("ffmpeg")) != nil else { throw XCTSkip("FFmpeg is not installed") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tenbit.mov")
        try VideoEngine.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96:rate=24:duration=2", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le", "-c:a", "aac", source.path])
        let info = try VideoEngine.probe(source)
        let destination = directory.appendingPathComponent("reduced.mov")
        try VideoEngine.export(info, fps: 2, destination: destination)
        let result = try VideoEngine.probe(destination)
        XCTAssertEqual(result.depth, 10)
        XCTAssertEqual(result.streams.count, 2)
        XCTAssertEqual(result.fps, 2, accuracy: 0.001)
    }
    func testExportAndCorruptionRejection() throws {
        guard (try? VideoEngine.executable("ffmpeg")) != nil else { throw XCTSkip("FFmpeg is not installed") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try VideoEngine.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=128x96:rate=30:duration=2", "-metadata", "title=Video Tools test", "-c:v", "libx264", source.path])
        let info = try VideoEngine.probe(source)
        let destination = directory.appendingPathComponent("output.mov")
        try VideoEngine.export(info, fps: 2, destination: destination)
        let output = try VideoEngine.probe(destination)
        XCTAssertEqual(output.fps, 2, accuracy: 0.001)
        XCTAssertEqual(output.depth, info.depth)
        XCTAssertEqual((output.format["tags"] as? [String: String])?["title"], "Video Tools test")
        XCTAssertThrowsError(try VideoEngine.export(info, fps: 2, destination: source))
        let bad = directory.appendingPathComponent("broken.mov")
        try Data("corrupted video".utf8).write(to: bad)
        XCTAssertThrowsError(try VideoEngine.probe(bad))
        let fake = ToolVideo(url: bad, streams: info.streams, format: info.format, video: info.video)
        let failed = directory.appendingPathComponent("failed.mov")
        XCTAssertThrowsError(try VideoEngine.export(fake, fps: 2, destination: failed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".video-export-") })
    }
}
