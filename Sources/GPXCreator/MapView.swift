import SwiftUI
import WebKit

// WKWebView does not consistently expose macOS magnification as DOM gestures.
// Forward it to the shared, cursor-anchored map pinch handlers instead.
final class MapWebView: WKWebView {
    private var pinchScale: CGFloat = 1
    private var pinching = false

    var historyShortcut: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if historyShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with:event)
    }
    private var contextMonitor: Any?
    var mapIsActive=true
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let contextMonitor { NSEvent.removeMonitor(contextMonitor);self.contextMonitor=nil }
        guard window != nil else { return }
        contextMonitor=NSEvent.addLocalMonitorForEvents(matching:[.rightMouseDown,.rightMouseUp,.leftMouseDown,.leftMouseUp]) { [weak self] event in
            guard let self,self.usesGoogle3D,self.mapIsActive,event.window===self.window,
                  event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) else { return event }
            let location=self.convert(event.locationInWindow,from:nil)
            guard self.bounds.contains(location) else { return event }
            let y=self.isFlipped ? location.y : self.bounds.height-location.y
            if event.type == .rightMouseUp || event.type == .leftMouseUp { return nil }
            self.evaluateJavaScript("window.nativeMapContextMenu?.(\(location.x),\(y))")
            return nil
        }
    }
    deinit { if let contextMonitor { NSEvent.removeMonitor(contextMonitor) } }
    var usesGoogle3D=false
    func mapMouseEvent(_ event: NSEvent) -> NSEvent { event }
    override func mouseDown(with event: NSEvent) {
        if usesGoogle3D,event.clickCount==2 {
            let location=convert(event.locationInWindow,from:nil)
            let y=isFlipped ? location.y : bounds.height-location.y
            evaluateJavaScript("window.nativeMapDoubleClick?.(\(location.x),\(y))")
        }
        // Consume the second native down so Google cannot start double-click zoom.
        // The shared camera projection resolves insertion without a terrain event.
        if !(usesGoogle3D && event.clickCount==2) { super.mouseDown(with:event) }
    }
    override func magnify(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let x = location.x
        let y = isFlipped ? location.y : bounds.height-location.y
        func forward(_ phase: String) {
            evaluateJavaScript("window.nativeMapPinch?.('\(phase)',\(pinchScale),\(x),\(y))")
        }
        if !pinching || event.phase.contains(.began) {
            pinching = true
            pinchScale = 1
            forward("gesturestart")
        }
        pinchScale *= max(0.01, 1+event.magnification)
        forward("gesturechange")
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            forward("gestureend")
            pinching = false
        }
    }
}

struct MapView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var dashboard: Bool
    func makeCoordinator() -> Coordinator { Coordinator(model,dashboard) }
    func makeNSView(context: Context) -> WKWebView {
        let config=WKWebViewConfiguration(); config.userContentController.add(context.coordinator,name:"bridge")
        let web=MapWebView(frame:.zero,configuration:config);web.usesGoogle3D = !dashboard && model.google && model.google3D;web.historyShortcut = { [weak model] event in model?.handleHistoryShortcut(event) ?? false };context.coordinator.web=web
        if let url=Bundle.module.url(forResource:"map",withExtension:"html",subdirectory:"Resources") { web.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }; return web
    }
    func updateNSView(_ view: WKWebView, context: Context) { (view as? MapWebView)?.mapIsActive = dashboard ? model.tab==1 : model.tab==0; (view as? MapWebView)?.usesGoogle3D = !dashboard && model.google && model.google3D;context.coordinator.update() }
    @MainActor class Coordinator: NSObject, WKScriptMessageHandler {
        let model: AppModel; let dashboard: Bool; weak var web: WKWebView?; var ready=false; var previous=""; var lastCursor=""; var lastLock=""; var handledAbort=false
        init(_ model: AppModel,_ dashboard: Bool) { self.model=model;self.dashboard=dashboard }
        private struct MapState: Equatable {
            let tracksRevision: Int
            let pathRevision: Int
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
            let importedGPX: Bool
            let fit: String
            let camera: [String:Double]?
        }
        private struct MapTrack: Encodable {
            let id: String
            let points: [Point]
            let visible: Bool
        }
        private var loadedKey: String?
        private var lastState: MapState?
        func update() {
            if let loadedKey, loadedKey != model.key {
                self.loadedKey=model.key
                ready=false;previous="";lastState=nil;lastCursor="";lastLock=""
                web?.reload()
                return
            }
            loadedKey=model.key
            if model.renderingAborted && !handledAbort {
                handledAbort=true;ready=false;previous="";lastState=nil;lastCursor="";lastLock=""
                web?.reload();return
            }
            if !model.renderingAborted { handledAbort=false }
            guard ready else { return }
            let google=dashboard ? model.dashboardGoogle : model.google
            let osmSatellite=dashboard ? model.dashboardEsriSatellite : model.creatorEsriSatellite
            let camera=cameraForMap(google:google)
            let google3D = !dashboard && model.google3D
            let googleSatellite = dashboard ? model.dashboardGoogleSatellite : model.creatorGoogleSatellite
            let mapFit = !dashboard && model.tracks.contains(where: { $0.id == model.fitID }) ? "" : model.fitID
            let state = MapState(tracksRevision:model.tracksRevision,pathRevision:dashboard ? 0 : model.pathRevision,google:google,osmSatellite:osmSatellite,google3D:google3D,googleSatellite:googleSatellite,key:model.key,coverage:dashboard && model.coverage,selected:model.selected,focusedAnchorID:model.focusedAnchorID,hovered:model.hovered,duration:model.duration,hasVideo:model.videoURL != nil,importedGPX:model.importedGPX,fit:mapFit,camera:camera)
            let encoder=JSONEncoder()
            if state != lastState {
            let mapTracks=model.renderingAborted ? [] : model.tracks.map { MapTrack(id:$0.id,points:$0.points,visible:$0.isVisible) }
            guard let tracks=try? encoder.encode(mapTracks),let points=try? encoder.encode(dashboard || model.renderingAborted ? [] : model.rendered) else { return }
            let dict: [String:Any] = ["dashboard":dashboard,"google":google,"osmSatellite":osmSatellite,"google3D":google3D,"googleSatellite":googleSatellite,"key":model.key,"coverage":dashboard && model.coverage,"tracks":(try? JSONSerialization.jsonObject(with:tracks)) ?? [],"points":(try? JSONSerialization.jsonObject(with:points)) ?? [],"anchorCount":model.points.count,"selected":model.selected ?? "","focusedAnchorID":model.focusedAnchorID ?? "","hovered":model.hovered ?? "","duration":model.duration,"hasVideo":model.videoURL != nil,"importedGPX":model.importedGPX,"loadID":model.currentLoadID,"fit":mapFit,"camera":camera ?? [:]]
            if let data=try? JSONSerialization.data(withJSONObject:dict,options:.sortedKeys),let json=String(data:data,encoding:.utf8),json != previous { previous=json;web?.evaluateJavaScript("window.update(\(json))") }
            lastState = state
            }
            let cursorTime=model.previewTime ?? model.lockedPreviewTime ?? (model.videoURL != nil && model.player.rate != 0 ? model.time : nil)
            let locked=model.lockedPreviewTime.flatMap { Geometry.interpolateSorted(model.rendered,at:$0) }
            let lockValue=locked.map { "{\"lat\":\($0.lat),\"lng\":\($0.lng)}" } ?? "null"
            if lockValue != lastLock { lastLock=lockValue;web?.evaluateJavaScript("window.setLockedPreview(\(lockValue))") }
            let p=cursorTime.flatMap { Geometry.interpolateSorted(model.rendered,at:$0) }
            let value=p.map { "{\"lat\":\($0.lat),\"lng\":\($0.lng)}" } ?? "null"
            if value != lastCursor { lastCursor=value;web?.evaluateJavaScript("window.cursorAt(\(value),true)") }
        }
        func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
            guard let d=message.body as? [String:Any],let type=d["type"] as? String else { return }
            if type == "camera", let lat=d["lat"] as? Double, let lng=d["lng"] as? Double, let zoom=d["zoom"] as? Double {
                var camera=["lat":lat,"lng":lng,"zoom":zoom]
                for field in ["range3D","height3D","fov3D","altitude3D"] {
                    if let value=d[field] as? Double,value.isFinite { camera[field]=value }
                }
                UserDefaults.standard.set(camera,forKey:cameraKey)
                return
            }
            if type == "mapType", let satellite=d["satellite"] as? Bool {
                if dashboard { model.dashboardGoogleSatellite=satellite } else { model.creatorGoogleSatellite=satellite }
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
            case "rendered": model.mapDidRender(loadID:d["loadID"] as? String ?? "")
            case "hover": model.hovered=id.isEmpty ? nil : id
            case "select":
                model.selected=id.isEmpty ? nil : id
                if dashboard,!id.isEmpty {
                    model.fitID=""
                    DispatchQueue.main.async { [weak model] in model?.fitID=id }
                }
            case "focusAnchor": model.focusedAnchorID=id;model.lockedPreviewTime=nil;model.previewTime=nil;model.controls=true
            case "preview": if let t=d["time"] as? Double { model.preview(at:t) }
            case "previewEnd": model.previewTime=model.lockedPreviewTime;model.seek(model.time)
            case "lockPreview": if model.focusedAnchorID == nil,let t=d["time"] as? Double { model.lockedPreviewTime=t;model.previewTime=t }
            case "unlockPreview": model.lockedPreviewTime=nil;model.previewTime=nil
            case "escape": model.escapeSelection()
            case "undo": model.undo()
            case "redo": model.redo()
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
            case "add", "insert", "insertDragged":
                guard let incomingLat=d["lat"] as? Double,let incomingLng=d["lng"] as? Double else { return }
                var lat=incomingLat,lng=incomingLng
                var editedDuration=model.duration
                var t=type != "add" ? (d["time"] as? Double ?? model.time) : model.time
                if type == "add", model.points.contains(where:{ abs($0.time-t)<0.02 }) {
                    t=(model.points.map(\.time).max() ?? t)+1
                    if model.videoURL == nil { editedDuration=max(editedDuration,t) }
                }
                if type != "add",model.points.contains(where:{abs($0.time-t)<0.02}) {
                    let earlier=model.points.map(\.time).filter{$0<t-0.02}.max()
                    let later=model.points.map(\.time).filter{$0>t+0.02}.min()
                    if let earlier,let later { t=(earlier+later)/2 }
                    else if let earlier { t=(earlier+t)/2 }
                    else if let later { t=(t+later)/2 }
                }
                // If the click lands on an existing anchor time, move the time
                // between anchors and keep the new point on the current route.
                if type == "insert",let onRoute=Geometry.interpolateSorted(model.rendered,at:t) {
                    lat=onRoute.lat;lng=onRoute.lng
                }
                model.recordUndo()
                model.duration=editedDuration
                if !model.importedGPX { model.filled=true }
                model.points.append(Point(lat:lat,lng:lng,time:t));model.points.sort { $0.time<$1.time }
            default: break
            }
        }
    }
}
import AVFoundation
