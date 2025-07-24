#!/usr/bin/env swift
// screenshot.swift
// Swift 5+, macOS 10.15+

import Foundation
import Quartz

func captureAppWindow(appName: String, outputPath: String) throws {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

    // — Updated unwrapping here —
    guard let cfArray = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) else {
        throw NSError(
            domain: "CaptureError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to fetch window list."]
        )
    }
    guard let info = (cfArray as NSArray) as? [[String: Any]] else {
        throw NSError(
            domain: "CaptureError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unexpected format for window list."]
        )
    }
    // — end update —

    guard let win = info.first(where: {
        ($0[kCGWindowOwnerName as String] as? String) == appName
    }),
    let winID = win[kCGWindowNumber as String] as? Int else {
        throw NSError(
            domain: "CaptureError",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "No on-screen window found for “\(appName)”."] 
        )
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-l", "\(winID)", outputPath]
    try task.run()
    task.waitUntilExit()

    if task.terminationStatus != 0 {
        throw NSError(
            domain: "CaptureError",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey:
                "screencapture exited with status \(task.terminationStatus)."]
        )
    }
}

let appName    = "Claude"
let desktopURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Desktop")
let outputPath = desktopURL
    .appendingPathComponent("claude_screenshot.png")
    .path

do {
    try captureAppWindow(appName: appName, outputPath: outputPath)
    print("✅ Screenshot saved to \(outputPath)")
} catch {
    fputs("❌ Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
