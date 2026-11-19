import XCTest
import SwiftUI
import AVKit
@testable import GPXCreator

final class VideoPreviewTests: XCTestCase {
    @MainActor func testRepeatedMapClicksPreserveStarterAndAllowInsertion() {
        let model=AppModel()
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
        let model = AppModel()
        model.points = [Point(lat:0,lng:0,time:0),Point(lat:2,lng:2,time:2)]
        model.filled = true
        XCTAssertEqual(model.rendered.map(\.id),model.rendered.map(\.id))
        model.points[1].lat = 4
        XCTAssertEqual(model.rendered[1].lat,2)
        model.filled = false
        XCTAssertEqual(model.rendered.count,2)
    }
    @MainActor func testImportAndClearPathPreserveVideo() throws {
        let model = AppModel()
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
        let model=AppModel()
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
