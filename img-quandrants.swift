import AppKit
import CoreGraphics

autoreleasepool {
    // 1. Load input image
    let inputPath = "claude-final.png"
    guard let inputImage = NSImage(contentsOfFile: inputPath),
          let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { fatalError("Could not load image at \(inputPath)") }

    // 2. Prepare drawing context
    let width  = cgImage.width
    let height = cgImage.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create graphics context") }

    // 3. Draw the original image
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    // 4. Line attributes
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(1)

    // 5. Compute grid dimensions and draw lines every 400px
    let spacing: Int = 400
    let cols = Int(ceil(Double(width) / Double(spacing)))
    let rows = Int(ceil(Double(height) / Double(spacing)))

    // Vertical lines
    for i in 0...cols {
        let xPos = min(i * spacing, width)
        context.beginPath()
        context.move(to: CGPoint(x: xPos, y: 0))
        context.addLine(to: CGPoint(x: xPos, y: height))
        context.strokePath()
    }
    // Horizontal lines
    for j in 0...rows {
        let yPos = min(j * spacing, height)
        context.beginPath()
        context.move(to: CGPoint(x: 0, y: yPos))
        context.addLine(to: CGPoint(x: width, y: yPos))
        context.strokePath()
    }

    // 6. Draw cell numbers in each grid box, numbering top-left as 1
    let fontSize: CGFloat = 36
    let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
        .foregroundColor: NSColor.red
    ]
    for rowIndex in 0..<rows {
        for colIndex in 0..<cols {
            let cellNumber = rowIndex * cols + colIndex + 1
            // Column bounds
            let xStart = colIndex * spacing
            let xEnd = min((colIndex + 1) * spacing, width)
            let centerX = CGFloat(xStart + xEnd) / 2
            // Row from bottom for drawing
            let bottomRow = rows - 1 - rowIndex
            let yStart = bottomRow * spacing
            let yEnd = min((bottomRow + 1) * spacing, height)
            let centerY = CGFloat(yStart + yEnd) / 2

            let label = "\(cellNumber)" as NSString
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

            let textSize = label.size(withAttributes: textAttributes)
            let drawPoint = CGPoint(
                x: centerX - textSize.width / 2,
                y: centerY - textSize.height / 2
            )
            label.draw(at: drawPoint, withAttributes: textAttributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // 7. Export to PNG
    guard let outputCG = context.makeImage() else { fatalError("Failed to create output image") }
    let rep = NSBitmapImageRep(cgImage: outputCG)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("Failed to create PNG representation") }
    do {
        try data.write(to: URL(fileURLWithPath: "claude-final-result.png"))
        print("✅ Saved new image to test-new.png")
    } catch {
        fatalError("Failed to write output image: \(error)")
    }
}
