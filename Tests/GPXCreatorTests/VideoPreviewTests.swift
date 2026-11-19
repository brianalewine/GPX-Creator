import XCTest
import SwiftUI
import AVKit
@testable import GPXCreator

final class VideoPreviewTests: XCTestCase {
    @MainActor func testExportUsesRecordingStart() throws {
        let model=makeModel()
        model.points=[Point(lat:42,lng:-71,time:0),Point(lat:43,lng:-72,time:120)]
        model.samplesPerSecond=0
        let start=ISO8601DateFormatter().date(from:"2026-11-17T19:23:00Z")!
        model.recordingStart=start
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gpx")
        defer { try? FileManager.default.removeItem(at:url) }
        try model.export(to:url)
        let xml=try String(contentsOf:url)
        XCTAssertTrue(xml.contains("<time>2026-11-17T19:23:00Z</time>"))
        XCTAssertTrue(xml.contains("<time>2026-11-17T19:25:00Z</time>"))
    }
    @MainActor private func makeModel(fileLoadTimeout: Duration = .seconds(20)) -> AppModel {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("GPXCreatorTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at:folder) }
        return AppModel(storageFolder:folder,fileLoadTimeout:fileLoadTimeout)
    }
    @MainActor private func waitForParsing(_ model: AppModel) async {
        for _ in 0..<500 where model.isParsing { try? await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(model.isParsing)
    }
    @MainActor func testRepeatedMapClicksPreserveStarterAndAllowInsertion() {
        let model=makeModel()
        let bridge=MapView.Coordinator(model,false)
        bridge.handle(["lat":42.0,"lng":-71.0],type:"add")
        let starter=model.points[0]
        bridge.handle(["lat":43.0,"lng":-72.0],type:"add")
        XCTAssertEqual(model.points.count,2)
        XCTAssertEqual(model.points[0],starter)
        XCTAssertEqual(model.points[1].time,1)
        XCTAssertEqual(model.duration,1)
        bridge.handle(["lat":42.5,"lng":-71.5,"time":0.5],type:"insert")
        XCTAssertEqual(model.points.map(\.time),[0,0.5,1])
    }
    @MainActor func testPathHoverStillPreviewsWithSelectedAnchor() {
        let model=makeModel()
        let bridge=MapView.Coordinator(model,false)
        model.focusedAnchorID="selected-anchor"
        bridge.handle(["time":0.5],type:"preview")
        XCTAssertEqual(model.previewTime,0.5)
        bridge.handle(["time":0.75],type:"lockPreview")
        XCTAssertNil(model.lockedPreviewTime)
    }
    @MainActor func testEscapeDeselectsAnchorAndUnlocksHover() {
        let model=makeModel()
        let bridge=MapView.Coordinator(model,false)
        model.focusedAnchorID="anchor";model.lockedPreviewTime=0.5;model.previewTime=0.5
        bridge.handle([:],type:"escape")
        XCTAssertNil(model.focusedAnchorID)
        XCTAssertNil(model.lockedPreviewTime)
        XCTAssertNil(model.previewTime)
    }
    @MainActor func testSlowGPXImportStopsAtDeadline() async throws {
        let model=makeModel(fileLoadTimeout:.milliseconds(1))
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gpx")
        defer { try? FileManager.default.removeItem(at:url) }
        let point="<trkpt lat=\"42.0001\" lon=\"-71.0001\"/>"
        try ("<gpx><trk><trkseg>"+String(repeating:point,count:55_000)+"</trkseg></trk></gpx>").write(to:url,atomically:true,encoding:.utf8)
        model.importFile(url)
        await waitForParsing(model)
        XCTAssertTrue(model.points.isEmpty)
        XCTAssertTrue(model.error?.contains("20 seconds") == true)
    }
    @MainActor func testStaleMapRenderDoesNotFinishCurrentLoad() async throws {
        let model=makeModel()
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gpx")
        defer { try? FileManager.default.removeItem(at:url) }
        try "<gpx><trk><trkseg><trkpt lat=\"42\" lon=\"-71\"/></trkseg></trk></gpx>".write(to:url,atomically:true,encoding:.utf8)
        model.importFile(url)
        await waitForParsing(model)
        model.mapDidRender(loadID:"stale")
        XCTAssertNotNil(model.loadingMessage)
        model.mapDidRender(loadID:model.currentLoadID)
        XCTAssertNil(model.loadingMessage)
    }
    @MainActor func testAnchorOnlyExportAndDashboardReediting() async throws {
        let defaults=UserDefaults.standard
        let previousRate=defaults.object(forKey:"samplesPerSecond")
        defer {
            if let previousRate { defaults.set(previousRate,forKey:"samplesPerSecond") }
            else { defaults.removeObject(forKey:"samplesPerSecond") }
        }
        let model=makeModel()
        model.points=[Point(lat:42,lng:-71,time:0),Point(lat:43,lng:-72,time:2)]
        model.filled=true;model.duration=2;model.setSamplesPerSecond(0)
        XCTAssertEqual(model.rendered.count,2)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gpx")
        defer { try? FileManager.default.removeItem(at:url) }
        try model.export(to:url)
        XCTAssertEqual(try GPXParser.parse(Data(contentsOf:url)).count,2)
        model.saveCreatorPathToDashboard()
        XCTAssertEqual(model.tracks.count,1)
        let id=try XCTUnwrap(model.editingTrackID)
        XCTAssertEqual(model.tracks[0].points.count,2)
        XCTAssertNotNil(model.tracks[0].creatorState)
        model.editCreatorPathFromDashboard(id:id)
        XCTAssertEqual(model.tab,0)
        XCTAssertEqual(model.points.count,2)
        XCTAssertEqual(model.samplesPerSecond,0)
        model.points.append(Point(lat:44,lng:-73,time:3))
        model.saveCreatorPathToDashboard()
        XCTAssertEqual(model.tracks.count,1)
        XCTAssertEqual(model.tracks[0].points.count,3)
        let restored=AppModel(storageFolder:model.folder)
        await waitForParsing(restored)
        restored.editCreatorPathFromDashboard(id:id)
        XCTAssertEqual(restored.points.count,3)
        XCTAssertEqual(restored.editingTrackID,id)
    }
    func testOlderDashboardTrackStillDecodes() throws {
        let legacy="""
        {"id":"old","name":"Imported GPX","date":0,"points":[]}
        """
        let track=try JSONDecoder().decode(Track.self,from:Data(legacy.utf8))
        XCTAssertNil(track.creatorState)
    }
    @MainActor func testLargeGPXImportCanUndoAndRedo() async throws {
        let model=makeModel()
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gpx")
        defer { try? FileManager.default.removeItem(at:url) }
        let point="<trkpt lat=\"42.0001\" lon=\"-71.0001\"/>"
        let gpx="<gpx><trk><trkseg>"+String(repeating:point,count:55_000)+"</trkseg></trk></gpx>"
        XCTAssertGreaterThan(gpx.utf8.count,2_000_000)
        try gpx.write(to:url,atomically:true,encoding:.utf8)
        model.importFile(url)
        await waitForParsing(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.points.count,55_000)
        model.undo()
        XCTAssertTrue(model.points.isEmpty)
        model.redo()
        XCTAssertEqual(model.points.count,55_000)
        let restored=AppModel(storageFolder:model.folder)
        await waitForParsing(restored)
        XCTAssertEqual(restored.points.count,55_000)
    }
    @MainActor func testLoadedPlayerViewCanMountAndRemount() {
        let player = AVPlayer(playerItem:AVPlayerItem(asset:AVMutableComposition()))
        let host = NSHostingView(rootView:VideoPreview(player:player))
        host.frame = NSRect(x:0,y:0,width:640,height:360)
        host.layoutSubtreeIfNeeded()
        func playerView(in view: NSView) -> AVPlayerView? {
            if let view = view as? AVPlayerView { return view }
            return view.subviews.lazy.compactMap { playerView(in:$0) }.first
        }
        let mounted = playerView(in:host)
        XCTAssertNotNil(mounted)
        XCTAssertTrue(mounted?.player === player)
        XCTAssertEqual(mounted?.controlsStyle, AVPlayerViewControlsStyle.none)
        let replacement = AVPlayer()
        host.rootView = VideoPreview(player:replacement)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(playerView(in:host)?.player === replacement)
    }
    @MainActor func testZoomPreservesCursorAnchorAndClamps() {
        let view = ZoomableVideoView(frame:NSRect(x:0,y:0,width:640,height:360))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.playerView.videoGravity,.resizeAspectFill)
        let cursor = CGPoint(x:160,y:90)
        view.setZoom(2,at:cursor)
        XCTAssertEqual(view.playerView.frame.minX,-160,accuracy:0.01)
        XCTAssertEqual(view.playerView.frame.minY,-90,accuracy:0.01)
        XCTAssertEqual((cursor.x-view.playerView.frame.minX)/view.playerView.frame.width,0.25,accuracy:0.001)
        view.setZoom(0.5,at:cursor)
        XCTAssertEqual(view.zoom,1)
        XCTAssertEqual(view.playerView.frame,view.bounds)
    }
    @MainActor func testSeekDropsObsoleteRequestsAndKeepsExactRelease() {
        var requests: [(Double,Bool)] = []
        var completions: [() -> Void] = []
        let seeker = ScrubSeeker { time,exact,completion in
            requests.append((time,exact)); completions.append(completion)
        }
        seeker.seek(1,exact:false)
        seeker.seek(2,exact:false)
        seeker.seek(3,exact:false)
        seeker.seek(4,exact:true)
        XCTAssertEqual(requests.map { $0.0 },[1])
        completions.removeFirst()()
        XCTAssertEqual(requests.map { $0.0 },[1,4])
        XCTAssertTrue(requests[1].1)
        completions.removeFirst()()
        XCTAssertFalse(seeker.busy)
    }
    @MainActor func testRenderedPointsCacheInvalidatesAfterEdits() {
        let model = makeModel()
        model.points = [Point(lat:0,lng:0,time:0),Point(lat:2,lng:2,time:2)]
        model.filled = true
        XCTAssertEqual(model.rendered.map(\.id),model.rendered.map(\.id))
        model.points[1].lat = 4
        XCTAssertEqual(model.rendered.first(where:{$0.id==model.points[1].id})?.lat,4)
        model.filled = false
        XCTAssertEqual(model.rendered.count,2)
    }
    @MainActor func testImportAndClearPathPreserveVideo() async throws {
        let model = makeModel()
        let videoURL = URL(fileURLWithPath:"/tmp/existing-video.mov")
        let item = AVPlayerItem(asset:AVMutableComposition())
        model.videoURL=videoURL
        model.player.replaceCurrentItem(with:item)
        model.time=12
        model.duration=60
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".gpx")
        defer { try? FileManager.default.removeItem(at:url) }
        try "<gpx><trk><trkseg><trkpt lat=\"42\" lon=\"-71\"/></trkseg></trk></gpx>".write(to:url,atomically:true,encoding:.utf8)
        model.importFile(url)
        await waitForParsing(model)
        XCTAssertEqual(model.points.count,1)
        XCTAssertEqual(model.gpxURL,url)
        XCTAssertTrue(model.finished,"Imported GPX paths should show the finish marker")
        model.filled=true;model.finished=true
        model.clearPath()
        XCTAssertTrue(model.points.isEmpty)
        XCTAssertNil(model.gpxURL)
        XCTAssertFalse(model.filled)
        XCTAssertFalse(model.finished)
        XCTAssertEqual(model.videoURL,videoURL)
        XCTAssertTrue(model.player.currentItem === item)
        XCTAssertEqual(model.time,12)
        XCTAssertEqual(model.duration,60)
    }
    @MainActor func testRemovingVideoPreservesPath() {
        let model=makeModel()
        model.points=[Point(lat:42,lng:-71,time:0)]
        let path=model.points
        model.videoURL=URL(fileURLWithPath:"/tmp/video.mov")
        model.player.replaceCurrentItem(with:AVPlayerItem(asset:AVMutableComposition()))
        model.clearVideo()
        XCTAssertNil(model.videoURL)
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.points,path)
    }
    @MainActor func testVideoResizeKeepsPlayerWithinPane() {
        let view=ZoomableVideoView(frame:NSRect(x:0,y:0,width:640,height:360))
        for height in stride(from:360,through:160,by:-5) {
            view.frame.size.height=CGFloat(height)
            view.needsLayout=true
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.playerView.frame,view.bounds)
        }
    }
}
