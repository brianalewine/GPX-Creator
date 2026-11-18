import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = root.appendingPathComponent("Assets/AppIcon.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.985, green: 0.973, blue: 0.951, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x:p*0.04,y:p*0.04,width:p*0.92,height:p*0.92),xRadius:p*0.20,yRadius:p*0.20).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize:p*0.60,weight:.medium).applying(.init(paletteColors:[NSColor.systemOrange]))
        guard let symbol=NSImage(systemSymbolName:"point.3.connected.trianglepath.dotted",accessibilityDescription:nil)?.withSymbolConfiguration(configuration) else {fatalError("Missing SF Symbol")}
        let ratio=symbol.size.width/symbol.size.height
        let width=p*0.64, height=width/ratio
        symbol.draw(in:NSRect(x:(p-width)/2,y:(p-height)/2,width:width,height:height))
        image.unlockFocus()
        guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {fatalError("Cannot render icon")}
        let suffix=scale==2 ? "@2x" : ""
        try png.write(to:folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
