import SwiftUI
import AVKit

@main struct GPXCreatorApp: App {
    @StateObject private var model=AppModel()
    var body: some Scene { WindowGroup { ContentView(model:model).preferredColorScheme(.light).frame(minWidth:1000,minHeight:720) }.windowStyle(.hiddenTitleBar).commands { CommandGroup(replacing:.appSettings) { Button("Settings…") { model.settings=true }.keyboardShortcut(",") } } }
}
struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("dashboardWidth") var dashboardWidth=310.0
    @AppStorage("creatorWidth") var creatorWidth=290.0
    @State var resizeStart: Double?
    var body: some View {
        HStack(spacing:0) {
            VStack(spacing:20) {
                Image(systemName:"point.topleft.down.to.point.bottomright.curvepath").font(.system(size:24,weight:.bold)).foregroundStyle(.orange).padding(.top,30)
                nav("GPX Creator",icon:"point.3.connected.trianglepath.dotted",tab:0)
                nav("Path Dashboard",icon:"map",tab:1)
                Spacer()
                Button { model.settings=true } label: { Image(systemName:"gearshape").font(.system(size:21)).frame(width:50,height:45) }.buttonStyle(.plain).help("Settings").padding(.bottom,16)
            }.frame(width:84).background(Color(red:0.965,green:0.97,blue:0.98))
            Divider()
            VStack(spacing:0) {
                HStack {
                    VStack(alignment:.leading,spacing:3) { Text(model.tab==0 ? "GPX Creator" : "Path Dashboard").font(.system(size:21,weight:.semibold));Text(model.tab==0 ? "Turn your footage into a precise path" : "Your paths, in perspective").font(.system(size:12)).foregroundStyle(.secondary) }
                    Spacer()
                    if model.tab==1 { Button { model.choose(dashboard:true) } label: { Label("Import GPX",systemImage:"plus") }.buttonStyle(.borderedProminent).tint(.orange) }
                    else { Button { model.choose(dashboard:false) } label: { Label("GPX",systemImage:"doc.badge.plus") }; Button { model.choose(dashboard:false,video:true) } label: { Label("Video",systemImage:"video.badge.plus") };Button { model.controls.toggle() } label: { Image(systemName:"sidebar.right") }.help("Path controls") }
                }.padding(20).frame(height:83).background(.white)
                Divider()
                GeometryReader { geo in
                    HStack(spacing:0) {
                        if model.tab==1 {
                            ZStack(alignment:.topTrailing) { MapView(model:model,dashboard:true);Toggle("Street View coverage",isOn:$model.coverage).toggleStyle(.checkbox).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).padding(16) }
                            resize(width:$dashboardWidth,total:geo.size.width)
                            dashboard.frame(width:min(dashboardWidth,geo.size.width*0.5))
                        } else {
                            VStack(spacing:0) { video.frame(height:geo.size.height*0.5);Divider();ZStack(alignment:.bottomTrailing) { MapView(model:model,dashboard:false);Menu { Button("OpenStreetMap") { model.google=false }; Button("Google Maps") { model.google=true } } label: { Label(model.google ? "Google Maps" : "OpenStreetMap",systemImage:"square.3.layers.3d") }.menuStyle(.borderlessButton).fixedSize().padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:9)).padding(14) } }
                            if model.controls { resize(width:$creatorWidth,total:geo.size.width);creatorControls.frame(width:min(creatorWidth,geo.size.width*0.45)) }
                        }
                    }
                }
            }
        }.background(.white)
        .sheet(isPresented:$model.settings) { SettingsView(model:model) }
        .alert("Unable to complete action",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) { Button("OK") { model.error=nil } } message: { Text(model.error ?? "") }
    }
    func nav(_ title: String,icon: String,tab: Int) -> some View { Button { model.tab=tab } label: { VStack(spacing:7) { Image(systemName:icon).font(.system(size:21));Text(title).font(.system(size:10,weight:.medium)).multilineTextAlignment(.center) }.frame(width:72,height:66).foregroundStyle(model.tab==tab ? .orange : .secondary).background(model.tab==tab ? Color.orange.opacity(0.10) : .clear,in:RoundedRectangle(cornerRadius:12)) }.buttonStyle(.plain) }
    func resize(width: Binding<Double>,total: CGFloat) -> some View { Rectangle().fill(Color.gray.opacity(0.15)).frame(width:5).overlay(Rectangle().fill(Color.gray.opacity(0.45)).frame(width:1,height:35)).gesture(DragGesture(minimumDistance:0).onChanged { value in if resizeStart == nil { resizeStart=width.wrappedValue }; width.wrappedValue=max(240,min(total*0.5,(resizeStart ?? width.wrappedValue)-value.translation.width)) }.onEnded { _ in resizeStart=nil }).onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } } }
    var dashboard: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Text("IMPORTED PATHS").font(.system(size:11,weight:.semibold)).tracking(1.3);Spacer();Text("\(model.tracks.count)").foregroundStyle(.secondary) }.padding(20)
            Divider()
            ScrollViewReader { proxy in ScrollView { LazyVStack(spacing:6) {
                if model.tracks.isEmpty { VStack(spacing:12) { Image(systemName:"map").font(.largeTitle);Text("Your paths live here").font(.headline);Text("Import GPX files to see them on the map.").font(.caption).multilineTextAlignment(.center) }.foregroundStyle(.secondary).padding(30) }
                ForEach(model.tracks) { track in TrackRow(track:track,active:model.selected==track.id || model.hovered==track.id,select:{model.selected=track.id;model.fitID="";DispatchQueue.main.async {model.fitID=track.id}},delete:{model.tracks.removeAll {$0.id==track.id};model.persist()}).id(track.id) }
            }.padding(10) }.onChange(of:model.hovered) { _,id in if let id { withAnimation {proxy.scrollTo(id,anchor:.center)} } }.onChange(of:model.selected) { _,id in if let id {withAnimation {proxy.scrollTo(id,anchor:.center)}} } }
            Spacer(minLength:0)
            Text("Imported paths are saved in the app. Removing one leaves your original file untouched.").font(.caption).foregroundStyle(.secondary).padding(18)
        }.background(Color(red:0.985,green:0.987,blue:0.99))
    }
    var video: some View { VStack(spacing:0) {
        ZStack { Color(red:0.10,green:0.12,blue:0.15);if model.videoURL != nil { VideoPlayer(player:model.player) } else { VStack(spacing:12) { Image(systemName:"video").font(.system(size:36));Text("Bring your journey into view").font(.headline);Button("Open equirectangular video") {model.choose(dashboard:false,video:true)} }.foregroundStyle(.white.opacity(0.85)) } }
        HStack(spacing:12) { Button { if model.player.rate==0 { model.player.play() } else { model.player.pause() } } label: { Image(systemName:model.player.rate==0 ? "play.fill" : "pause.fill") }.buttonStyle(.plain);Text(clock(model.time)).monospacedDigit().font(.caption);TimelineView(model:model);Text(clock(model.duration)).monospacedDigit().font(.caption) }.padding(12).background(Color.white)
    } }
    var creatorControls: some View { VStack(alignment:.leading,spacing:18) {
        Text("PATH CONTROLS").font(.system(size:11,weight:.semibold)).tracking(1.3)
        Label("\(model.points.count) manual anchors",systemImage:"mappin.and.ellipse").font(.headline)
        Text("Scrub the video, then click the map to pin that moment. Drag an anchor to refine its position.").font(.callout).foregroundStyle(.secondary)
        Divider()
        Button { model.filled=true } label: { Label("Fill points · 1 per second",systemImage:"point.3.filled.connected.trianglepath.dotted") }.buttonStyle(.borderedProminent).tint(.orange).disabled(model.points.count<2)
        if model.filled {Text("\(model.rendered.count) total points · updates automatically").font(.caption).foregroundStyle(.secondary)}
        Text("Double-click to finish. Click the finish flag to extend. Right-click an anchor to delete. Click the orange line to insert an anchor.").font(.caption).foregroundStyle(.secondary)
        Divider()
        if let url=model.videoURL {Label(url.lastPathComponent,systemImage:"video").font(.caption).lineLimit(2)}
        if let url=model.gpxURL {Label(url.lastPathComponent,systemImage:"doc").font(.caption).lineLimit(2)}
        Spacer()
        Button {model.export()} label: {Label("Export GPX",systemImage:"square.and.arrow.up").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent).tint(.orange).disabled(model.points.isEmpty)
    }.padding(20).background(Color(red:0.985,green:0.987,blue:0.99)) }
    func clock(_ t: Double) -> String { let s=Int(max(0,t));return String(format:"%02d:%02d:%02d",s/3600,(s/60)%60,s%60) }
}
struct TrackRow: View {
    let track: Track;let active: Bool;let select:()->Void;let delete:()->Void
    @State var hover=false
    var body: some View { HStack(spacing:10) { Image(systemName:"point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(active ? .orange : Color(red:0.08,green:0.23,blue:0.47));VStack(alignment:.leading,spacing:5) {Text(track.name).font(.system(size:13,weight:.medium)).lineLimit(2);Text(track.date.formatted(date:.abbreviated,time:.shortened)).font(.system(size:11)).foregroundStyle(.secondary)};Spacer();if hover {Button(action:delete) {Image(systemName:"trash").foregroundStyle(.secondary)}.buttonStyle(.plain).help("Remove imported copy")} }.padding(12).background(active ? Color.orange.opacity(0.12) : hover ? Color.gray.opacity(0.06) : .clear,in:RoundedRectangle(cornerRadius:10)).contentShape(Rectangle()).onTapGesture(perform:select).onHover {hover=$0} }
}
struct SettingsView: View {
    @ObservedObject var model: AppModel;@State var entry="";@State var saved=false
    var body: some View { VStack(alignment:.leading,spacing:20) {Text("Map settings").font(.title2.bold());Text(model.key.isEmpty ? "Enter your Google Maps demo key." : "A Google Maps key is securely saved in Keychain.").foregroundStyle(.secondary);SecureField("Enter a new Google Maps key",text:$entry).textFieldStyle(.roundedBorder);Text("The saved key is never displayed here. Google Maps uses it to load the map and Street View coverage.").font(.caption).foregroundStyle(.secondary);HStack {Spacer();Button("Done") {model.settings=false};Button("Save key") { do {try KeyStore.save(entry.trimmingCharacters(in:.whitespacesAndNewlines));model.key=entry.trimmingCharacters(in:.whitespacesAndNewlines);entry="";model.settings=false} catch {model.error=error.localizedDescription} }.buttonStyle(.borderedProminent).disabled(entry.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)} }.padding(28).frame(width:440) }
}
