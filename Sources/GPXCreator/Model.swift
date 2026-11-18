import SwiftUI
import AVKit
import Security

struct Point: Codable, Identifiable {
    var id = UUID().uuidString
    var lat: Double
    var lng: Double
    var time: Double
    var manual = true
}
struct Track: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var date: Date
    var points: [Point]
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
    static func filled(_ points: [Point]) -> [Point] {
        let p = points.filter(\.manual).sorted { $0.time < $1.time }; guard let a=p.first, let b=p.last else { return p }
        var result=p
        if b.time-a.time < 200000, Int(ceil(a.time)) <= Int(floor(b.time)) {
            for t in Int(ceil(a.time))...Int(floor(b.time)) where !p.contains(where: { abs($0.time-Double(t)) < 0.01 }) { if let point=interpolate(p,at:Double(t)) { result.append(point) } }
        }
        return result.sorted { $0.time < $1.time }
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
    @Published var coverage=false; @Published var controls=false; @Published var google=false
    @Published var points: [Point]=[]; @Published var filled=false; @Published var finished=false
    @Published var time=0.0; @Published var duration=1.0; @Published var videoURL: URL?; @Published var gpxURL: URL?
    @Published var error: String?; @Published var fitID=""; @Published var previewTime: Double?
    let player=AVPlayer(); var observer: Any?; var scopedURLs: [URL]=[]
    var folder: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("GPXCreator") }
    var rendered: [Point] { filled ? Geometry.filled(points) : points.sorted { $0.time < $1.time } }
    init() {
        if let data=try? Data(contentsOf:folder.appendingPathComponent("tracks.json")), let saved=try? JSONDecoder().decode([Track].self,from:data) { tracks=saved }
        observer=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.1,preferredTimescale:600),queue:.main) { [weak self] t in Task { @MainActor in if self?.previewTime == nil { self?.time=t.seconds.isFinite ? t.seconds : 0 } } }
    }
    func persist() { do { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); try JSONEncoder().encode(tracks).write(to:folder.appendingPathComponent("tracks.json"),options:.atomic) } catch { self.error=error.localizedDescription } }
    func choose(dashboard: Bool, video: Bool=false) {
        let panel=NSOpenPanel(); panel.allowsMultipleSelection=dashboard; panel.allowedContentTypes=video ? [.movie] : [.xml, .data]; panel.message=video ? "Choose an equirectangular video" : "Choose GPX files"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { do {
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            if video { videoURL=url; player.replaceCurrentItem(with:AVPlayerItem(url:url)); Task { do { let d=try await AVURLAsset(url:url).load(.duration); duration=max(1,d.seconds.isFinite ? d.seconds : 1) } catch { self.error=error.localizedDescription } }; return }
            let parsed=try GPXParser.parse(Data(contentsOf:url))
            if dashboard { let track=Track(name:url.lastPathComponent,date:(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? Date(),points:parsed); tracks.append(track); fitID=track.id; persist() }
            else { gpxURL=url; points=parsed; finished=false; fitID=UUID().uuidString }
        } catch { self.error=error.localizedDescription } }
    }
    func seek(_ t: Double) { time=max(0,min(duration,t)); player.seek(to:CMTime(seconds:time,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) }
    func export() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="Created Path.gpx"; guard panel.runModal() == .OK, let url=panel.url else { return }
        let epoch=Date(); let f=ISO8601DateFormatter()
        let body=rendered.map { "<trkpt lat=\"\($0.lat)\" lon=\"\($0.lng)\"><time>\(f.string(from:epoch.addingTimeInterval($0.time)))</time></trkpt>" }.joined(separator:"\n")
        do { try "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"GPX Creator\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>Created Path</name><trkseg>\(body)</trkseg></trk></gpx>".write(to:url,atomically:true,encoding:.utf8) } catch { self.error=error.localizedDescription }
    }
}
