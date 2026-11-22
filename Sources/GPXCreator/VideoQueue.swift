import Foundation

struct VideoExportSettings: Equatable {
    var fps: Double = 2
    var original = true
    var custom = false
    var path = ""
    static func saved(_ defaults: UserDefaults = .standard) -> Self {
        Self(fps: defaults.object(forKey: "videoToolsFPS") as? Double ?? 2,
             original: defaults.object(forKey: "videoToolsOriginalLocation") as? Bool ?? true,
             custom: defaults.bool(forKey: "videoToolsCustomLocation"),
             path: defaults.string(forKey: "videoToolsExportPath") ?? "")
    }
    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(fps, forKey: "videoToolsFPS"); defaults.set(original, forKey: "videoToolsOriginalLocation")
        defaults.set(custom, forKey: "videoToolsCustomLocation"); defaults.set(path, forKey: "videoToolsExportPath")
    }
    func transferred(to video: ToolVideo) -> Self {
        var result = self
        if !fps.isFinite || fps <= 0 || fps >= video.fps { result.fps = min(2, video.fps / 2) }
        if custom && !path.isEmpty {
            let previous = URL(fileURLWithPath: path)
            result.path = previous.deletingLastPathComponent().appendingPathComponent(video.url.deletingPathExtension().lastPathComponent + "-\(result.fps)fps." + previous.pathExtension).path
        }
        return result
    }
}
struct VideoQueueItem: Identifiable {
    let id = UUID()
    let video: ToolVideo
    var settings: VideoExportSettings
}
struct VideoExportRequest: Identifiable {
    let id = UUID()
    let videoID: UUID
    let video: ToolVideo
    let settings: VideoExportSettings
    let destination: URL
    var state = "Waiting"
    var detail = ""
    var terminal: Bool { ["Saved", "Stopped", "Failed"].contains(state) }
}
