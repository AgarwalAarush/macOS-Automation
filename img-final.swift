#!/usr/bin/env swift

import Foundation
import AppKit
import CoreGraphics

// Input and output file names
let inputPath  = "claude_screenshot.png"
let outputPath = "claude-final.png"

// Define the two corner points for the crop rectangle
let p1 = CGPoint(x: 700, y: 700)
let p2 = CGPoint(x: 1300, y: 1300)

/// Normalize two points into a CGRect
func makeCropRect(from p1: CGPoint, to p2: CGPoint) -> CGRect {
    let origin = CGPoint(x: min(p1.x, p2.x),
                         y: min(p1.y, p2.y))
    let size   = CGSize(width: abs(p2.x - p1.x),
                        height: abs(p2.y - p1.y))
    return CGRect(origin: origin, size: size)
}

/// Load an NSImage from disk
guard let srcImage = NSImage(contentsOfFile: inputPath) else {
    fputs("Error: Could not load image at \(inputPath)\n", stderr)
    exit(1)
}

/// Get its CGImage backing
guard
    let cg = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fputs("Error: Could not get CGImage from NSImage\n", stderr)
    exit(1)
}

// Compute the crop rectangle
let cropRect = makeCropRect(from: p1, to: p2)

/// Perform the crop
guard let croppedCG = cg.cropping(to: cropRect) else {
    fputs("Error: Cropping failed\n", stderr)
    exit(1)
}

// Wrap back into an NSImage
let croppedImage = NSImage(cgImage: croppedCG, size: cropRect.size)

/// Encode as PNG
guard
    let tiffData = croppedImage.tiffRepresentation,
    let bitmap   = NSBitmapImageRep(data: tiffData),
    let pngData  = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Error: Failed to encode cropped image as PNG\n", stderr)
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Cropped image written to \(outputPath)")
} catch {
    fputs("Error: Could not write PNG to disk: \(error)\n", stderr)
    exit(1)
}
