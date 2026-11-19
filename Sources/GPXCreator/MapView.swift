import SwiftUI
import WebKit
struct MapView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var dashboard: Bool
    func makeCoordinator() -> Coordinator { Coordinator(model,dashboard) }
    func makeNSView(context: Context) -> WKWebView {
        let config=WKWebViewConfiguration(); config.userContentController.add(context.coordinator,name:"bridge")
        let web=WKWebView(frame:.zero,configuration:config); context.coordinator.web=web
        if let url=Bundle.module.url(forResource:"map",withExtension:"html",subdirectory:"Resources") { web.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }; return web
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update() }
    @MainActor class Coordinator: NSObject, WKScriptMessageHandler {
        let model: AppModel; let dashboard: Bool; weak var web: WKWebView?; var ready=false; var previous=""; var lastCursor=""
        init(_ model: AppModel,_ dashboard: Bool) { self.model=model;self.dashboard=dashboard }
        private struct MapState: Equatable {
            let tracks: [Track]
            let points: [Point]
            let google: Bool
            let osmSatellite: Bool
            let google3D: Bool
            let googleSatellite: Bool
            let key: String
            let coverage: Bool
            let selected: String?
            let focusedAnchorID: String?
            let hovered: String?
            let duration: Double
            let hasVideo: Bool
            let fit: String
            let camera: [String:Double]?
        }
        private var lastState: MapState?
        func update() {
            guard ready else { return }
            let google=dashboard ? model.dashboardGoogle : model.google
            let osmSatellite=dashboard ? model.dashboardEsriSatellite : model.creatorEsriSatellite
            let camera=cameraForMap(google:google)
            let google3D = !dashboard && model.google3D
            let googleSatellite = !dashboard && UserDefaults.standard.bool(forKey:"creatorGoogleSatellite")
            let state = MapState(tracks:model.tracks,points:dashboard ? [] : model.rendered,google:google,osmSatellite:osmSatellite,google3D:google3D,googleSatellite:googleSatellite,key:model.key,coverage:model.coverage,selected:model.selected,focusedAnchorID:model.focusedAnchorID,hovered:model.hovered,duration:model.duration,hasVideo:model.videoURL != nil,fit:model.fitID,camera:camera)
            let encoder=JSONEncoder()
            if state != lastState {
            guard let tracks=try? encoder.encode(state.tracks),let points=try? encoder.encode(state.points) else { return }
            let dict: [String:Any] = ["dashboard":dashboard,"google":google,"osmSatellite":osmSatellite,"google3D":google3D,"googleSatellite":googleSatellite,"key":model.key,"coverage":model.coverage,"tracks":(try? JSONSerialization.jsonObject(with:tracks)) ?? [],"points":(try? JSONSerialization.jsonObject(with:points)) ?? [],"selected":model.selected ?? "","focusedAnchorID":model.focusedAnchorID ?? "","hovered":model.hovered ?? "","duration":model.duration,"hasVideo":model.videoURL != nil,"fit":model.fitID,"camera":camera ?? [:]]
            if let data=try? JSONSerialization.data(withJSONObject:dict,options:.sortedKeys),let json=String(data:data,encoding:.utf8),json != previous { previous=json;web?.evaluateJavaScript("window.update(\(json))") }
            lastState = state
            }
            let p=model.previewTime.flatMap { Geometry.interpolate(model.rendered,at:$0) }
            let value=p.map { "{\"lat\":\($0.lat),\"lng\":\($0.lng)}" } ?? "null"
            if value != lastCursor { lastCursor=value;web?.evaluateJavaScript("window.cursorAt(\(value))") }
        }
        func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
            guard let d=message.body as? [String:Any],let type=d["type"] as? String else { return }
            if type == "camera", let lat=d["lat"] as? Double, let lng=d["lng"] as? Double, let zoom=d["zoom"] as? Double {
                UserDefaults.standard.set(["lat":lat,"lng":lng,"zoom":zoom],forKey:cameraKey)
                return
            }
            if type == "mapType", let satellite=d["satellite"] as? Bool {
                UserDefaults.standard.set(satellite,forKey:"creatorGoogleSatellite")
                return
            }
            handle(d,type:type)
        }
        private var sharesDashboardCamera: Bool { dashboard || model.points.isEmpty }
        private var cameraKey: String { "mapCamera.\(sharesDashboardCamera ? "dashboard" : "creator")" }
        private func cameraForMap(google: Bool) -> [String:Double]? {
            let defaults=UserDefaults.standard
            if let saved=defaults.dictionary(forKey:cameraKey) as? [String:Double] { return saved }
            guard !sharesDashboardCamera else { return nil }
            // Migrate the last active provider's saved view into one shared creator camera.
            let preferred=google ? "google" : "osm", fallback=google ? "osm" : "google"
            let legacy=defaults.dictionary(forKey:"mapCamera.creator.\(preferred)") as? [String:Double]
                ?? defaults.dictionary(forKey:"mapCamera.creator.\(fallback)") as? [String:Double]
            if let legacy { defaults.set(legacy,forKey:cameraKey) }
            return legacy
        }
        func handle(_ d: [String:Any], type: String) {
            let id=d["id"] as? String ?? ""
            switch type {
            case "ready": ready=true;update()
            case "hover": model.hovered=id.isEmpty ? nil : id
            case "select": model.selected=id.isEmpty ? nil : id
            case "focusAnchor": model.focusedAnchorID=id;model.controls=true
            case "preview": if let t=d["time"] as? Double { model.preview(at:t) }
            case "previewEnd": model.previewTime=nil;model.seek(model.time)
            case "seek": if let t=d["time"] as? Double { model.seek(t) }
            case "delete":
                if let i=model.points.firstIndex(where:{$0.id==id}) {
                    model.recordUndo()
                    model.points.remove(at:i)
                    if model.points.count<2 { model.finished=false }
                }
            case "move":
                lastCursor=""
                if let i=model.points.firstIndex(where:{$0.id==id}),let lat=d["lat"] as? Double,let lng=d["lng"] as? Double,model.points[i].lat != lat || model.points[i].lng != lng { model.recordUndo();model.points[i].lat=lat;model.points[i].lng=lng }
            case "add", "insert":
                guard let incomingLat=d["lat"] as? Double,let incomingLng=d["lng"] as? Double else { return }
                var lat=incomingLat,lng=incomingLng
                var t=type == "insert" ? (d["time"] as? Double ?? model.time) : model.time
                if type == "add", model.points.contains(where:{ abs($0.time-t)<0.02 }) {
                    t=(model.points.map(\.time).max() ?? t)+1
                    if model.videoURL == nil { model.duration=max(model.duration,t) }
                }
                if type == "insert",model.points.contains(where:{abs($0.time-t)<0.02}) {
                    let earlier=model.points.map(\.time).filter{$0<t-0.02}.max()
                    let later=model.points.map(\.time).filter{$0>t+0.02}.min()
                    if let earlier,let later { t=(earlier+later)/2 }
                    else if let earlier { t=(earlier+t)/2 }
                    else if let later { t=(t+later)/2 }
                }
                // If the click lands on an existing anchor time, move the time
                // between anchors and keep the new point on the current route.
                if type == "insert",let onRoute=Geometry.interpolate(model.rendered,at:t) {
                    lat=onRoute.lat;lng=onRoute.lng
                }
                model.recordUndo()
                if !model.importedGPX { model.filled=true }
                model.points.append(Point(lat:lat,lng:lng,time:t));model.points.sort { $0.time<$1.time }
            default: break
            }
        }
    }
}
import AVFoundation
