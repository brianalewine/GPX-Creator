import SwiftUI
import AVKit
import Security
import UniformTypeIdentifiers

struct Point: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var lat: Double
    var lng: Double
    var time: Double
    var manual = true
}
struct Track: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var date: Date
    var points: [Point]
}
private struct CreatorPathState: Codable {
    var points: [Point]
    var filled: Bool
    var imported: Bool?
    var finished: Bool
}
private struct AppEditSnapshot: Equatable {
    var tracks: [Track]
    var points: [Point]
    var gpxURL: URL?
    var importedGPX: Bool
    var filled: Bool
    var finished: Bool
    var duration: Double
    var samplesPerSecond: Int
}
final class GPXParser: NSObject, XMLParserDelegate {
    var points: [Point] = []; var lat: Double?; var lng: Double?; var timestamp: Date?; var text = ""; var first: Date?
    static func parse(_ data: Data) throws -> [Point] {
        let delegate = GPXParser(); let parser = XMLParser(data: data); parser.delegate = delegate
        guard parser.parse(), !delegate.points.isEmpty else { throw NSError(domain: "GPX", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file has no valid GPX track or route points."]) }
        return delegate.points
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if ["trkpt", "rtept", "wpt"].contains(name) { lat = Double(attributes["lat"] ?? ""); lng = Double(attributes["lon"] ?? ""); timestamp = nil }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "time" { let f = ISO8601DateFormatter(); timestamp = f.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)); if timestamp == nil { f.formatOptions.insert(.withFractionalSeconds); timestamp = f.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        if ["trkpt", "rtept", "wpt"].contains(name), let lat, let lng, abs(lat) <= 90, abs(lng) <= 180 {
            if first == nil { first = timestamp }
            points.append(Point(lat: lat, lng: lng, time: timestamp.flatMap { t in first.map { t.timeIntervalSince($0) } } ?? Double(points.count)))
        }
    }
}
enum Geometry {
    static func interpolate(_ points: [Point], at time: Double) -> Point? {
        let p = points.sorted { $0.time < $1.time }; guard let first = p.first, let last = p.last else { return nil }
        if time <= first.time { return first }; if time >= last.time { return last }
        for (a,b) in zip(p,p.dropFirst()) where time >= a.time && time <= b.time {
            let f = (time-a.time)/max(0.0001,b.time-a.time)
            var delta = b.lng-a.lng; if delta > 180 { delta -= 360 }; if delta < -180 { delta += 360 }
            let longitude = (a.lng+delta*f+540).truncatingRemainder(dividingBy: 360)-180
            return Point(lat: a.lat+(b.lat-a.lat)*f, lng: longitude, time: time, manual: false)
        }; return nil
    }
    static func filled(_ points: [Point],samplesPerSecond: Int=1) -> [Point] {
        let anchors=points.filter(\.manual).sorted { $0.time < $1.time }
        guard let last=anchors.last else { return anchors }
        let rate=Double(max(1,samplesPerSecond))
        var result:[Point]=[]
        for (a,b) in zip(anchors,anchors.dropFirst()) {
            result.append(a)
            let intervals=Int(floor((b.time-a.time)*rate))
            if intervals>1 {
                for step in 1..<intervals {
                    let sampleTime=a.time+Double(step)/rate
                    if sampleTime<b.time,let point=interpolate(anchors,at:sampleTime) { result.append(point) }
                }
            }
        }
        result.append(last)
        return result
    }
}
enum KeyStore {
    static let service = "com.brian.gpxcreator.googlemaps"
    static func read() -> String { var result: CFTypeRef?; let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"maps",kSecReturnData as String:true]; guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess, let data=result as? Data else { return "" }; return String(data:data,encoding:.utf8) ?? "" }
    static func save(_ key: String) throws {
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"maps"]
        let data=Data(key.utf8); let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound { var item=q; item[kSecValueData as String]=data; let s=SecItemAdd(item as CFDictionary,nil); guard s==errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(s)) } }
        else if status != errSecSuccess { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
    }
}
@MainActor final class AppModel: ObservableObject {
    @Published var tab=0; @Published var settings=false; @Published var key=KeyStore.read()
    @Published var tracks: [Track]=[]; @Published var selected: String?; @Published var hovered: String?
    @Published var focusedAnchorID: String?
    @Published private(set) var canUndo=false; @Published private(set) var canRedo=false
    @Published var coverage=false
    @Published var dashboardGoogle=(UserDefaults.standard.object(forKey:"dashboardGoogle") as? Bool) ?? true { didSet { UserDefaults.standard.set(dashboardGoogle,forKey:"dashboardGoogle") } }
    @Published var dashboardEsriSatellite=UserDefaults.standard.bool(forKey:"dashboardEsriSatellite") { didSet { UserDefaults.standard.set(dashboardEsriSatellite,forKey:"dashboardEsriSatellite") } }
    @Published var controls=UserDefaults.standard.bool(forKey:"creatorControls") { didSet { UserDefaults.standard.set(controls,forKey:"creatorControls") } }
    @Published var google=false; @Published var google3D=false
    @Published var creatorEsriSatellite=UserDefaults.standard.bool(forKey:"creatorEsriSatellite") { didSet { UserDefaults.standard.set(creatorEsriSatellite,forKey:"creatorEsriSatellite") } }
    @Published var samplesPerSecond=(UserDefaults.standard.object(forKey:"samplesPerSecond") as? Int) ?? 200 { didSet { let bounded=max(1,min(2000,samplesPerSecond));if bounded != samplesPerSecond { samplesPerSecond=bounded };UserDefaults.standard.set(bounded,forKey:"samplesPerSecond");renderedCache=nil } }
    @Published var points: [Point]=[] { didSet { renderedCache=nil; persistCreatorPath() } }
    @Published var importedGPX=false { didSet { renderedCache=nil; persistCreatorPath() } }
    @Published var filled=false { didSet { renderedCache=nil; persistCreatorPath() } }
    @Published var finished=false { didSet { persistCreatorPath() } }
    @Published var time=0.0 { didSet { if videoURL != nil && !restoringVideo && time.isFinite { UserDefaults.standard.set(time,forKey:"lastVideoTime") } } }
    @Published var duration=1.0; @Published var videoURL: URL?; @Published var gpxURL: URL?
    @Published var error: String?; @Published var fitID=""; @Published var previewTime: Double?
    private var scrubbing=false
    private var resumeAfterScrub=false
    private var restoringVideo=false
    private var undoStack:[AppEditSnapshot]=[]
    private var redoStack:[AppEditSnapshot]=[]
    private lazy var seeker = ScrubSeeker { [weak self] time, exact, completion in
        guard let self else { completion(); return }
        let tolerance = exact ? CMTime.zero : CMTime(seconds:0.1,preferredTimescale:600)
        self.player.seek(to:CMTime(seconds:time,preferredTimescale:600),toleranceBefore:tolerance,toleranceAfter:tolerance) { _ in
            Task { @MainActor in completion() }
        }
    }
    let player=AVPlayer(); var observer: Any?; var scopedURLs: [URL]=[]
    var folder: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("GPXCreator") }
    private var renderedCache: [Point]?
    var rendered: [Point] {
        if let renderedCache { return renderedCache }
        let result = filled && !importedGPX ? Geometry.filled(points,samplesPerSecond:samplesPerSecond) : points.sorted { $0.time < $1.time }
        renderedCache = result
        return result
    }
    init() {
        if let data=try? Data(contentsOf:folder.appendingPathComponent("tracks.json")), let saved=try? JSONDecoder().decode([Track].self,from:data) { tracks=saved }
        if let data=try? Data(contentsOf:folder.appendingPathComponent("creator-path.json")),let saved=try? JSONDecoder().decode(CreatorPathState.self,from:data) {
            points=saved.points;filled=saved.imported == nil ? true : saved.filled;importedGPX=saved.imported ?? false;finished=saved.finished
            duration=max(duration,saved.points.map(\.time).max() ?? 0)
        }
        DispatchQueue.main.async { [weak self] in _ = self?.importPanel }
        observer=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.1,preferredTimescale:600),queue:.main) { [weak self] t in Task { @MainActor in if let self, !self.scrubbing, !self.seeker.busy, self.previewTime == nil { self.time=t.seconds.isFinite ? t.seconds : 0 } } }
        restoreLastVideo()
    }
    func persist() { do { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); try JSONEncoder().encode(tracks).write(to:folder.appendingPathComponent("tracks.json"),options:.atomic) } catch { self.error=error.localizedDescription } }
    func recordUndo() {
        undoStack.append(editSnapshot())
        if undoStack.count>100 { undoStack.removeFirst(undoStack.count-100) }
        redoStack.removeAll()
        refreshUndoAvailability()
    }
    func undo() {
        guard let previous=undoStack.popLast() else { return }
        redoStack.append(editSnapshot());restore(previous);refreshUndoAvailability()
    }
    func redo() {
        guard let next=redoStack.popLast() else { return }
        undoStack.append(editSnapshot());restore(next);refreshUndoAvailability()
    }
    private func refreshUndoAvailability() { canUndo = !undoStack.isEmpty;canRedo = !redoStack.isEmpty }
    private func editSnapshot() -> AppEditSnapshot { AppEditSnapshot(tracks:tracks,points:points,gpxURL:gpxURL,importedGPX:importedGPX,filled:filled,finished:finished,duration:duration,samplesPerSecond:samplesPerSecond) }
    private func restore(_ snapshot: AppEditSnapshot) {
        tracks=snapshot.tracks;points=snapshot.points;gpxURL=snapshot.gpxURL;importedGPX=snapshot.importedGPX;filled=snapshot.filled;finished=snapshot.finished
        samplesPerSecond=snapshot.samplesPerSecond
        if videoURL==nil { duration=snapshot.duration }
        selected=selected.flatMap{id in tracks.contains(where:{$0.id==id}) ? id : nil}
        persist()
    }
    private func persistCreatorPath() {
        let url=folder.appendingPathComponent("creator-path.json")
        guard !points.isEmpty else { try? FileManager.default.removeItem(at:url); return }
        let saved=CreatorPathState(points:points,filled:filled,imported:importedGPX,finished:finished)
        do { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); try JSONEncoder().encode(saved).write(to:url,options:.atomic) } catch { }
    }
    private lazy var importPanel = NSOpenPanel()
    private let gpxType = UTType(filenameExtension:"gpx") ?? .xml
    private var choosingFile = false
    func choose(dashboard: Bool, video: Bool=false) {
        guard !choosingFile else { return }
        let panel=importPanel
        panel.allowsMultipleSelection = !video
        panel.allowedContentTypes = video ? [.movie] : dashboard ? [gpxType,.xml] : [.movie,gpxType,.xml]
        panel.message = video ? "Choose an equirectangular video" : dashboard ? "Choose GPX files" : "Choose video or GPX files"
        choosingFile = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.choosingFile = false
            guard response == .OK else { return }
            for url in panel.urls { self.importFile(url,dashboard:dashboard,videoOnly:video) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for:window,completionHandler:completion) }
        else { panel.begin(completionHandler:completion) }
    }
    func importFile(_ url: URL, dashboard: Bool=false, videoOnly: Bool=false) {
        do {
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            let type = (try? url.resourceValues(forKeys:[.contentTypeKey]))?.contentType ?? UTType(filenameExtension:url.pathExtension)
            if videoOnly || (!dashboard && type?.conforms(to:.movie) == true) {
                player.pause()
                time=0; duration=1; previewTime=nil
                player.replaceCurrentItem(with:AVPlayerItem(url:url))
                videoURL=url; controls=true
                saveLastVideo(url)
                Task {
                    do {
                        let d=try await AVURLAsset(url:url).load(.duration)
                        guard videoURL == url else { return }
                        duration=max(1,d.seconds.isFinite ? d.seconds : 1)
                    } catch { self.error=error.localizedDescription }
                }
                return
            }
            let parsed=try GPXParser.parse(Data(contentsOf:url))
            if dashboard {
                let track=Track(name:url.lastPathComponent,date:(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? Date(),points:parsed)
                recordUndo()
                tracks.append(track); fitID=track.id; persist()
            } else {
                recordUndo()
                controls=true; gpxURL=url; importedGPX=true; filled=false; points=parsed; finished=true; fitID=UUID().uuidString
            }
        } catch { self.error=error.localizedDescription }
    }
    func clearVideo() {
        scrubbing=false; resumeAfterScrub=false
        player.pause(); player.replaceCurrentItem(with:nil)
        videoURL=nil; time=0; duration=1; previewTime=nil
        UserDefaults.standard.removeObject(forKey:"lastVideoBookmark")
        UserDefaults.standard.removeObject(forKey:"lastVideoPath")
        UserDefaults.standard.removeObject(forKey:"lastVideoTime")
    }
    func clearPath() {
        guard !points.isEmpty || importedGPX || finished || gpxURL != nil else { return }
        recordUndo()
        points=[]; gpxURL=nil; importedGPX=false; filled=false; finished=false; previewTime=nil; fitID=""
    }
    func seek(_ t: Double, exact: Bool=true) {
        guard t.isFinite else { return }
        time=max(0,min(duration,t))
        seeker.seek(time,exact:exact)
    }
    func pauseVideo() {
        player.pause()
        let current=player.currentTime().seconds
        if current.isFinite { time=max(0,min(duration,current)) }
    }
    func beginScrubbing() {
        resumeAfterScrub = player.rate != 0
        scrubbing = true
        previewTime = nil
        player.pause()
    }
    func endScrubbing(at t: Double) {
        seek(t)
        scrubbing = false
        if resumeAfterScrub { player.play() }
    }
    func preview(at t: Double) {
        guard t.isFinite else { return }
        previewTime=max(0,min(duration,t))
        seeker.seek(previewTime!,exact:false)
    }
    func updateAnchor(id: String,time: Double?=nil,lat: Double?=nil,lng: Double?=nil) {
        guard let index=points.firstIndex(where:{$0.id==id}),points[index].manual else { return }
        let old=points[index]
        let updatedTime=time.map{max(0,$0)} ?? old.time
        let updatedLat=lat.flatMap{abs($0)<=90 ? $0 : nil} ?? old.lat
        let updatedLng=lng.flatMap{abs($0)<=180 ? $0 : nil} ?? old.lng
        guard old.time != updatedTime || old.lat != updatedLat || old.lng != updatedLng else { return }
        recordUndo()
        if let time,time.isFinite { points[index].time=max(0,time) }
        if let lat,lat.isFinite,abs(lat)<=90 { points[index].lat=lat }
        if let lng,lng.isFinite,abs(lng)<=180 { points[index].lng=lng }
    }
    func setSamplesPerSecond(_ value: Int) {
        let bounded=max(1,min(2000,value))
        guard bounded != samplesPerSecond else { return }
        recordUndo();samplesPerSecond=bounded
    }
    private func saveLastVideo(_ url: URL) {
        let defaults=UserDefaults.standard
        defaults.set(url.path,forKey:"lastVideoPath")
        let bookmark=(try? url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil))
            ?? (try? url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil))
        if let bookmark { defaults.set(bookmark,forKey:"lastVideoBookmark") }
        defaults.set(time,forKey:"lastVideoTime")
    }
    private func restoreLastVideo() {
        let defaults=UserDefaults.standard
        let savedTime=max(0,defaults.double(forKey:"lastVideoTime"))
        var resolvedURL: URL?
        var stale=false
        if let bookmark=defaults.data(forKey:"lastVideoBookmark"),let url=try? URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale) {
            resolvedURL=url
            if stale,let refreshed=try? url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) { defaults.set(refreshed,forKey:"lastVideoBookmark") }
        } else if let path=defaults.string(forKey:"lastVideoPath"),!path.isEmpty {
            resolvedURL=URL(fileURLWithPath:path)
        }
        guard let url=resolvedURL else { return }
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        restoringVideo=true
        videoURL=url;controls=true;player.replaceCurrentItem(with:AVPlayerItem(url:url))
        Task {
            do {
                let asset=AVURLAsset(url:url),d=try await asset.load(.duration)
                guard videoURL==url else { return }
                duration=max(1,d.seconds.isFinite ? d.seconds : 1)
                seek(min(savedTime,duration))
                restoringVideo=false
            } catch {
                restoringVideo=false
                self.error="Could not restore the last video: \(error.localizedDescription)"
            }
        }
    }
    func export() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="Created Path.gpx"; guard panel.runModal() == .OK, let url=panel.url else { return }
        let epoch=Date(); let f=ISO8601DateFormatter()
        let body=rendered.map { "<trkpt lat=\"\($0.lat)\" lon=\"\($0.lng)\"><time>\(f.string(from:epoch.addingTimeInterval($0.time)))</time></trkpt>" }.joined(separator:"\n")
        do { try "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"GPX Creator\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>Created Path</name><trkseg>\(body)</trkseg></trk></gpx>".write(to:url,atomically:true,encoding:.utf8) } catch { self.error=error.localizedDescription }
    }
}
