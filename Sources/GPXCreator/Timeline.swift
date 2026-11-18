import SwiftUI
import AVFoundation
struct TimelineView: View {
    @ObservedObject var model: AppModel
    @State var hover: Double?;@State var image: NSImage?;@State var task: Task<Void,Never>?
    var body: some View { GeometryReader { geo in
        ZStack(alignment:.leading) {
            Capsule().fill(Color.gray.opacity(0.18)).frame(height:5)
            Capsule().fill(Color.orange).frame(width:max(0,geo.size.width*min(1,model.time/model.duration)),height:5)
            Circle().fill(.white).shadow(color:.black.opacity(0.2),radius:2).overlay(Circle().stroke(.orange,lineWidth:2)).frame(width:12,height:12).offset(x:max(0,geo.size.width*min(1,model.time/model.duration)-6))
            if let hover { VStack(spacing:4) {if let image {Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(width:170,height:86)};Text(String(format:"%.1f s",hover)).font(.caption.monospacedDigit()).foregroundStyle(.white)}.padding(6).background(Color.black.opacity(0.9),in:RoundedRectangle(cornerRadius:8)).offset(x:min(max(0,geo.size.width*hover/model.duration-85),max(0,geo.size.width-182)),y:-80).allowsHitTesting(false) }
        }.frame(maxHeight:.infinity).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance:0).onChanged {value in model.seek(max(0,min(1,value.location.x/geo.size.width))*model.duration)})
        .onContinuousHover { phase in switch phase {case .active(let location): let t=max(0,min(1,location.x/geo.size.width))*model.duration;hover=t;model.previewTime=t;thumbnail(t)
        case .ended:hover=nil;model.previewTime=nil;task?.cancel() } }
    }.frame(height:22) }
    func thumbnail(_ t: Double) { task?.cancel();guard let url=model.videoURL else {return};task=Task {try? await Task.sleep(for:.milliseconds(80));guard !Task.isCancelled else {return};let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.maximumSize=CGSize(width:340,height:172);generator.appliesPreferredTrackTransform=true;if let result=try? await generator.image(at:CMTime(seconds:t,preferredTimescale:600)), !Task.isCancelled {image=NSImage(cgImage:result.image,size:.zero)} } }
}
