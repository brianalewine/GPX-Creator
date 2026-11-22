import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = root.appendingPathComponent("Assets/AppIcon.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let context=NSGraphicsContext(bitmapImageRep:bitmap) else { fatalError("Cannot create icon bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current=context
        context.imageInterpolation = .high
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.985, green: 0.973, blue: 0.951, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x:p*0.04,y:p*0.04,width:p*0.92,height:p*0.92),xRadius:p*0.20,yRadius:p*0.20).fill()
        NSColor.systemOrange.setFill()
        // Draw the route nodes as true circles instead of scaling SF Symbol
        // artwork. Every node uses exactly the same horizontal/vertical radius.
        func circle(_ x: CGFloat,_ y: CGFloat,_ radius: CGFloat) {
            NSBezierPath(ovalIn:NSRect(x:(x-radius)*p,y:(y-radius)*p,width:2*radius*p,height:2*radius*p)).fill()
        }
        let side: CGFloat = 0.44
        let height = side * sqrt(3) / 2
        let radius: CGFloat = 0.0805
        let dotRadius: CGFloat = 0.0205
        // Center the complete artwork's bounds, including the node radii.
        let vertices: [CGPoint] = [
            CGPoint(x:0.5-side/2,y:0.5+height/2),
            CGPoint(x:0.5+side/2,y:0.5+height/2),
            CGPoint(x:0.5,y:0.5-height/2)
        ]
        for vertex in vertices { circle(vertex.x,vertex.y,radius) }
        // Equal visible gaps between each big node and the three small dots.
        let gap = (side-2*radius-6*dotRadius)/4
        for edge in 0..<3 {
            let start=vertices[edge],end=vertices[(edge+1)%3]
            for index in 0..<3 {
                let distance=radius+dotRadius+gap+CGFloat(index)*(2*dotRadius+gap)
                let t=distance/side
                circle(start.x+(end.x-start.x)*t,start.y+(end.y-start.y)*t,dotRadius)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png=bitmap.representation(using:.png,properties:[:]) else {fatalError("Cannot render icon")}
        let suffix=scale==2 ? "@2x" : ""
        try png.write(to:folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
