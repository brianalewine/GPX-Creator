import XCTest
import WebKit
@testable import GPXCreator

// Explicit opt-in: exercises the real WebKit layout and Google renderer.
final class LiveMapTests: XCTestCase {
    @MainActor func testReal3DOverlayLayout() async throws {
        guard ProcessInfo.processInfo.environment["GPX_LIVE_MAP_TESTS"] == "1" else { throw XCTSkip("Live Google test is opt-in") }
        let key=KeyStore.library().selectedValue
        guard !key.isEmpty else { throw XCTSkip("No selected Google key") }
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/GPXCreator/Resources/map.html")
        let config=WKWebViewConfiguration()
        let bridge=MapBridge();config.userContentController.add(bridge,name:"bridge")
        let web=MapWebView(frame:NSRect(x:0,y:0,width:1000,height:700),configuration:config)
        let window=NSWindow(contentRect:web.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=web;window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        defer { window.orderOut(nil);config.userContentController.removeScriptMessageHandler(forName:"bridge") }
        web.loadFileURL(source,allowingReadAccessTo:source.deletingLastPathComponent())
        for _ in 0..<100 { if bridge.ready { break };try await Task.sleep(for:.milliseconds(100)) }
        XCTAssertTrue(bridge.ready)
        let state:[String:Any] = ["google":true,"google3D":true,"dashboard":false,"key":key,"points":[["id":"a","lat":42.3600,"lng":-71.0600,"time":0,"manual":true],["id":"b","lat":42.3610,"lng":-71.0580,"time":60,"manual":true]],"tracks":[],"camera":["lat":42.3605,"lng":-71.0590,"zoom":17],"duration":60,"fit":"","hasVideo":false]
        _=try await web.evaluateJavaScript("window.requestAnimationFrame=callback=>setTimeout(()=>callback(performance.now()),16);window.cancelAnimationFrame=clearTimeout;void 0")
        web.usesGoogle3D=true
        let data=try JSONSerialization.data(withJSONObject:state)
        _=try await web.evaluateJavaScript("window.update(\(String(decoding:data,as:UTF8.self)));void 0")
        var report:[String:Any]=[:]
        for _ in 0..<100 {
            report=(try await web.evaluateJavaScript("({notice:document.getElementById('notice').textContent,hasLine:!!creatorLine,points:creatorLine?._screenLine?creatorLine.screenPoints().filter(Boolean).length:0,separation:(()=>{const p=creatorLine?.screenPoints().filter(Boolean)||[];return p.length>1?Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y):0})(),markerClass:typeof google3DLibrary?.MarkerElement})")) as? [String:Any] ?? [:]
            if (report["separation"] as? Double ?? 0)>10 { break }
            try await Task.sleep(for:.milliseconds(200))
        }
        print("Live 3D layout:",report)
        XCTAssertEqual(report["points"] as? Int,2)
        XCTAssertGreaterThan(report["separation"] as? Double ?? 0,10)
        _=try await web.evaluateJavaScript("map.tilt=70;map.heading=35;void 0")
        try await Task.sleep(for:.seconds(1))
        let hover=(try await web.evaluateJavaScript("(()=>{const p=creatorLine.screenPoints(),x=(p[0].x+p[1].x)/2,y=(p[0].y+p[1].y)/2;previewPointer({clientX:x,clientY:y});return {time:nearestScreenPath3D(x,y)?.time,expectedTime:60*(p[0].depth||1)/((p[0].depth||1)+(p[1].depth||1)),width:String(map.querySelector('gmp-polyline-3d').strokeWidth),hiddenUI:map.defaultUIHidden}})()")) as? [String:Any] ?? [:]
        XCTAssertEqual(try XCTUnwrap(hover["time"] as? Double),try XCTUnwrap(hover["expectedTime"] as? Double),accuracy:0.0001)
        XCTAssertEqual(hover["width"] as? String,"3.5")
        XCTAssertEqual(hover["hiddenUI"] as? Bool,true)
        try await Task.sleep(for:.milliseconds(100))
        let dot=(try await web.evaluateJavaScript("cursor?.firstElementChild?.getBoundingClientRect().width||0")) as? Double ?? 0
        XCTAssertEqual(dot,12)
        let snapshot=try await web.takeSnapshot(configuration:nil)
        if let tiff=snapshot.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) { try png.write(to:URL(fileURLWithPath:"/tmp/gpx-live-3d.png")) }
        bridge.messages.removeAll()
        _=try await web.evaluateJavaScript("""
        (()=>{const r=pointMarkers[0].marker.firstElementChild.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2,c=document.getElementById('map');
        c.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,clientX:x,clientY:y,button:0,pointerId:7}));
        document.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:x+20,clientY:y+15,pointerId:7}));
        document.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,clientX:x+20,clientY:y+15,pointerId:7}));return null})()
        """)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(bridge.messages.filter{$0=="move"}.count,1)
        XCTAssertFalse(bridge.messages.contains("insertDragged"))
        let anchorCount=try await web.evaluateJavaScript("state.points.length")
        XCTAssertEqual(anchorCount as? Int,2)
        bridge.messages.removeAll()
        _=try await web.evaluateJavaScript("(()=>{const r=pointMarkers[1].marker.firstElementChild.getBoundingClientRect();window.nativeMapContextMenu(r.left+r.width/2,r.top+r.height/2);return null})()")
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(bridge.messages.filter{$0=="delete"}.count,1)
        // Deliver actual AppKit mouse events through the WKWebView, including
        // modifier changes while the mouse button remains down.
        func mouse(_ type: NSEvent.EventType,x: CGFloat,y: CGFloat,flags: NSEvent.ModifierFlags=[],clicks: Int=1) throws {
            let local=NSPoint(x:x,y:web.isFlipped ? y : web.bounds.height-y)
            let point=web.convert(local,to:nil)
            let event=try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:clicks,pressure:1))
            if type == .leftMouseDown { web.mouseDown(with:event) }
            else if type == .leftMouseUp { web.mouseUp(with:event) }
            else if type == .mouseMoved { web.mouseMoved(with:event) }
            else { web.mouseDragged(with:event) }
        }
        try mouse(.leftMouseDown,x:700,y:450)
        try mouse(.leftMouseDragged,x:710,y:440,flags:.shift)
        try await Task.sleep(for:.milliseconds(100))
        let shifted=(try await web.evaluateJavaScript("({heading:map.heading,tilt:map.tilt,lat:map.center.lat,lng:map.center.lng})")) as! [String:Double]
        try mouse(.leftMouseDragged,x:720,y:430,flags:.command)
        try await Task.sleep(for:.milliseconds(100))
        let commanded=(try await web.evaluateJavaScript("({heading:map.heading,tilt:map.tilt,lat:map.center.lat,lng:map.center.lng})")) as! [String:Double]
        XCTAssertEqual(commanded["heading"]! - shifted["heading"]!,3,accuracy:0.2)
        XCTAssertEqual(commanded["tilt"]! - shifted["tilt"]!,2.5,accuracy:0.2)
        try mouse(.leftMouseDragged,x:730,y:440)
        try mouse(.leftMouseUp,x:730,y:440)
        try await Task.sleep(for:.milliseconds(100))
        let resumed=(try await web.evaluateJavaScript("({heading:map.heading,tilt:map.tilt,lat:map.center.lat,lng:map.center.lng})")) as! [String:Double]
        XCTAssertEqual(resumed["heading"]!,commanded["heading"]!,accuracy:0.2)
        XCTAssertEqual(resumed["tilt"]!,commanded["tilt"]!,accuracy:0.2)
        XCTAssertNotEqual(resumed["lat"],commanded["lat"])
        // Google does not emit terrain hits for manually delivered AppKit
        // clicks in this XCTest harness, including with native gestures only.
        // Terrain-hit insertion remains covered by the production-handler suite.
        // Sweep anchors across viewport edges at steep tilts. The route must
        // never substitute the flat-ground estimate for Google's DOM position.
        let geographicPath=try await web.evaluateJavaScript("JSON.stringify(map.querySelector('gmp-polyline-3d').path)") as? String
        for (offset,tilt) in [(0.0,50.0),(0.008,75.0),(-0.008,80.0),(0.0,60.0)] {
            _=try await web.evaluateJavaScript("map.center={lat:42.3605,lng:-71.059+\(offset),altitude:map.center.altitude};map.tilt=\(tilt);void 0")
            try await Task.sleep(for:.milliseconds(200))
            let mismatches=try await web.evaluateJavaScript("""
            (()=>{const points=creatorLine.screenPoints();return points.filter(Boolean).filter(p=>{
            const probe=[...map.children].find(m=>{if(m.firstElementChild?.style.width!=='2px')return false;try{return m.position&&Math.abs(m.position.lat-p.point.lat)<1e-9&&Math.abs(m.position.lng-p.point.lng)<1e-9}catch(_){return false}});
            if(!probe)return true;const r=probe.firstElementChild.getBoundingClientRect();return Math.abs(p.x-r.left-r.width/2)>.01||Math.abs(p.y-r.top-r.height/2)>.01}).length})()
            """)
            XCTAssertEqual(mismatches as? Int,0)
            let currentPath=try await web.evaluateJavaScript("JSON.stringify(map.querySelector('gmp-polyline-3d').path)") as? String
            XCTAssertEqual(currentPath,geographicPath)
        }
        web.usesGoogle3D=false
        // Switch the same WebKit view to satellite and exercise Google's own
        // overlay event dispatcher, ensuring insertion cannot also append.
        var satelliteState=state;satelliteState["google3D"]=false;satelliteState["googleSatellite"]=true
        let satelliteData=try JSONSerialization.data(withJSONObject:satelliteState)
        _=try await web.evaluateJavaScript("window.update(\(String(decoding:satelliteData,as:UTF8.self)));void 0")
        for _ in 0..<100 {
            if (try await web.evaluateJavaScript("provider==='google'&&!updateRunning&&!!creatorHitLine&&!!map.getProjection()")) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        bridge.messages.removeAll()
        _=try await web.evaluateJavaScript("""
        (()=>{const p=pointMarkers[0].point,pr=map._gpxOverlay.getProjection(),pixel=pr.fromLatLngToContainerPixel(new google.maps.LatLng(p.lat,p.lng)),r=map.getDiv().getBoundingClientRect(),x=r.left+pixel.x,y=r.top+pixel.y,c=document.getElementById('map');
        c.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,clientX:x,clientY:y,button:0,pointerId:9}));
        document.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:x+25,clientY:y+20,pointerId:9}));
        document.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,clientX:x+25,clientY:y+20,pointerId:9}));return null})()
        """)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(bridge.messages.filter{$0=="move"}.count,1)
        XCTAssertFalse(bridge.messages.contains("insertDragged"))
        bridge.messages.removeAll()
        _=try await web.evaluateJavaScript("google.maps.event.trigger(creatorHitLine,'dblclick',{latLng:new google.maps.LatLng(42.3605,-71.059),stop(){}});void 0")
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(bridge.messages.filter{$0=="insert"}.count,1)
        XCTAssertFalse(bridge.messages.contains("add"))
        satelliteState["googleSatellite"]=false
        let flatData=try JSONSerialization.data(withJSONObject:satelliteState)
        _=try await web.evaluateJavaScript("window.update(\(String(decoding:flatData,as:UTF8.self)));void 0")
        for _ in 0..<100 {
            if (try await web.evaluateJavaScript("provider==='google'&&!updateRunning&&map.getRenderingType()==='RASTER'")) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        let flatRenderer=try await web.evaluateJavaScript("map.getRenderingType()")
        XCTAssertEqual(flatRenderer as? String,"RASTER")
        let mapTypeControl=try await web.evaluateJavaScript("map.get('mapTypeControl')")
        XCTAssertEqual(mapTypeControl as? Bool,false)

    }
}
@MainActor private final class MapBridge: NSObject, WKScriptMessageHandler {
    var ready=false
    var messages:[String]=[]
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) { if let type=(message.body as? [String:Any])?["type"] as? String { messages.append(type);if type == "ready" { ready=true } } }
}
