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
        func update() {
            guard ready else { return }
            let encoder=JSONEncoder(); guard let tracks=try? encoder.encode(model.tracks),let points=try? encoder.encode(model.rendered) else { return }
            let dict: [String:Any] = ["dashboard":dashboard,"google":dashboard || model.google,"key":model.key,"coverage":model.coverage,"tracks":(try? JSONSerialization.jsonObject(with:tracks)) ?? [],"points":(try? JSONSerialization.jsonObject(with:points)) ?? [],"selected":model.selected ?? "","hovered":model.hovered ?? "","finished":model.finished,"fit":model.fitID]
            if let data=try? JSONSerialization.data(withJSONObject:dict,options:.sortedKeys),let json=String(data:data,encoding:.utf8),json != previous { previous=json;web?.evaluateJavaScript("window.update(\(json))") }
            let p=Geometry.interpolate(model.rendered,at:model.previewTime ?? model.time)
            let value=p.flatMap { try? encoder.encode($0) }.flatMap { String(data:$0,encoding:.utf8) } ?? "null"
            if value != lastCursor { lastCursor=value;web?.evaluateJavaScript("window.cursorAt(\(value))") }
        }
        func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
            guard let d=message.body as? [String:Any],let type=d["type"] as? String else { return }
            let id=d["id"] as? String ?? ""
            switch type {
            case "ready": ready=true;update()
            case "hover": model.hovered=id.isEmpty ? nil : id
            case "select": model.selected=id.isEmpty ? nil : id
            case "preview": if let t=d["time"] as? Double { model.previewTime=t;model.player.seek(to:CMTime(seconds:t,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) }
            case "previewEnd": model.previewTime=nil;model.seek(model.time)
            case "seek": if let t=d["time"] as? Double { model.seek(t) }
            case "unfinish": model.finished=false
            case "delete": model.points.removeAll { $0.id==id }
            case "move": if let i=model.points.firstIndex(where:{$0.id==id}),let lat=d["lat"] as? Double,let lng=d["lng"] as? Double { model.points[i].lat=lat;model.points[i].lng=lng }
            case "add", "insert":
                guard !model.finished,let lat=d["lat"] as? Double,let lng=d["lng"] as? Double else { return }
                let t=type == "insert" ? (d["time"] as? Double ?? model.time) : model.time
                model.points.removeAll { abs($0.time-t)<0.02 }
                model.points.append(Point(lat:lat,lng:lng,time:t));model.points.sort { $0.time<$1.time };model.finished=d["finish"] as? Bool ?? false
            default: break
            }
        }
    }
}
import AVFoundation
