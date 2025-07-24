import Cocoa
import ApplicationServices

/// Activate an app by its name (brings it to the front).
func activateApp(named appName: String) -> Bool {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == appName
    }) else {
        print("App “\(appName)” not running.")
        return false
    }
    // Only .activateAllWindows is needed on macOS 14+
    return app.activate(options: [.activateAllWindows])
}

/// Simulate a mouse click at a given screen coordinate.
func click(at point: CGPoint) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!
    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!
    let up   = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,   mouseCursorPosition: point, mouseButton: .left)!
    move.post(tap: .cghidEventTap)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

/// Type a Unicode string by sending key‐down and key‐up events.
func typeText(_ text: String) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    for scalar in text.unicodeScalars {
        // Prepare the UTF‐16 code units for this scalar
        let chars = [UniChar](String(scalar).utf16)
        
        // Key down
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
        chars.withUnsafeBufferPointer { buf in
            keyDown.keyboardSetUnicodeString(
                stringLength: buf.count,
                unicodeString: buf.baseAddress
            )
        }
        keyDown.post(tap: .cghidEventTap)
        
        // Key up
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
        chars.withUnsafeBufferPointer { buf in
            keyUp.keyboardSetUnicodeString(
                stringLength: buf.count,
                unicodeString: buf.baseAddress
            )
        }
        keyUp.post(tap: .cghidEventTap)
    }
}

// —————— USAGE ——————
let targetAppName = "ChatGPT"
let clickPoint = CGPoint(x: 900, y: 900)  // adjust as needed
let inputString = "Hello, GPT! Automated input here."

if activateApp(named: targetAppName) {
    // give the app a moment to come forward
    usleep(300_000)
    click(at: clickPoint)
    usleep(200_000)
    typeText(inputString)
} else {
    print("Failed to activate “\(targetAppName)”.")
}
