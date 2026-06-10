import Cocoa

func drawStatusIcon(scale: CGFloat) -> NSImage {
    let size = NSSize(width: 22 * scale, height: 22 * scale)
    let image = NSImage(size: size)
    image.lockFocus()
    
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    
    // Draw a gray rounded rectangle
    let rect = NSRect(x: 1, y: 4, width: 20, height: 14)
    let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
    
    // Gray color, not pure white, not so contrasted
    let rectColor = NSColor(white: 0.55, alpha: 1.0)
    rectColor.setFill()
    path.fill()
    
    // Draw "L+" text inside (off-white color)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    
    let font = NSFont.systemFont(ofSize: 10, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(white: 0.95, alpha: 1.0),
        .paragraphStyle: paragraphStyle
    ]
    
    let text = "L+"
    // Center the text vertically
    let textHeight = font.capHeight
    let textY = rect.midY - (textHeight / 2) - 1.0
    let textRect = NSRect(x: rect.origin.x, y: textY, width: rect.size.width, height: 12)
    text.draw(in: textRect, withAttributes: attrs)
    
    image.unlockFocus()
    return image
}

func savePNG(image: NSImage, path: String) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to convert image to PNG")
        return
    }
    do {
        try pngData.write(to: URL(fileURLWithPath: path))
        print("Saved \(path)")
    } catch {
        print("Failed to write to \(path): \(error)")
    }
}

let icon1x = drawStatusIcon(scale: 1.0)
let icon2x = drawStatusIcon(scale: 2.0)

savePNG(image: icon1x, path: "StatusIcon.png")
savePNG(image: icon2x, path: "StatusIcon@2x.png")
