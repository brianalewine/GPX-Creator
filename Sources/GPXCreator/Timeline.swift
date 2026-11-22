import SwiftUI
import AVFoundation

@MainActor final class TimelineThumbnails: ObservableObject {
    @Published var image: NSImage?
    private var generator: AVAssetImageGenerator?
    private var task: Task<Void,Never>?
    private var lastBucket: Int?
    private var cache: [Int:NSImage] = [:]
    private var revision = 0
    private var pendingBucket: Int?

    func configure(url: URL?) {
        cancel()
        cache.removeAll()
        image = nil
        generator = url.map { url in
            let generator = AVAssetImageGenerator(asset:AVURLAsset(url:url))
            generator.maximumSize = CGSize(width:340,height:172)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds:0.15,preferredTimescale:600)
            generator.requestedTimeToleranceAfter = CMTime(seconds:0.15,preferredTimescale:600)
            return generator
        }
    }
    func request(_ time: Double) {
        let bucket = Int(max(0,time)*4)
        guard bucket != lastBucket else { return }
        lastBucket = bucket
        pendingBucket = bucket
        if let cached = cache[bucket] { image = cached }
        guard task == nil, let generator else { return }
        let requestRevision = revision
        task = Task {
            while let bucket = pendingBucket, !Task.isCancelled, revision == requestRevision {
                pendingBucket = nil
                if let cached = cache[bucket] { image=cached; continue }
                guard let result = try? await generator.image(at:CMTime(seconds:Double(bucket)/4,preferredTimescale:600)),
                      !Task.isCancelled, revision == requestRevision else { break }
                let thumbnail = NSImage(cgImage:result.image,size:.zero)
                if cache.count >= 100 { cache.removeAll() }
                cache[bucket] = thumbnail
                // Show completed frames while coalescing movement to the latest request.
                image = thumbnail
            }
            if revision == requestRevision { task=nil }
        }
    }
    func cancel() {
        revision += 1
        task?.cancel()
        task=nil
        pendingBucket=nil
        generator?.cancelAllCGImageGeneration()
        lastBucket = nil
    }
}

struct TimelineView: View {
    @ObservedObject var model: AppModel
    @State private var hover: Double?
    @State private var dragging = false
    @StateObject private var thumbnails = TimelineThumbnails()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment:.leading) {
                RoundedRectangle(cornerRadius:6).fill(Color(red:0.95,green:0.955,blue:0.965))
                RoundedRectangle(cornerRadius:6).fill(Color.orange.opacity(0.10)).frame(width:geo.size.width*progress).allowsHitTesting(false)
                Canvas { context, size in
                    let count = max(1,Int(size.width/8))
                    for index in 0...count {
                        let x = 6 + max(0,size.width-12)*CGFloat(index)/CGFloat(count)
                        var tick = Path()
                        tick.move(to:CGPoint(x:x,y:index % 5 == 0 ? 6 : 10))
                        tick.addLine(to:CGPoint(x:x,y:size.height-13))
                        context.stroke(tick,with:.color(.gray.opacity(index % 5 == 0 ? 0.48 : 0.28)),lineWidth:1)
                    }
                }.allowsHitTesting(false)
                ForEach(scrubberAnchors) { anchor in
                    let fraction=max(0,min(1,anchor.time/max(1,model.duration)))
                    Button {
                        model.focusedAnchorID=anchor.id
                        model.lockedPreviewTime=nil
                        model.previewTime=nil
                        model.controls=true
                    } label: {
                        anchorGlyph(anchor,selected:model.focusedAnchorID==anchor.id).frame(width:18,height:18).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Select anchor at \(clock(anchor.time))")
                    .position(x:CGFloat(fraction)*geo.size.width,y:geo.size.height-9)
                }
                RoundedRectangle(cornerRadius:2).fill(.orange)
                    .frame(width:4,height:40)
                    .offset(x:min(max(0,geo.size.width*progress-2),max(0,geo.size.width-4)))
                    .allowsHitTesting(false)
            }
            .frame(width:geo.size.width,height:43)
            .clipped()
            .contentShape(Rectangle())
            // Attach scrubbing to the whole timeline, including the lower
            // anchor band. Overlay controls must not shield the background.
            .simultaneousGesture(DragGesture(minimumDistance:0).onChanged { value in
                guard model.videoURL != nil else { return }
                if !dragging { dragging=true; thumbnails.cancel(); model.beginScrubbing() }
                model.preview(at:time(at:value.location.x,width:geo.size.width))
            }.onEnded { value in
                guard dragging else { return }
                let t=time(at:value.location.x,width:geo.size.width)
                model.endScrubbing(at:t)
                if model.focusedAnchorID == nil { model.lockedPreviewTime=t; model.previewTime=t }
                dragging=false
            })
            .simultaneousGesture(SpatialTapGesture(count:2).onEnded { value in
                guard model.videoURL != nil else { return }
                model.addAnchorOnPath(at:time(at:value.location.x,width:geo.size.width))
            })
            .overlay(alignment:.topLeading) {
                if let hover, !dragging, model.videoURL != nil {
                    VStack(spacing:4) {
                        ZStack {
                            Color(red:0.95,green:0.955,blue:0.965)
                            if let image = thumbnails.image { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit) }
                        }.frame(width:170,height:86)
                        Text(clock(hover)).font(.caption.monospacedDigit())
                    }
                    .padding(6).background(.white,in:RoundedRectangle(cornerRadius:8))
                    .shadow(color:.black.opacity(0.15),radius:4)
                    .offset(x:min(max(0,geo.size.width*hover/max(1,model.duration)-91),max(0,geo.size.width-182)),y:-120)
                    .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard !dragging, model.videoURL != nil else { return }
                    let t = time(at:location.x,width:geo.size.width)
                    hover=t; model.previewTime=t; thumbnails.request(t)
                case .ended:
                    guard !dragging else { hover=nil; return }
                    hover=nil; model.previewTime=model.lockedPreviewTime; thumbnails.cancel()
                }
            }
        }
        .frame(height:43)
        .onExitCommand { model.escapeSelection(); hover=nil }
        .onChange(of:model.videoURL,initial:true) { _,url in thumbnails.configure(url:url) }
        .onDisappear { thumbnails.cancel(); model.previewTime=model.lockedPreviewTime }
    }
    private var progress: Double { let position=model.previewTime ?? model.time;return model.duration > 0 ? max(0,min(1,position/model.duration)) : 0 }
    private var scrubberAnchors: [Point] { model.points.filter(\.manual).sorted{$0.time<$1.time} }
    @ViewBuilder private func anchorGlyph(_ anchor: Point,selected: Bool) -> some View {
        if selected {
            Circle().fill(Color.orange).frame(width:9,height:9).overlay(Circle().stroke(.white,lineWidth:1))
        } else if scrubberAnchors.count>1,scrubberAnchors.last?.id==anchor.id {
            Image(systemName:"flag.checkered").font(.system(size:11,weight:.semibold)).foregroundStyle(.primary)
        } else {
            Circle().fill(scrubberAnchors.first?.id==anchor.id ? Color.green : Color(red:0.16,green:0.47,blue:0.84)).frame(width:8,height:8).overlay(Circle().stroke(.white,lineWidth:1))
        }
    }
    private func time(at x: CGFloat,width: CGFloat) -> Double { max(0,min(1,x/max(1,width)))*model.duration }
    private func clock(_ value: Double) -> String {
        let milliseconds=Int(max(0,value)*1000)
        return String(format:"%02d:%02d:%02d.%03d",milliseconds/3_600_000,(milliseconds/60_000)%60,(milliseconds/1_000)%60,milliseconds%1_000)
    }
}
