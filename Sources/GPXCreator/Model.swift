import WebKit
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
    var creatorState: CreatorTrackState? = nil
    var isVisible = true

    private enum CodingKeys: String, CodingKey { case id,name,date,points,creatorState,isVisible }
    init(id: String = UUID().uuidString, name: String, date: Date, points: [Point], creatorState: CreatorTrackState? = nil, isVisible: Bool = true) {
        self.id=id;self.name=name;self.date=date;self.points=points;self.creatorState=creatorState;self.isVisible=isVisible
    }
    init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        id=try values.decodeIfPresent(String.self,forKey:.id) ?? UUID().uuidString
        name=try values.decode(String.self,forKey:.name)
        date=try values.decode(Date.self,forKey:.date)
        points=try values.decode([Point].self,forKey:.points)
        creatorState=try values.decodeIfPresent(CreatorTrackState.self,forKey:.creatorState)
        isVisible=try values.decodeIfPresent(Bool.self,forKey:.isVisible) ?? true
    }
}
struct CreatorTrackState: Codable, Equatable {
    var editablePoints: [Point]?
    var filled: Bool
    var importedGPX: Bool
    var finished: Bool
    var duration: Double
    var samplesPerSecond: Int
}
private struct CreatorPathState: Codable {
    var points: [Point]
    var filled: Bool
    var imported: Bool?
    var finished: Bool
    var editingTrackID: String?
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
    var editingTrackID: String?
    var recordingStart: Date?
    var videoURL: URL?
    var mapsKeys: MapsKeyLibrary
}
final class GPXParser: NSObject, XMLParserDelegate {
    var points: [Point] = []; var lat: Double?; var lng: Double?; var timestamp: Date?; var text = ""; var first: Date?
    static func parse(_ data: Data) throws -> [Point] {
        let delegate = GPXParser(); let parser = XMLParser(data: data); parser.delegate = delegate
        guard parser.parse(), !delegate.points.isEmpty else {
            if Task.isCancelled { throw CancellationError() }
            throw NSError(domain: "GPX", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file has no valid GPX track or route points."])
        }
        return delegate.points
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if Task.isCancelled { parser.abortParsing(); return }
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
        interpolateSorted(points.sorted { $0.time < $1.time },at:time)
    }
    static func interpolateSorted(_ p: [Point], at time: Double) -> Point? {
        guard let first = p.first, let last = p.last else { return nil }
        if time <= first.time { return first }; if time >= last.time { return last }
        var low=0,high=p.count-1
        while high-low>1 { let middle=(low+high)/2;if p[middle].time<=time {low=middle}else{high=middle} }
        let a=p[low],b=p[high],f=(time-a.time)/max(0.0001,b.time-a.time)
        var delta=b.lng-a.lng; if delta > 180 { delta -= 360 }; if delta < -180 { delta += 360 }
        let longitude=(a.lng+delta*f+540).truncatingRemainder(dividingBy:360)-180
        return Point(lat:a.lat+(b.lat-a.lat)*f,lng:longitude,time:time,manual:false)
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
                    if sampleTime<b.time,let point=interpolateSorted(anchors,at:sampleTime) { result.append(point) }
                }
            }
        }
        result.append(last)
        return result
    }
}
struct SavedMapsKey: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var value: String
}
struct MapsKeyLibrary: Codable, Equatable {
    var keys: [SavedMapsKey] = []
    var selectedID: String?
    var selectedValue: String { keys.first { $0.id == selectedID }?.value ?? "" }
}
enum KeyStore {
    static let service = "com.brian.gpxcreator.googlemaps"
    private static func readData(account: String) -> Data? {
        var result: CFTypeRef?
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true]
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func library() -> MapsKeyLibrary {
        if let data=readData(account:"named-maps-keys"),let library=try? JSONDecoder().decode(MapsKeyLibrary.self,from:data) { return library }
        if let data=readData(account:"maps"),let value=String(data:data,encoding:.utf8),!value.isEmpty {
            let key=SavedMapsKey(name:"Saved key",value:value)
            return MapsKeyLibrary(keys:[key],selectedID:key.id)
        }
        return MapsKeyLibrary()
    }
    static func save(_ library: MapsKeyLibrary) throws {
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"named-maps-keys"]
        let data=try JSONEncoder().encode(library)
        let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var item=q;item[kSecValueData as String]=data
            let status=SecItemAdd(item as CFDictionary,nil)
            guard status == errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
        } else if status != errSecSuccess { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
        // Retire the original single-key item only after the library is safely saved.
        let legacy: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"maps"]
        SecItemDelete(legacy as CFDictionary)
    }
}
@MainActor final class AppModel: ObservableObject {
    @Published var tab=0; @Published var settings=false; @Published private(set) var key=""
    @Published private(set) var mapsKeys=MapsKeyLibrary()
    @Published var tracks: [Track]=[] { didSet { tracksRevision &+= 1 } }; @Published var selected: String?; @Published var hovered: String?
    @Published var focusedAnchorID: String?
    @Published private(set) var canUndo=false; @Published private(set) var canRedo=false
    @Published var coverage=false
    @Published var dashboardGoogle=(UserDefaults.standard.object(forKey:"dashboardGoogle") as? Bool) ?? true { didSet { UserDefaults.standard.set(dashboardGoogle,forKey:"dashboardGoogle") } }
    @Published var dashboardGoogleSatellite=UserDefaults.standard.bool(forKey:"dashboardGoogleSatellite") { didSet { UserDefaults.standard.set(dashboardGoogleSatellite,forKey:"dashboardGoogleSatellite") } }
    @Published var creatorGoogleSatellite=UserDefaults.standard.bool(forKey:"creatorGoogleSatellite") { didSet { UserDefaults.standard.set(creatorGoogleSatellite,forKey:"creatorGoogleSatellite") } }
    @Published var dashboardEsriSatellite=UserDefaults.standard.bool(forKey:"dashboardEsriSatellite") { didSet { UserDefaults.standard.set(dashboardEsriSatellite,forKey:"dashboardEsriSatellite") } }
    @Published var controls=UserDefaults.standard.bool(forKey:"creatorControls") { didSet { UserDefaults.standard.set(controls,forKey:"creatorControls") } }
    @Published var google=UserDefaults.standard.bool(forKey:"creatorGoogle") { didSet { UserDefaults.standard.set(google,forKey:"creatorGoogle") } }
    @Published var google3D=UserDefaults.standard.bool(forKey:"creatorGoogle3D") { didSet { UserDefaults.standard.set(google3D,forKey:"creatorGoogle3D") } }
    @Published var creatorEsriSatellite=UserDefaults.standard.bool(forKey:"creatorEsriSatellite") { didSet { UserDefaults.standard.set(creatorEsriSatellite,forKey:"creatorEsriSatellite") } }
    @Published var samplesPerSecond: Int = {
        let saved=UserDefaults.standard.object(forKey:"samplesPerSecond") as? Int ?? 1
        return [0,1,5,10].contains(saved) ? saved : 1
    }() { didSet { let preset=[0,1,5,10].contains(samplesPerSecond) ? samplesPerSecond : 1;if preset != samplesPerSecond { samplesPerSecond=preset };UserDefaults.standard.set(preset,forKey:"samplesPerSecond");pathRevision &+= 1;renderedCache=nil } }
    @Published var points: [Point]=[] { didSet { pathRevision &+= 1;renderedCache=nil; persistCreatorPath() } }
    @Published var importedGPX=false { didSet { pathRevision &+= 1;renderedCache=nil; persistCreatorPath() } }
    @Published var filled=false { didSet { pathRevision &+= 1;renderedCache=nil; persistCreatorPath() } }
    @Published var finished=false { didSet { persistCreatorPath() } }
    @Published var time=0.0 { didSet { if videoURL != nil && !restoringVideo && time.isFinite { UserDefaults.standard.set(time,forKey:"lastVideoTime") } } }
    @Published var duration=1.0; @Published var videoURL: URL?; @Published var gpxURL: URL?
    @Published var recordingStart: Date?
    @Published private(set) var isLoadingRecordingStart=false
    @Published var videoError: String?
    @Published var error: String?; @Published var fitID=""; @Published var previewTime: Double?; @Published var lockedPreviewTime: Double?
    @Published var loadingMessage: String?
    @Published var editingTrackID: String?
    @Published private(set) var isParsing=false
    @Published var renderingAborted=false
    private var activeLoadID: UUID?
    var currentLoadID: String { activeLoadID?.uuidString ?? "" }
    private var loadTimeoutTask: Task<Void,Never>?
    private var parseTask: Task<Void,Never>?
    private var loadSnapshot: AppEditSnapshot?
    private var loadCommitted=false
    private var loadingSavedPathURL: URL?
    private var suppressPathPersistence=false
    private(set) var pathRevision=0
    private(set) var tracksRevision=0
    private var scrubbing=false
    private var resumeAfterScrub=false
    private var restoringVideo=false
    private var editKeyMonitor: Any?
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
    private let storageFolder: URL?
    private let fileLoadTimeout: Duration
    var folder: URL { storageFolder ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("GPXCreator") }
    private var renderedCache: [Point]?
    var rendered: [Point] {
        if let renderedCache { return renderedCache }
        let result = samplesPerSecond==0 ? points.filter(\.manual).sorted { $0.time < $1.time } : Geometry.filled(points,samplesPerSecond:samplesPerSecond)
        renderedCache = result
        return result
    }
    init(storageFolder: URL? = nil,fileLoadTimeout: Duration = .seconds(20)) {
        player.isMuted=true
        self.storageFolder=storageFolder
        self.fileLoadTimeout=fileLoadTimeout
        editKeyMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            self?.handleHistoryShortcut(event) == true ? nil : event
        }
        mapsKeys=KeyStore.library()
        key=mapsKeys.selectedValue
        if let data=try? Data(contentsOf:folder.appendingPathComponent("tracks.json")), let saved=try? JSONDecoder().decode([Track].self,from:data) { tracks=saved }
        let savedPath=folder.appendingPathComponent("creator-path.json")
        if FileManager.default.fileExists(atPath:savedPath.path) {
            let loadID=startFileLoad("Loading saved path…",savedPath:savedPath)
            parseTask=Task.detached(priority:.userInitiated) { [weak self] in
                let saved=try? JSONDecoder().decode(CreatorPathState.self,from:Data(contentsOf:savedPath))
                await self?.finishRestoringPath(saved,loadID:loadID)
            }
        }
        DispatchQueue.main.async { [weak self] in _ = self?.importPanel }
        observer=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.1,preferredTimescale:600),queue:.main) { [weak self] t in Task { @MainActor in if let self, !self.scrubbing, !self.seeker.busy, self.previewTime == nil { self.time=t.seconds.isFinite ? t.seconds : 0 } } }
        if storageFolder == nil { restoreLastVideo() }
    }
    deinit { if let editKeyMonitor { NSEvent.removeMonitor(editKeyMonitor) } }
    func persist() { do { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); try JSONEncoder().encode(tracks).write(to:folder.appendingPathComponent("tracks.json"),options:.atomic) } catch { self.error=error.localizedDescription } }
    func toggleTrackVisibility(_ id: String) {
        guard let index=tracks.firstIndex(where:{$0.id==id}) else { return }
        recordUndo()
        tracks[index].isVisible.toggle()
        persist()
    }
    @discardableResult func handleHistoryShortcut(_ event: NSEvent) -> Bool {
        let flags=event.modifierFlags.intersection([.control,.shift,.command,.option])
        guard flags == .control || flags == [.control,.shift] || flags == .command || flags == [.command,.shift],
              event.keyCode == 6 || event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        // Committed app edits share one history, regardless of keyboard focus.
        if flags.contains(.shift) {
            if canRedo { redo() }
            else if let manager=(NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager,manager.canRedo { manager.redo() }
            else { return false }
        } else {
            if canUndo { undo() }
            else if let manager=(NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager,manager.canUndo { manager.undo() }
            else { return false }
        }
        return true
    }
    func recordUndo() {
        undoStack.append(editSnapshot())
        if undoStack.count>100 { undoStack.removeFirst(undoStack.count-100) }
        redoStack.removeAll()
        refreshUndoAvailability()
    }
    func clearHistory() {
        undoStack.removeAll();redoStack.removeAll();refreshUndoAvailability()
        for window in NSApp.windows {
            window.undoManager?.removeAllActions()
            (window.firstResponder as? NSTextView)?.undoManager?.removeAllActions()
        }
    }
    func setRecordingStart(_ value: Date) {
        guard recordingStart != value else { return }
        recordUndo();recordingStart=value
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
    private func editSnapshot() -> AppEditSnapshot { AppEditSnapshot(tracks:tracks,points:points,gpxURL:gpxURL,importedGPX:importedGPX,filled:filled,finished:finished,duration:duration,samplesPerSecond:samplesPerSecond,editingTrackID:editingTrackID,recordingStart:recordingStart,videoURL:videoURL,mapsKeys:mapsKeys) }
    private func restore(_ snapshot: AppEditSnapshot) {
        suppressPathPersistence=true
        tracks=snapshot.tracks;points=snapshot.points;gpxURL=snapshot.gpxURL;importedGPX=snapshot.importedGPX;filled=snapshot.filled;finished=snapshot.finished
        if mapsKeys != snapshot.mapsKeys {
            do { try KeyStore.save(snapshot.mapsKeys);mapsKeys=snapshot.mapsKeys;key=mapsKeys.selectedValue }
            catch { self.error=error.localizedDescription }
        }
        recordingStart=snapshot.recordingStart
        if videoURL != snapshot.videoURL {
            player.pause();videoURL=snapshot.videoURL
            player.replaceCurrentItem(with:snapshot.videoURL.map { AVPlayerItem(url:$0) })
            time=0
            if let url=snapshot.videoURL { saveLastVideo(url) }
            else { UserDefaults.standard.removeObject(forKey:"lastVideoBookmark");UserDefaults.standard.removeObject(forKey:"lastVideoPath") }
        }
        duration=snapshot.duration
        samplesPerSecond=snapshot.samplesPerSecond
        editingTrackID=snapshot.editingTrackID
        suppressPathPersistence=false;persistCreatorPath()
        if videoURL==nil { duration=snapshot.duration }
        selected=selected.flatMap{id in tracks.contains(where:{$0.id==id}) ? id : nil}
        persist()
    }
    private func persistCreatorPath() {
        guard !suppressPathPersistence else { return }
        let url=folder.appendingPathComponent("creator-path.json")
        guard !points.isEmpty else { try? FileManager.default.removeItem(at:url); return }
        let saved=CreatorPathState(points:points,filled:filled,imported:importedGPX,finished:finished,editingTrackID:editingTrackID)
        do { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); try JSONEncoder().encode(saved).write(to:url,options:.atomic) } catch { }
    }
    private func startFileLoad(_ message: String,savedPath: URL? = nil) -> UUID {
        parseTask?.cancel();loadTimeoutTask?.cancel()
        let id=UUID();activeLoadID=id;renderingAborted=false;error=nil
        loadSnapshot=editSnapshot();loadCommitted=false;loadingSavedPathURL=savedPath
        loadingMessage=message;isParsing=true
        let timeout=fileLoadTimeout
        loadTimeoutTask=Task { [weak self] in
            do { try await Task.sleep(for:timeout) } catch { return }
            self?.fileLoadTimedOut(id)
        }
        return id
    }
    private func fileLoadTimedOut(_ id: UUID) {
        guard activeLoadID==id else { return }
        parseTask?.cancel();parseTask=nil;loadTimeoutTask=nil;activeLoadID=nil
        if let savedPath=loadingSavedPathURL {
            let backup=savedPath.deletingLastPathComponent().appendingPathComponent("creator-path-timed-out-\(UUID().uuidString).json")
            try? FileManager.default.moveItem(at:savedPath,to:backup)
        }
        let wasCommitted=loadCommitted
        if loadCommitted,let loadSnapshot {
            restore(loadSnapshot)
            if !undoStack.isEmpty { undoStack.removeLast();refreshUndoAvailability() }
        }
        loadSnapshot=nil;loadCommitted=false;loadingSavedPathURL=nil
        isParsing=false;loadingMessage=nil;renderingAborted=wasCommitted
        error="Loading took longer than 20 seconds and was stopped. Try a smaller file or another map view."
    }
    func mapDidRender(loadID: String) {
        guard !isParsing,activeLoadID?.uuidString==loadID else { return }
        loadTimeoutTask?.cancel();loadTimeoutTask=nil;parseTask=nil;activeLoadID=nil;loadingMessage=nil
        loadSnapshot=nil;loadCommitted=false;loadingSavedPathURL=nil
    }
    private func finishRestoringPath(_ saved: CreatorPathState?,loadID: UUID) {
        guard activeLoadID==loadID else { return }
        suppressPathPersistence=true
        if let saved {
            points=saved.points;filled=saved.imported == nil ? true : saved.filled
            importedGPX=saved.imported ?? false;finished=saved.finished
            editingTrackID=saved.editingTrackID
            duration=max(duration,saved.points.map(\.time).max() ?? 0)
            loadingMessage="Drawing path…"
            loadCommitted=true
        } else {
            loadingMessage=nil;error="Could not load the saved path."
            loadTimeoutTask?.cancel();loadTimeoutTask=nil;activeLoadID=nil
            loadSnapshot=nil;loadingSavedPathURL=nil
        }
        suppressPathPersistence=false;isParsing=false
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
            Task { @MainActor in
                for url in panel.urls {
                    self.importFile(url,dashboard:dashboard,videoOnly:video)
                    while self.isParsing { try? await Task.sleep(for:.milliseconds(10)) }
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for:window,completionHandler:completion) }
        else { panel.begin(completionHandler:completion) }
    }
    func importFile(_ url: URL, dashboard: Bool=false, videoOnly: Bool=false) {
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            let type = (try? url.resourceValues(forKeys:[.contentTypeKey]))?.contentType ?? UTType(filenameExtension:url.pathExtension)
            if videoOnly || (!dashboard && type?.conforms(to:.movie) == true) {
                videoError=nil
                recordUndo()
                player.pause()
                time=0; duration=1; previewTime=nil
                recordingStart=nil
                isLoadingRecordingStart=true
                player.replaceCurrentItem(with:AVPlayerItem(url:url))
                videoURL=url; controls=true
                saveLastVideo(url)
                Task {
                    do {
                        let asset=AVURLAsset(url:url)
                        let d=try await asset.load(.duration)
                        guard videoURL == url else { return }
                        duration=max(1,d.seconds.isFinite ? d.seconds : 1)
                        let start=await Self.videoRecordingStart(asset)
                        if videoURL == url {
                            if recordingStart == nil { recordingStart=start }
                            isLoadingRecordingStart=false
                        }
                    } catch { self.error=error.localizedDescription; isLoadingRecordingStart=false }
                }
                return
            }
            let loadID=startFileLoad("Loading GPX…")
            parseTask=Task.detached(priority:.userInitiated) { [weak self] in
                let result=Result { try GPXParser.parse(Data(contentsOf:url)) }
                await self?.finishImport(result,url:url,dashboard:dashboard,loadID:loadID)
            }
    }
    private func finishImport(_ result: Result<[Point],Error>,url: URL,dashboard: Bool,loadID: UUID) {
        guard activeLoadID==loadID else { return }
        isParsing=false
        switch result {
        case .failure(let failure):
            error=failure.localizedDescription;loadingMessage=nil
            loadTimeoutTask?.cancel();loadTimeoutTask=nil;activeLoadID=nil
            loadSnapshot=nil;loadingSavedPathURL=nil
        case .success(let parsed):
            loadingMessage="Drawing path…"
            loadCommitted=true
            if dashboard {
                let track=Track(name:url.lastPathComponent,date:(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? Date(),points:parsed)
                recordUndo();tracks.append(track);fitID=track.id;persist()
            } else {
                recordUndo();controls=true;gpxURL=url;editingTrackID=nil;suppressPathPersistence=true
                importedGPX=true;filled=false;points=parsed;finished=true
                suppressPathPersistence=false;persistCreatorPath();fitID=UUID().uuidString
            }
        }
    }
    func clearVideo() {
        guard videoURL != nil else { return };recordUndo()
        scrubbing=false; resumeAfterScrub=false
        player.pause(); player.replaceCurrentItem(with:nil)
        videoURL=nil; time=0; duration=1; previewTime=nil; lockedPreviewTime=nil
        UserDefaults.standard.removeObject(forKey:"lastVideoBookmark")
        UserDefaults.standard.removeObject(forKey:"lastVideoPath")
        UserDefaults.standard.removeObject(forKey:"lastVideoTime")
    }
    func clearPath() {
        guard !points.isEmpty || importedGPX || finished || gpxURL != nil else { return }
        recordUndo()
        points=[]; gpxURL=nil; editingTrackID=nil; importedGPX=false; filled=false; finished=false; previewTime=nil; lockedPreviewTime=nil; fitID=""
    }
    func saveCreatorPathToDashboard() {
        guard !points.isEmpty else { return }
        recordUndo()
        let state=CreatorTrackState(editablePoints:importedGPX ? nil : points,filled:filled,importedGPX:importedGPX,finished:finished,duration:duration,samplesPerSecond:samplesPerSecond)
        if let id=editingTrackID,let index=tracks.firstIndex(where:{$0.id==id}) {
            var updated=tracks
            updated[index].points=rendered
            updated[index].creatorState=state
            updated[index].date=Date()
            tracks=updated
            selected=id
        } else {
            let name=gpxURL?.deletingPathExtension().lastPathComponent ?? "Created Path \(Date().formatted(date:.abbreviated,time:.shortened))"
            let track=Track(name:name,date:Date(),points:rendered,creatorState:state)
            tracks.append(track);editingTrackID=track.id;selected=track.id
        }
        persistCreatorPath();persist();tab=1;fitID=""
        DispatchQueue.main.async { [weak self] in self?.fitID=self?.selected ?? "" }
    }
    func editCreatorPathFromDashboard(id: String) {
        guard let track=tracks.first(where:{$0.id==id}),let state=track.creatorState else { return }
        recordUndo();suppressPathPersistence=true
        points=state.editablePoints ?? track.points
        gpxURL=nil;importedGPX=state.importedGPX;filled=state.filled;finished=state.finished
        editingTrackID=id;samplesPerSecond=state.samplesPerSecond;duration=state.duration
        suppressPathPersistence=false;persistCreatorPath()
        focusedAnchorID=nil;previewTime=nil;lockedPreviewTime=nil;controls=true;tab=0;fitID=UUID().uuidString
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
        previewTime = nil
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
    func addAnchorOnPath(at time: Double) {
        let anchors=points.filter(\.manual).sorted { $0.time < $1.time }
        guard time.isFinite,anchors.count>1,let first=anchors.first,let last=anchors.last,
              time>first.time,time<last.time else { return }
        var anchorTime=time
        if points.contains(where:{abs($0.time-anchorTime)<0.02}) {
            let earlier=points.map(\.time).filter{$0<anchorTime-0.02}.max()
            let later=points.map(\.time).filter{$0>anchorTime+0.02}.min()
            if let earlier,let later { anchorTime=(earlier+later)/2 }
            else if let earlier { anchorTime=(earlier+anchorTime)/2 }
            else if let later { anchorTime=(anchorTime+later)/2 }
        }
        guard let location=Geometry.interpolateSorted(rendered,at:anchorTime) else { return }
        recordUndo()
        if !importedGPX { filled=true }
        points.append(Point(lat:location.lat,lng:location.lng,time:anchorTime))
        points.sort{$0.time<$1.time}
    }
    func saveMapsKey(name: String, value: String) throws {
        var library=mapsKeys
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        let value=value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,!value.isEmpty else { return }
        if let index=library.keys.firstIndex(where: { $0.value == value }) {
            library.keys[index].name=name
            library.selectedID=library.keys[index].id
        } else {
            let saved=SavedMapsKey(name:name,value:value)
            library.keys.append(saved);library.selectedID=saved.id
        }
        try persistMapsKeys(library)
    }
    func selectMapsKey(_ id: String) throws {
        guard mapsKeys.keys.contains(where: { $0.id == id }) else { return }
        var library=mapsKeys;library.selectedID=id
        try persistMapsKeys(library)
    }
    func renameMapsKey(_ id: String, name: String) throws {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,let index=mapsKeys.keys.firstIndex(where: { $0.id == id }) else { return }
        var library=mapsKeys;library.keys[index].name=name
        try persistMapsKeys(library)
    }
    func removeMapsKey(_ id: String) throws {
        var library=mapsKeys
        library.keys.removeAll { $0.id == id }
        if library.selectedID == id { library.selectedID=library.keys.first?.id }
        try persistMapsKeys(library)
    }
    private func persistMapsKeys(_ library: MapsKeyLibrary) throws {
        guard library != mapsKeys else { return }
        try KeyStore.save(library)
        recordUndo()
        mapsKeys=library;key=library.selectedValue
    }
    func setSamplesPerSecond(_ value: Int) {
        guard [0,1,5,10].contains(value),value != samplesPerSecond else { return }
        recordUndo();samplesPerSecond=value
    }
    func escapeSelection() {
        focusedAnchorID=nil;lockedPreviewTime=nil;previewTime=nil
    }
    private func saveLastVideo(_ url: URL) {
        let defaults=UserDefaults.standard
        defaults.set(url.path,forKey:"lastVideoPath")
        let bookmark=(try? url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil))
            ?? (try? url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil))
        if let bookmark { defaults.set(bookmark,forKey:"lastVideoBookmark") }
        defaults.set(time,forKey:"lastVideoTime")
    }
    private static func videoRecordingStart(_ asset: AVURLAsset) async -> Date? {
        if let item=try? await asset.load(.creationDate), let date=try? await item.load(.dateValue) {
            return date
        }
        var items=(try? await asset.load(.commonMetadata)) ?? []
        if let formats=try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                items += (try? await asset.loadMetadata(for:format)) ?? []
            }
        }
        for item in items where item.commonKey == .commonKeyCreationDate || item.identifier == .quickTimeMetadataCreationDate {
            if let date=try? await item.load(.dateValue) { return date }
            if let value=try? await item.load(.stringValue) {
                let formatter=ISO8601DateFormatter()
                if let date=formatter.date(from:value) { return date }
                formatter.formatOptions.insert(.withFractionalSeconds)
                if let date=formatter.date(from:value) { return date }
            }
        }
        return nil
    }
    private func restoreLastVideo() {
        videoError=nil
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
        recordingStart=nil;isLoadingRecordingStart=true
        videoURL=url;controls=true;player.replaceCurrentItem(with:AVPlayerItem(url:url))
        Task {
            do {
                let asset=AVURLAsset(url:url),d=try await asset.load(.duration)
                guard videoURL==url else { return }
                duration=max(1,d.seconds.isFinite ? d.seconds : 1)
                let start=await Self.videoRecordingStart(asset)
                if videoURL==url {
                    if recordingStart == nil { recordingStart=start }
                    isLoadingRecordingStart=false
                }
                seek(min(savedTime,duration))
                restoringVideo=false
            } catch {
                guard videoURL==url else { return }
                restoringVideo=false
                isLoadingRecordingStart=false
                // A stale or unreadable remembered file should quietly return to
                // the empty player instead of interrupting the user at launch.
                player.pause(); player.replaceCurrentItem(with:nil)
                videoURL=nil; time=0; duration=1; previewTime=nil; lockedPreviewTime=nil
                videoError=nil
                for key in ["lastVideoBookmark", "lastVideoPath", "lastVideoTime"] { defaults.removeObject(forKey:key) }
            }
        }
    }
    func export() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="Created Path.gpx"; guard panel.runModal() == .OK, let url=panel.url else { return }
        do { try export(to:url) } catch { self.error=error.localizedDescription }
    }
    func export(to url: URL) throws {
        if videoURL != nil && recordingStart == nil {
            throw NSError(domain:"GPXCreator",code:2,userInfo:[NSLocalizedDescriptionKey:"Set the video recording start date and time before exporting GPX for Street View."])
        }
        let epoch=recordingStart ?? Date(); let f=ISO8601DateFormatter()
        let body=rendered.map { "<trkpt lat=\"\($0.lat)\" lon=\"\($0.lng)\"><time>\(f.string(from:epoch.addingTimeInterval($0.time)))</time></trkpt>" }.joined(separator:"\n")
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"GPX Creator\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>Created Path</name><trkseg>\(body)</trkseg></trk></gpx>".write(to:url,atomically:true,encoding:.utf8)
    }
}
