import SwiftUI
import AVKit

struct VideoPreview: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> ZoomableVideoView {
        let view = ZoomableVideoView()
        view.playerView.player = player
        return view
    }

    func updateNSView(_ view: ZoomableVideoView, context: Context) {
        if view.playerView.player !== player { view.playerView.player = player }
        if view.item !== player.currentItem {
            view.item = player.currentItem
            view.resetZoom()
        }
    }

    static func dismantleNSView(_ view: ZoomableVideoView, coordinator: ()) {
        view.playerView.player = nil
    }
}

// Keep the video on AVKit's native rendering path, outside its SwiftUI bridge.
final class ZoomableVideoView: NSView {
    let playerView = AVPlayerView()
    weak var item: AVPlayerItem?
    private(set) var zoom: CGFloat = 1
    private var origin = CGPoint.zero
    private var dragPoint: CGPoint?

    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill
        addSubview(playerView)
        toolTip = nil
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    // Receive gestures ourselves; the player has no built-in controls.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === playerView || hit?.isDescendant(of:playerView) == true ? self : hit
    }
    override func layout() {
        super.layout()
        constrainOrigin()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerView.frame = CGRect(origin:origin,size:CGSize(width:bounds.width*zoom,height:bounds.height*zoom))
        CATransaction.commit()
    }
    func setZoom(_ value: CGFloat, at anchor: CGPoint) {
        let next = min(8,max(1,value))
        origin = CGPoint(x:anchor.x-(anchor.x-origin.x)*next/zoom,
                         y:anchor.y-(anchor.y-origin.y)*next/zoom)
        zoom = next
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    private func constrainOrigin() {
        origin.x = min(0,max(bounds.width*(1-zoom),origin.x))
        origin.y = min(0,max(bounds.height*(1-zoom),origin.y))
    }
    @objc func resetZoom() {
        zoom = 1
        origin = .zero
        needsLayout = true
    }
    override func scrollWheel(with event: NSEvent) {
        setZoom(zoom*exp(event.scrollingDeltaY*0.015),at:convert(event.locationInWindow,from:nil))
    }
    override func magnify(with event: NSEvent) {
        setZoom(zoom*(1+event.magnification),at:convert(event.locationInWindow,from:nil))
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { resetZoom(); return }
        dragPoint = convert(event.locationInWindow,from:nil)
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if let previous = dragPoint {
            origin.x += point.x-previous.x
            origin.y += point.y-previous.y
            needsLayout = true
        }
        dragPoint = point
    }
    override func mouseUp(with event: NSEvent) { dragPoint = nil }
}
