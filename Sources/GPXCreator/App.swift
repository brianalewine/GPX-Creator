import SwiftUI
import AVKit
import AppKit

enum AppRuntime {
    // SwiftPM/XCTest loads this executable into its test runner. Test failures
    // belong in assertions and logs, never in modal alerts on the desktop.
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@main struct GPXCreatorApp: App {
    @NSApplicationDelegateAdaptor(GPXApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model=AppModel()
    @StateObject private var videoTools=VideoToolsModel()
    var body: some Scene { WindowGroup { ContentView(model:model,videoTools:videoTools).preferredColorScheme(.light).frame(minWidth:1000,minHeight:720) }.windowStyle(.hiddenTitleBar).commands { CommandGroup(replacing:.undoRedo) { Button("Undo") { model.undo() }.keyboardShortcut("z",modifiers:.control).disabled(!model.canUndo);Button("Redo") { model.redo() }.keyboardShortcut("z",modifiers:[.control,.shift]).disabled(!model.canRedo) ;Divider();Button("Clear History") { model.clearHistory() }.disabled(!model.canUndo && !model.canRedo) };CommandGroup(replacing:.appSettings) { Button("Settings…") { model.settings=true }.keyboardShortcut(",") } } }
}
struct WindowControlsPositioner: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowControlsView { WindowControlsView() }
    func updateNSView(_ view: WindowControlsView,context: Context) {}
}
final class WindowControlsView: NSView {
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .white
        // Host native AppKit buttons in the visible toolbar, outside titlebar clipping.
        subviews.forEach { $0.removeFromSuperview() }
        let types: [NSWindow.ButtonType] = [.closeButton,.miniaturizeButton,.zoomButton]
        let actions = [#selector(NSWindow.performClose(_:)),#selector(NSWindow.performMiniaturize(_:)),#selector(NSWindow.toggleFullScreen(_:))]
        for (index,type) in types.enumerated() {
            window.standardWindowButton(type)?.isHidden = true
            guard let button = NSWindow.standardWindowButton(type,for:window.styleMask) else { continue }
            button.target = window
            button.action = actions[index]
            button.frame = NSRect(x:6 + CGFloat(index)*23,y:15,width:14,height:14)
            addSubview(button)
        }
    }
}
// One continuous material behind the toolbar and both sidebars.
struct WindowGlassBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            WindowMaterialBackdrop()
                .glassEffect(.regular.tint(.white.opacity(0.65)), in:Rectangle())
                .overlay(.white.opacity(0.78))
        } else {
            WindowMaterialBackdrop().overlay(.white.opacity(0.9))
        }
    }
}

struct WindowMaterialBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named:.aqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct WorkspaceGlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular,in:RoundedRectangle(cornerRadius:14,style:.continuous))
                } else {
                    RoundedRectangle(cornerRadius:14,style:.continuous).fill(.regularMaterial)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))
            .overlay {
                RoundedRectangle(cornerRadius:14,style:.continuous)
                    .strokeBorder(.white.opacity(0.65),lineWidth:0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color:.black.opacity(0.08),radius:3,y:1)
    }
}

struct IconSquareButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        IconSquareButtonBody(configuration:configuration,selected:selected)
    }

    private struct IconSquareButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Color.orange.opacity(configuration.isPressed ? 0.24 : hovering ? 0.18 : selected ? 0.10 : 0),in:RoundedRectangle(cornerRadius:12))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration:0.12),value:hovering)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingMapLayers=false
    @ObservedObject var videoTools: VideoToolsModel
    @AppStorage("dashboardWidth") var dashboardWidth=310.0
    @AppStorage("creatorWidth") var creatorWidth=290.0
    @State var resizeStart: Double?
    @AppStorage("videoHeightFraction") private var savedVideoHeightFraction=0.5
    @State private var videoHeightFraction=0.5
    @State private var videoResizeStart: Double?
    @FocusState private var recordingStartFocused: Bool
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:8) {
                // Leave the native traffic lights unobstructed.
                WindowControlsPositioner().frame(width:88,height:44)
                Spacer()
                if let message=model.loadingMessage {
                    ProgressView().controlSize(.small)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Button { if model.tab == 2 { videoTools.choose() } else { model.choose(dashboard:model.tab==1) } } label: {
                    Image(systemName:"plus").frame(width:32,height:32).contentShape(Rectangle())
                }.buttonStyle(IconSquareButtonStyle()).disabled(model.tab == 2 && videoTools.loading).help(model.tab == 2 ? "Open video for Video Tools" : model.tab==1 ? "Import GPX" : "Import video or GPX")
                if model.tab==0 {
                    Button { withAnimation(.easeInOut(duration:0.25)) { model.controls.toggle() } } label: {
                        Image(systemName:"sidebar.right").frame(width:32,height:32).contentShape(Rectangle())
                    }.buttonStyle(IconSquareButtonStyle()).help("Path controls")
                }
            }.font(.system(size:17)).foregroundStyle(.secondary)
                .padding(.horizontal,10).frame(height:44)
            HStack(spacing:0) {
                VStack(spacing:8) {
                    nav("GPX Creator",icon:"point.3.filled.connected.trianglepath.dotted",tab:0)
                    nav("Path Dashboard",icon:"map",tab:1)
                    nav("Video Tools",icon:"film.stack",tab:2)
                    Spacer()
                    Button { model.settings=true } label: {
                        Image(systemName:"gearshape").font(.system(size:21)).frame(width:50,height:45)
                    }.buttonStyle(IconSquareButtonStyle()).help("Settings")
                    .popover(isPresented:$model.settings,arrowEdge:.trailing) {
                        SettingsView(model:model).background(WindowGlassBackground()).preferredColorScheme(.light)
                    }.padding(.bottom,12)
                }.padding(.top,8).frame(width:84)
                GeometryReader { geo in
                    ZStack {
                        VideoToolsView(model:videoTools).opacity(model.tab==2 ? 1 : 0).allowsHitTesting(model.tab==2).accessibilityHidden(model.tab != 2)
                        HStack(spacing:0) {
                            ZStack(alignment:.topTrailing) {
                                MapView(model:model,dashboard:true)
                                VStack(alignment:.trailing,spacing:8) {
                                    mapLayersMenu(dashboard:true)
                                    if model.dashboardGoogle {
                                        Button { model.coverage.toggle() } label: {
                                            HStack(spacing:8) {
                                                Image(systemName:model.coverage ? "checkmark.square.fill" : "square").foregroundStyle(model.coverage ? Color.accentColor : Color.secondary)
                                                Text("Street View coverage")
                                            }.modifier(MapControlSurface())
                                        }.buttonStyle(StableMapButtonStyle()).foregroundStyle(Color.primary).accessibilityValue(model.coverage ? "On" : "Off")
                                    }
                                }.padding(14)
                            }.modifier(WorkspaceGlassPanel())
                            resize(width:$dashboardWidth,total:geo.size.width)
                            dashboard.frame(width:min(dashboardWidth,geo.size.width*0.5))
                        }.opacity(model.tab==1 ? 1 : 0).allowsHitTesting(model.tab==1).accessibilityHidden(model.tab != 1)
                        HStack(spacing:0) {
                            VStack(spacing:0) {
                                video.frame(height:max(150,min(geo.size.height-125,geo.size.height*videoHeightFraction)))
                                videoDivider(total:geo.size.height)
                                ZStack(alignment:.topTrailing) {
                                    MapView(model:model,dashboard:false)
                                    mapLayersMenu(dashboard:false).padding(14)
                                }
                            }.modifier(WorkspaceGlassPanel())
                            HStack(spacing:0) {
                                resize(width:$creatorWidth,total:geo.size.width)
                                creatorControls.frame(width:min(creatorWidth,geo.size.width*0.45))
                            }
                            .frame(width:model.controls ? min(creatorWidth,geo.size.width*0.45)+10 : 0,alignment:.leading)
                            .clipped().opacity(model.controls ? 1 : 0)
                            .allowsHitTesting(model.controls)
                            .accessibilityHidden(!model.controls)
                            .animation(.easeInOut(duration:0.25),value:model.controls)
                        }.opacity(model.tab==0 ? 1 : 0).allowsHitTesting(model.tab==0).accessibilityHidden(model.tab != 0)
                    }
                }.padding(.bottom,8).padding(.trailing,8)
            }
        }.background(WindowGlassBackground()).ignoresSafeArea(.container,edges:.top)
        .onExitCommand { model.escapeSelection() }
        .onAppear { videoHeightFraction=savedVideoHeightFraction }
                .alert("Unable to complete action",isPresented:Binding(get:{!AppRuntime.isRunningTests && model.error != nil},set:{if !$0 {model.error=nil}})) { Button("OK") { model.error=nil } } message: { Text(model.error ?? "") }
    }
    func nav(_ title: String,icon: String,tab: Int) -> some View { Button { model.tab=tab } label: { VStack(spacing:7) { Image(systemName:icon).font(.system(size:21));Text(title).font(.system(size:10,weight:.medium)).multilineTextAlignment(.center) }.frame(width:72,height:66).foregroundStyle(model.tab==tab ? .orange : .secondary) }.buttonStyle(IconSquareButtonStyle(selected:model.tab==tab)) }
    func mapLayersMenu(dashboard: Bool) -> some View {
        Button { showingMapLayers.toggle() } label: {
            Image(systemName:"square.3.layers.3d")
                .font(.system(size:18))
                .modifier(MapControlSurface())
        }
        .buttonStyle(StableMapButtonStyle())
        .accessibilityLabel("Map layers")
        .popover(isPresented:$showingMapLayers,arrowEdge:.top) {
            VStack(alignment:.leading,spacing:6) {

            Button { showingMapLayers=false; if dashboard { model.dashboardGoogle=false;model.dashboardEsriSatellite=false } else { model.google=false;model.google3D=false;model.creatorEsriSatellite=false } } label: {
                HStack { if dashboard ? (!model.dashboardGoogle && !model.dashboardEsriSatellite) : (!model.google && !model.creatorEsriSatellite) { Image(systemName:"checkmark") };Text("OpenStreetMap") }
            }
            Button { showingMapLayers=false; if dashboard { model.dashboardGoogle=false;model.dashboardEsriSatellite=true } else { model.google=false;model.google3D=false;model.creatorEsriSatellite=true } } label: {
                HStack { if dashboard ? model.dashboardEsriSatellite : model.creatorEsriSatellite { Image(systemName:"checkmark") };Text("OpenStreetMap Satellite") }
            }
            Button { showingMapLayers=false; if dashboard { model.dashboardGoogleSatellite=false;model.dashboardGoogle=true;model.dashboardEsriSatellite=false } else { model.creatorGoogleSatellite=false;model.google=true;model.google3D=false;model.creatorEsriSatellite=false } } label: {
                HStack { if dashboard ? model.dashboardGoogle && !model.dashboardGoogleSatellite : model.google && !model.google3D && !model.creatorGoogleSatellite { Image(systemName:"checkmark") };Text("Google Maps") }
            }
            Button { showingMapLayers=false;
                if dashboard { model.dashboardGoogleSatellite=true;model.dashboardGoogle=true;model.dashboardEsriSatellite=false }
                else { model.creatorGoogleSatellite=true;model.google=true;model.google3D=false;model.creatorEsriSatellite=false }
            } label: {
                HStack { if dashboard ? model.dashboardGoogle && model.dashboardGoogleSatellite : model.google && !model.google3D && model.creatorGoogleSatellite { Image(systemName:"checkmark") };Text("Google Satellite") }
            }
            if !dashboard {
                Button { showingMapLayers=false; model.google=true;model.google3D=true;model.creatorEsriSatellite=false } label: {
                    HStack { if model.google3D { Image(systemName:"checkmark") };Text("Google Maps 3D") }
                }
            }

            }.buttonStyle(.borderless).padding(12)
        }
    }
    func resize(width: Binding<Double>,total: CGFloat) -> some View { Rectangle().fill(Color.clear).frame(width:10).contentShape(Rectangle()).overlay(Rectangle().fill(Color.gray.opacity(0.45)).frame(width:1,height:35)).gesture(DragGesture(minimumDistance:0,coordinateSpace:.global).onChanged { value in if resizeStart == nil { resizeStart=width.wrappedValue }; width.wrappedValue=max(240,min(total*0.5,(resizeStart ?? width.wrappedValue)-value.translation.width)) }.onEnded { _ in resizeStart=nil }).onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } } }
    func videoDivider(total: CGFloat) -> some View {
        Rectangle().fill(Color.clear).frame(height:4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.global).onChanged { value in
                if videoResizeStart == nil { videoResizeStart=max(150,min(total-125,videoHeightFraction*total)) }
                videoHeightFraction=max(150,min(total-125,(videoResizeStart ?? total*0.5)+value.translation.height))/max(1,total)
            }.onEnded { _ in videoResizeStart=nil; savedVideoHeightFraction=videoHeightFraction })
            .transaction { $0.animation=nil }
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .help("Drag to resize video and map")
    }
    var dashboard: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Text("IMPORTED PATHS").font(.system(size:11,weight:.semibold)).tracking(1.3);Spacer();Text("\(model.tracks.count)").foregroundStyle(.secondary) }.padding(20)
            Divider()
            ScrollViewReader { proxy in ScrollView { LazyVStack(spacing:6) {
                if model.tracks.isEmpty { VStack(spacing:12) { Image(systemName:"map").font(.largeTitle);Text("Import GPX files to see them on the map.").font(.caption).multilineTextAlignment(.center) }.foregroundStyle(.secondary).padding(30) }
                ForEach(model.tracks) { track in TrackRow(model:model,track:track,active:model.selected==track.id,select:{model.selected=track.id;model.fitID="";DispatchQueue.main.async {model.fitID=track.id}},edit:track.creatorState == nil ? nil : {model.editCreatorPathFromDashboard(id:track.id)},delete:{model.recordUndo();model.tracks.removeAll {$0.id==track.id};model.persist()}).id(track.id) }
            }.padding(10) }.onChange(of:model.hovered) { _,id in if let id { withAnimation {proxy.scrollTo(id,anchor:.center)} } }.onChange(of:model.selected) { _,id in if let id {withAnimation {proxy.scrollTo(id,anchor:.center)}} } }
            Spacer(minLength:0)
            Text("Imported paths are saved in the app. Removing one leaves your original file untouched.").font(.caption).foregroundStyle(.secondary).padding(18)
        }
    }
    var video: some View { VStack(spacing:0) {
        ZStack {
            if model.videoURL != nil {
                Color.black
                VideoPreview(player:model.player)
            } else {
                Color(red:0.97,green:0.975,blue:0.985)
                VStack(spacing:12) {
                    Image(systemName:"video").font(.system(size:36)).foregroundStyle(.secondary)
                    Button("Open equirectangular video") {model.choose(dashboard:false,video:true)}
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
            }

        }.clipped()
        if model.videoURL != nil {
            HStack(spacing:12) { Button { if model.player.rate==0 { model.player.play() } else { model.pauseVideo() } } label: { Image(systemName:model.player.rate==0 ? "play.fill" : "pause.fill") }.buttonStyle(.plain).keyboardShortcut(.space,modifiers:[]).help("Play or pause video (Space)");Text(clock(model.time)).monospacedDigit().font(.caption);TimelineView(model:model);Text(clock(model.duration)).monospacedDigit().font(.caption) }.padding(12).background(.white.opacity(0.96),in:RoundedRectangle(cornerRadius:12)).padding(4)
        }
    } }
    var creatorControls: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("IMPORTED FILES").font(.system(size:11,weight:.semibold)).tracking(1.3)
                Spacer()
                Text("\((model.videoURL == nil ? 0 : 1)+(model.gpxURL == nil ? 0 : 1))").foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:6) {
                    if let url=model.videoURL {
                        ImportedFileRow(url:url,icon:"video",select:{},delete:{model.clearVideo()})
                    }
                    if let url=model.gpxURL {
                        ImportedFileRow(url:url,icon:"point.topleft.down.to.point.bottomright.curvepath",select:{model.fitID=UUID().uuidString},delete:{model.clearPath()})
                    }
                    if model.videoURL == nil && model.gpxURL == nil {
                        Text("Import video or GPX files.").font(.caption).foregroundStyle(.secondary).padding(20)
                    }
                }.padding(10)
                if let id=model.focusedAnchorID,model.points.contains(where:{$0.id==id}) {
                    Divider()
                    AnchorDetailsEditor(model:model,anchorID:id).padding(20)
                }
                Divider()
                VStack(alignment:.leading,spacing:16) {
                    Text("PATH CONTROLS").font(.system(size:11,weight:.semibold)).tracking(1.3)
                    Label("\(model.points.count) manual anchors",systemImage:"mappin.and.ellipse").font(.headline)
                    Text("Scrub the video, then double-click the map to add an anchor. Drag an anchor to move it.").font(.callout).foregroundStyle(.secondary)
                    Picker("Path detail",selection:Binding(get:{model.samplesPerSecond},set:{model.setSamplesPerSecond($0)})) {
                        Label { Text("GPX · Anchors only") } icon: { Image(systemName:"point.3.filled.connected.trianglepath.dotted").foregroundStyle(.black) }.tag(0)
                        Label("Walking · 1 per sec",systemImage:"figure.walk").tag(1)
                        Label("Biking · 5 per sec",systemImage:"bicycle").tag(5)
                        Label("Driving · 10 per sec",systemImage:"car.fill").tag(10)
                    }.pickerStyle(.menu)
                    if !model.importedGPX && model.points.count>1 { Text(model.samplesPerSecond == 0 ? "\(model.rendered.count) anchor points · no added samples" : "\(model.rendered.count) total points · generated at \(model.samplesPerSecond) samples per second").font(.caption).foregroundStyle(.secondary) }
                    Text("Double-click an anchor to edit its coordinates. Right-click an anchor to delete. Double-click the blue line to insert an anchor.").font(.caption).foregroundStyle(.secondary)
                    if model.gpxURL == nil && !model.points.isEmpty {
                        Button { model.clearPath() } label: { Label("Clear path",systemImage:"trash").frame(maxWidth:.infinity,alignment:.leading).padding(10) }.buttonStyle(FlatButtonStyle())
                    }
                }.padding(20)
            }
            Spacer(minLength:0)
            VStack(spacing:8) {
                if model.videoURL != nil {
                    if model.recordingStart != nil {
                        HStack(spacing:10) {
                            Text("Video recording started")
                                .font(.body)
                            Spacer(minLength:0)
                            RecordingStartPicker(date:Binding(get:{model.recordingStart ?? Date()},set:{model.setRecordingStart($0)}))
                                .fixedSize()
                                .environment(\.colorScheme,.light)
                        }
                    } else if model.isLoadingRecordingStart {
                        HStack(spacing:8) {
                            ProgressView().controlSize(.small)
                            Text("Reading video recording time…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No recording time found in the video. Set it before exporting for Street View.").font(.caption).foregroundStyle(.secondary)
                        Button("Manually set start time") { model.recordingStart=Date() }
                    }
                }
                Button { model.saveCreatorPathToDashboard() } label: {
                    Label(model.editingTrackID == nil ? "Save to Path Dashboard" : "Update in Path Dashboard",systemImage:"square.and.arrow.down").frame(maxWidth:.infinity)
                }.buttonStyle(.bordered).disabled(model.points.isEmpty)
                Button {model.export()} label: {
                    Label(model.samplesPerSecond == 0 ? "Export anchors as GPX" : "Export GPX",systemImage:"square.and.arrow.up").frame(maxWidth:.infinity)
                }.buttonStyle(.borderedProminent).tint(.orange).disabled(model.points.isEmpty || (model.videoURL != nil && model.recordingStart == nil))
            }.padding(20)
        }
    }
    func clock(_ t: Double) -> String { let milliseconds=Int(max(0,t)*1000);return String(format:"%02d:%02d:%02d.%03d",milliseconds/3_600_000,(milliseconds/60_000)%60,(milliseconds/1_000)%60,milliseconds%1_000) }
}
struct RecordingStartPicker: View {
    @Binding var date: Date
    @State private var showingPicker=false
    @State private var yearText=""
    @FocusState private var yearFocused: Bool
    private var calendar: Calendar { .current }
    private var year: Binding<Int> {
        Binding(get:{calendar.component(.year,from:date)},set:{setCalendar(year:$0)})
    }
    private var month: Binding<Int> {
        Binding(get:{calendar.component(.month,from:date)},set:{setCalendar(month:$0)})
    }
    private func syncYear() { yearText=String(calendar.component(.year,from:date)) }
    private func commitYear() {
        if let value=Int(yearText.trimmingCharacters(in:.whitespaces)),(1...9999).contains(value) {
            setCalendar(year:value)
        }
        syncYear()
    }
    private func setCalendar(year: Int?=nil,month: Int?=nil) {
        var parts=calendar.dateComponents([.year,.month,.day,.hour,.minute,.second,.nanosecond],from:date)
        parts.year=min(9999,max(1,year ?? parts.year ?? 1))
        parts.month=month ?? parts.month
        let day=parts.day ?? 1
        parts.day=1
        guard let first=calendar.date(from:parts),let days=calendar.range(of:.day,in:.month,for:first) else { return }
        parts.day=min(day,days.count)
        if let value=calendar.date(from:parts) { date=value }
    }
    var body: some View {
        HStack(spacing:6) {
            RecordingDateField(date:$date,elements:.yearMonthDay)
                .fixedSize()
            RecordingDateField(date:$date,elements:.hourMinute)
                .fixedSize()
            Button { showingPicker.toggle() } label: {
                Image(systemName:"calendar").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose recording date")
            .help("Choose a date or jump to a different year")
            .popover(isPresented:$showingPicker,arrowEdge:.top) {
                VStack(spacing:12) {
                    HStack {
                        Picker("Month",selection:month) {
                            ForEach(1...12,id:\.self) { value in
                                Text(calendar.monthSymbols[value-1]).tag(value)
                            }
                        }.labelsHidden().frame(width:140)
                        TextField("Year",text:$yearText)
                            .textFieldStyle(.roundedBorder).frame(width:64)
                            .accessibilityLabel("Year")
                            .focused($yearFocused)
                            .onSubmit { commitYear();yearFocused=false }
                            .background(ClickAwayObserver(commit:{ yearFocused=false }))
                        Stepper("Year",value:year,in:1...9999).labelsHidden()
                    }
                    DatePicker("Recording date",selection:$date,displayedComponents:.date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .id(calendar.component(.year,from:date)*12+calendar.component(.month,from:date))
                }
                .padding(12)
                .environment(\.colorScheme,.light)
                .onAppear(perform:syncYear)
                .onChange(of:yearFocused) { _,focused in if !focused { commitYear() } }
                .onChange(of:date) { _,_ in if !yearFocused { syncYear() } }
                .onDisappear(perform:commitYear)
            }
        }
        .padding(.horizontal,7).padding(.vertical,4)
        .background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:6))
    }
}

// Separate numeric fields keep punctuation from forwarding clicks to a previously
// selected segment, as the native date control does.
struct RecordingDateField: View {
    @Binding var date: Date
    var elements: NSDatePicker.ElementFlags
    @State private var drafts: [Calendar.Component:String]=[:]
    @FocusState private var focused: Calendar.Component?
    private var components: [Calendar.Component] {
        elements == .hourMinute ? [.hour,.minute] : [.month,.day,.year]
    }
    private func formatted(_ component: Calendar.Component) -> String {
        String(format:component == .year ? "%04d" : "%02d",Calendar.current.component(component,from:date))
    }
    private func reload() {
        for component in components { drafts[component]=formatted(component) }
    }
    private func commit(_ component: Calendar.Component) {
        defer { drafts[component]=formatted(component) }
        guard let value=Int(drafts[component] ?? "") else { return }
        let range: ClosedRange<Int>
        switch component {
        case .year: range=1...9999
        case .month: range=1...12
        case .day: range=1...31
        case .hour: range=0...23
        default: range=0...59
        }
        guard range.contains(value) else { return }
        let calendar=Calendar.current
        var parts=calendar.dateComponents([.year,.month,.day,.hour,.minute,.second,.nanosecond],from:date)
        parts.setValue(value,for:component)
        // Keep month/year edits valid at the end of shorter months.
        let day=parts.day ?? 1
        parts.day=1
        guard let first=calendar.date(from:parts),let days=calendar.range(of:.day,in:.month,for:first) else { return }
        if component == .day && day>days.count { return }
        parts.day=min(day,days.count)
        if let updated=calendar.date(from:parts) { date=updated }
    }
    var body: some View {
        HStack(spacing:0) {
            ForEach(components,id:\.self) { component in
                if component != components.first {
                    Text(elements == .hourMinute ? ":" : "/")
                        .contentShape(Rectangle())
                        .onTapGesture { focused=nil }
                }
                TextField("",text:Binding(get:{drafts[component] ?? formatted(component)},set:{drafts[component]=$0}))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(width:component == .year ? 36 : 20)
                    .focused($focused,equals:component)
                    .accessibilityLabel(String(describing:component))
                    .onSubmit { commit(component);focused=nil }
            }
        }
        .font(.system(size:NSFont.systemFontSize).monospacedDigit())
        .onAppear(perform:reload)
        .onChange(of:focused) { previous,current in
            if let previous { commit(previous) }
            if let current { drafts[current]=formatted(current) }
        }
        .onChange(of:date) { _,_ in if focused == nil { reload() } }
        .background(ClickAwayObserver(commit:{ focused=nil }))
    }
}

struct AnchorDetailsEditor: View {
    @ObservedObject var model: AppModel
    let anchorID: String
    @State private var timestampText=""
    @State private var coordinateText=""
    @State private var baselineTimestamp=""
    @State private var baselineCoordinates=""
    @State private var errorText: String?
    private var anchor: Point? { model.points.first(where:{$0.id==anchorID}) }
    private var hasChanges: Bool {
        guard anchor != nil else { return false }
        return timestampText != baselineTimestamp || coordinateText != baselineCoordinates
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("SELECTED ANCHOR").font(.system(size:11,weight:.semibold)).tracking(1.2)
            VStack(alignment:.leading,spacing:5) {
                Text("Timestamp").font(.caption).foregroundStyle(.secondary)
                TextField("HH:MM:SS.mmm",text:$timestampText).textFieldStyle(.roundedBorder).onSubmit(commitTime)
            }
            VStack(alignment:.leading,spacing:5) {
                Text("Coordinates").font(.caption).foregroundStyle(.secondary)
                TextField("latitude, longitude",text:$coordinateText).textFieldStyle(.roundedBorder).onSubmit(commitCoordinates)
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
            Button("Apply changes",action:applyChanges).buttonStyle(.borderedProminent).tint(.orange).disabled(!hasChanges)
        }
        .onAppear(perform:reload)
        .onChange(of:anchorID) { _,_ in reload() }
        .onChange(of:model.points) { _,_ in if !hasChanges { reload() } }
    }
    private func reload() {
        guard let anchor else { return }
        timestampText=formatted(anchor.time)
        coordinateText="\(anchor.lat), \(anchor.lng)"
        baselineTimestamp=timestampText
        baselineCoordinates=coordinateText
        errorText=nil
    }
    private func commitTime() {
        guard let value=parseTime(timestampText),value>=0,(model.videoURL==nil || value<=model.duration) else { errorText="Enter a valid timestamp within the video.";return }
        model.updateAnchor(id:anchorID,time:value);timestampText=formatted(value);baselineTimestamp=timestampText;errorText=nil
    }
    private func commitCoordinates() {
        guard let (lat,lng)=parseCoordinates(coordinateText) else { errorText="Enter latitude, longitude within valid ranges.";return }
        model.updateAnchor(id:anchorID,lat:lat,lng:lng);coordinateText="\(lat), \(lng)";baselineCoordinates=coordinateText;errorText=nil
    }
    private func applyChanges() {
        guard let value=parseTime(timestampText),value>=0,(model.videoURL==nil || value<=model.duration),let (lat,lng)=parseCoordinates(coordinateText) else { errorText="Check the timestamp and coordinates.";return }
        model.updateAnchor(id:anchorID,time:value,lat:lat,lng:lng)
        reload()
    }
    private func parseTime(_ text: String) -> Double? {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        let parts=value.split(separator:":",omittingEmptySubsequences:false)
        if parts.count==3,let hours=Double(parts[0]),let minutes=Double(parts[1]),let seconds=Double(parts[2]),hours>=0,minutes>=0,minutes<60,seconds>=0,seconds<60 {
            return hours*3600+minutes*60+seconds
        }
        if parts.count==1,let seconds=Double(value),seconds.isFinite { return seconds }
        return nil
    }
    private func parseCoordinates(_ text: String) -> (Double,Double)? {
        let parts=text.split(separator:",",omittingEmptySubsequences:false)
        guard parts.count==2,let lat=Double(parts[0].trimmingCharacters(in:.whitespacesAndNewlines)),let lng=Double(parts[1].trimmingCharacters(in:.whitespacesAndNewlines)),lat.isFinite,lng.isFinite,abs(lat)<=90,abs(lng)<=180 else { return nil }
        return (lat,lng)
    }
    private func formatted(_ time: Double) -> String {
        let ms=Int(max(0,time)*1000)
        return String(format:"%02d:%02d:%02d.%03d",ms/3_600_000,(ms/60_000)%60,(ms/1_000)%60,ms%1_000)
    }
}
struct FlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration:configuration)
    }
    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering=false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .background(Color.gray.opacity(configuration.isPressed ? 0.22 : hovering && isEnabled ? 0.16 : 0.08),in:RoundedRectangle(cornerRadius:8))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering=isEnabled && $0 }
                .animation(.easeOut(duration:0.12),value:hovering)
        }
    }
}
// Observe clicks without consuming them, so the clicked control still works.
struct ClickAwayObserver: NSViewRepresentable {
    var commit: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(commit:commit) }
    func updateNSView(_ view: ObserverView,context: Context) { view.commit=commit }
    static func dismantleNSView(_ view: ObserverView,coordinator: ()) { view.stopObserving() }

    final class ObserverView: NSView {
        var commit: () -> Void
        private var monitor: Any?
        init(commit: @escaping () -> Void) {
            self.commit=commit
            super.init(frame:.zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in
                guard let self,let window=self.window,event.window === window else { return event }
                if !self.bounds.contains(self.convert(event.locationInWindow,from:nil)) {
                    self.commit()
                }
                return event
            }
        }
        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor=nil
        }
        deinit { stopObserving() }
    }
}

struct SidebarFileRow: View {
    let title: String
    let detail: String
    let icon: String
    var active=false
    var externallyHovered=false
    var appIcon=false
    var blackIcon=false
    let select: () -> Void
    var edit: (() -> Void)? = nil
    let delete: () -> Void
    var rename: ((String) -> Void)? = nil
    var visibility: Bool? = nil
    var toggleVisibility: (() -> Void)? = nil
    @State private var hover=false
    @State private var renaming=false
    @State private var draftTitle=""
    @FocusState private var titleFocused: Bool
    var body: some View {
        HStack(spacing:10) {
            Button(action:select) {
                HStack(spacing:10) {
                    if appIcon { Image(systemName:"point.3.filled.connected.trianglepath.dotted").foregroundStyle(.black) }
                    else { Image(systemName:icon).foregroundStyle(blackIcon ? .black : active ? .orange : Color(red:0.08,green:0.23,blue:0.47)) }
                    VStack(alignment:.leading,spacing:5) {
                        if renaming, rename != nil {
                            TextField("Path name",text:$draftTitle)
                                .font(.system(size:13,weight:.medium))
                                .textFieldStyle(.roundedBorder)
                                .focused($titleFocused)
                                .background(ClickAwayObserver(commit:commitRename))
                                .onSubmit(commitRename)
                                .onExitCommand { renaming=false;titleFocused=false }
                                .onChange(of:titleFocused) { _,focused in
                                    if !focused && renaming { commitRename() }
                                }
                                .onAppear { draftTitle=title;DispatchQueue.main.async { titleFocused=true } }
                        } else {
                            Text(title).font(.system(size:13,weight:.medium)).lineLimit(2)
                                .onTapGesture(count:2) {
                                    beginRename()
                                }
                                .help(rename == nil ? "" : "Double-click to rename")
                        }
                        Text(detail).font(.system(size:11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let edit {
                Button(action:edit) {Image(systemName:"pencil").foregroundStyle(.secondary)}
                    .buttonStyle(.plain).help("Edit in GPX Creator")
            }
            if let visibility, let toggleVisibility {
                Button(action:toggleVisibility) {Image(systemName:visibility ? "eye" : "eye.slash").foregroundStyle(visibility ? Color.secondary : Color.secondary.opacity(0.55))}
                    .buttonStyle(.plain).help(visibility ? "Hide path on map" : "Show path on map")
            }
            Button(action:delete) {Image(systemName:"trash").foregroundStyle(.secondary)}
                .buttonStyle(.plain).help("Remove from app")
                .opacity(hover ? 1 : 0).allowsHitTesting(hover)
        }.padding(12)
            .background(hover || externallyHovered ? Color.gray.opacity(0.06) : active ? Color.orange.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:10))
            .contentShape(Rectangle()).onHover {hover=$0}
            .contextMenu {
                if rename != nil {
                    Button("Rename",systemImage:"pencil",action:beginRename)
                }
            }
    }
    private func beginRename() {
        guard rename != nil else { return }
        draftTitle=title
        renaming=true
    }
    private func commitRename() {
        guard renaming else { return }
        let value=draftTitle.trimmingCharacters(in:.whitespacesAndNewlines)
        if !value.isEmpty, value != title { rename?(value) }
        renaming=false;titleFocused=false
    }
}
struct TrackRow: View {
    @ObservedObject var model: AppModel
    let track: Track;let active: Bool;let select:()->Void;let edit:(()->Void)?;let delete:()->Void
    var body: some View {
        SidebarFileRow(title:track.name,detail:track.date.formatted(date:.abbreviated,time:.shortened),icon:"point.topleft.down.to.point.bottomright.curvepath",active:active,externallyHovered:model.hovered==track.id,appIcon:track.creatorState != nil,blackIcon:true,select:select,edit:edit,delete:delete,rename:{ value in
            guard let index=model.tracks.firstIndex(where:{$0.id==track.id}),model.tracks[index].name != value else { return }
            model.recordUndo();model.tracks[index].name=value;model.persist()
        },visibility:track.isVisible,toggleVisibility:{model.toggleTrackVisibility(track.id)})
        .onHover { inside in
            if inside { model.hovered=track.id }
            else if model.hovered==track.id { model.hovered=nil }
        }
    }
}
struct ImportedFileRow: View {
    let url: URL
    let icon: String
    let select: () -> Void
    let delete: () -> Void
    @State private var detail=""
    var body: some View {
        SidebarFileRow(title:url.lastPathComponent,detail:detail,icon:icon,blackIcon:icon=="point.topleft.down.to.point.bottomright.curvepath",select:select,delete:delete)
            .onChange(of:url,initial:true) { _,url in
                detail=((try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate).map { $0.formatted(date:.abbreviated,time:.shortened) } ?? url.pathExtension.uppercased()
            }
    }
}
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var entry=""
    @State private var name=""
    @State private var rename=""
    @State private var failure: String?
    @State private var removingKey=false
    @State private var removingID: String?
    @State private var editingID: String?
    private var selectedID: String { model.mapsKeys.selectedID ?? "" }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Map settings").font(.title2.bold())
            if model.mapsKeys.keys.isEmpty {
                Text("Add a named Google Maps key to get started.").foregroundStyle(.secondary)
            } else {
                Text("Saved keys").font(.headline)
                ScrollView {
                    LazyVStack(spacing:6) {
                        ForEach(model.mapsKeys.keys) { key in
                            HStack(spacing:10) {
                                Button { perform { try model.selectMapsKey(key.id) } } label: {
                                    HStack(spacing:10) {
                                        Image(systemName:selectedID == key.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedID == key.id ? Color.accentColor : Color.secondary)
                                        if editingID != key.id {
                                            Text(key.name).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                                        }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Use this key")
                                    .accessibilityLabel("Use \(key.name)")
                                if editingID == key.id {
                                    TextField("Key name",text:$rename).textFieldStyle(.roundedBorder)
                                        .onSubmit { saveRename(key.id) }
                                    Button { saveRename(key.id) } label: { Image(systemName:"checkmark") }
                                        .disabled(rename.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                                        .help("Save name").accessibilityLabel("Save key name")
                                } else {
                                    Button { rename=key.name;editingID=key.id } label: { Image(systemName:"pencil") }
                                        .help("Edit key name").accessibilityLabel("Edit name for \(key.name)")
                                }
                                Button { removingID=key.id;removingKey=true } label: { Image(systemName:"xmark") }
                                    .help("Remove key").accessibilityLabel("Remove \(key.name)")
                            }
                            .padding(10)
                            .background(selectedID == key.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:8))
                        }
                    }.padding(6)
                }.frame(height:190)
                    .background(Color.primary.opacity(0.03),in:RoundedRectangle(cornerRadius:10))
            }
            Divider()
            Text("Add a key").font(.headline)
            TextField("Name (for example, Personal or Work)",text:$name).textFieldStyle(.roundedBorder)
            SecureField("Google Maps API key",text:$entry).textFieldStyle(.roundedBorder)
            Text("Keys are securely saved in Keychain. Only their names are shown. The selected key is used for Google Maps and Street View coverage.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Done") { model.settings=false }.keyboardShortcut(.cancelAction)
                Button("Save and use key") {
                    perform { try model.saveMapsKey(name:name,value:entry);entry="";name="" }
                }.buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || entry.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width:480)
            .alert("Remove saved key?",isPresented:$removingKey) {
                Button("Cancel",role:.cancel) {}
                Button("Remove",role:.destructive) {
                    if let removingID { perform { try model.removeMapsKey(removingID);if editingID == removingID { editingID=nil } } }
                    removingID=nil
                }
            } message: { Text("This removes the key from this app. It does not revoke it in Google Cloud.") }

    }
    private func saveRename(_ id: String) {
        perform { try model.renameMapsKey(id,name:rename);editingID=nil }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action();failure=nil } catch { failure=error.localizedDescription }
    }
}

struct StableMapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

struct MapControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.primary)
            .padding(.horizontal,12)
            .frame(height:42)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
            .contentShape(RoundedRectangle(cornerRadius:10))
    }
}
