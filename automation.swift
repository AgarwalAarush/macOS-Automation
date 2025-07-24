#!/usr/bin/env swift
// Task Input: String
// Tool Call JSON: Use LLM Client to determine the series of tool calls needed to complete the task
// Exectute each tool call in the series
// Click (item): take a screenshot of the app window, feed the screenshot to the quadrant creater, then to the llm for the box
// then give it an portion of the image with the quadrant within (as context), explain the role, the bounds, and ask it to
// choose the (x,y) coordinates. Then execute the click at those coordinates

import Foundation
import AppKit
import CoreGraphics
import Quartz
import Cocoa
import ApplicationServices

// MARK: - Configuration
struct Config {
    static let initialGridSpacing = 400
    static let refinedGridSpacing = 120
    static let cropSize = 600
    static let screenshotPath = "claude_screenshot.png"
    static let quadrantImagePath = "claude_quadrant.png"
    static let croppedImagePath = "claude_cropped.png"
    static let refinedQuadrantPath = "claude_refined.png"
}

// MARK: - Data Models
struct ToolCall {
    let type: String
    let parameters: [String: Any]
}

struct QuadrantResult {
    let quadrantNumber: Int
    let centerPoint: CGPoint
}

struct GridBounds {
    let topLeft: CGPoint
    let bottomRight: CGPoint
}

// MARK: - LLM API Client
class LLMAPIClient {
    
    /// Send a request to OpenAI API
    static func sendRequest(messages: [[String: Any]], model: String = "gpt-4.1-2025-04-14", temperature: Double = 0.7) -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.OPENAI_API_KEY)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temperature
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            print("❌ Failed to serialize JSON payload")
            return ""
        }
        request.httpBody = httpBody
        
        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                print("❌ Request error:", error)
                return
            }
            guard let data = data else {
                print("❌ No data received")
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    result = content
                } else {
                    let text = String(data: data, encoding: .utf8) ?? "<invalid UTF-8>"
                    print("❌ Unexpected response format:\n\(text)")
                }
            } catch {
                print("❌ JSON decode error:", error)
            }
        }.resume()
        
        semaphore.wait()
        return result
    }
    
    /// Send text-only prompt to LLM
    static func sendTextPrompt(_ prompt: String, model: String = "gpt-4.1-mini-2025-04-14", temperature: Double = 0.7) -> String {
        let messages: [[String: Any]] = [
            ["role": "user", "content": prompt]
        ]
        return sendRequest(messages: messages, model: model, temperature: temperature)
    }
    
    /// Send image analysis request to LLM
    static func analyzeImage(imagePath: String, textPrompt: String, model: String = "gpt-4.1-mini-2025-04-14") -> String {
        guard let imageData = FileManager.default.contents(atPath: imagePath) else {
            print("❌ Failed to read image at \(imagePath)")
            return ""
        }
        let base64Image = imageData.base64EncodedString()
        
        let messageContent: [Any] = [
            ["type": "text", "text": textPrompt],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]]
        ]
        let messages: [[String: Any]] = [
            ["role": "user", "content": messageContent]
        ]
        
        return sendRequest(messages: messages, model: model, temperature: 0.7)
    }
}

// MARK: - LLM Client Functions
class LLMClient {
    
    /// Available tools definition for the LLM
    static let availableTools: [String: Any] = [
        "tools": [
            [
                "name": "click",
                "description": "Click on a UI element in an application",
                "parameters": [
                    "target": ["type": "string", "description": "Description of the UI element to click (e.g., 'submit button', 'text input field')"],
                    "appName": ["type": "string", "description": "Name of the application to interact with"]
                ]
            ],
            [
                "name": "type",
                "description": "Type text into a focused input field",
                "parameters": [
                    "text": ["type": "string", "description": "The text to type"],
                    "appName": ["type": "string", "description": "Name of the application to type into"]
                ]
            ],
            [
                "name": "screenshot",
                "description": "Take a screenshot of an application window",
                "parameters": [
                    "appName": ["type": "string", "description": "Name of the application to screenshot"]
                ]
            ],
            [
                "name": "activate_app",
                "description": "Bring an application to the foreground",
                "parameters": [
                    "appName": ["type": "string", "description": "Name of the application to activate"]
                ]
            ]
        ]
    ]
    
    /// Analyze task and determine required tool calls using LLM
    static func determineToolCalls(for task: String) -> [ToolCall] {
        let prompt = """
        <task>
        Analyze the following user task and determine which tool calls are needed to complete it.
        
        User task: \(task)
        </task>
        
        <available_tools>
        \(toolsJSONString())
        </available_tools>
        
        <instructions>
        1. Break down the task into a sequence of tool calls. Think from the perspective 
        of a user. What series of steps would the user make to accomplish this task?
        2. For each tool call, specify the tool name and required parameters
        3. Use descriptive targets for UI elements (e.g., "search input field", "submit button")
        4. Return a JSON array of tool calls in the exact format shown below
        5. Remember, interacting with an App requires activating it
        </instructions>
        
        <format>
        Return only a JSON array in this exact format:
        [
            {
                "type": "tool_name",
                "parameters": {
                    "param1": "value1",
                    "param2": "value2"
                }
            }
        ]
        </format>
        """
        
        let response = LLMAPIClient.sendTextPrompt(prompt)
        return parseToolCallsFromResponse(response)
    }
    
    /// Convert tools JSON to string format
    static func toolsJSONString() -> String {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: availableTools, options: .prettyPrinted),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{}"
        }
        return jsonString
    }
    
    
    /// Parse tool calls from LLM response
    static func parseToolCallsFromResponse(_ response: String) -> [ToolCall] {
        var toolCalls: [ToolCall] = []
        
        // Extract JSON from response (handle potential markdown code blocks)
        let cleanedResponse = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let jsonData = cleanedResponse.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [[String: Any]] else {
            print("❌ Failed to parse tool calls JSON: \(response)")
            return []
        }
        
        for toolCallData in jsonArray {
            guard let type = toolCallData["type"] as? String,
                  let parameters = toolCallData["parameters"] as? [String: Any] else {
                continue
            }
            toolCalls.append(ToolCall(type: type, parameters: parameters))
        }

        print("Tool Calls: \(toolCalls.map { "\($0.type): \($0.parameters)" })")
        
        return toolCalls
    }
    
    /// First stage: Analyze image with quadrants to find general area
    static func analyzeImageForInitialQuadrant(imagePath: String, target: String) -> QuadrantResult? {
        let quadrantInput = """
        <task>
        Identify which numbered section contains the \(target) in the provided image.
        </task>

        <instructions>
        1. Locate your target: the \(target) in the image
        2. Determine which red-numbered section it primarily occupies
        3. If the element spans multiple sections, choose the section that contains the center/majority of the target
        4. Look specifically for text input fields, search bars, prompt input areas, or interactive elements
        </instructions>

        <format>
        Return only the section number (1-40) that best represents the location of the \(target).
        </format>
        """
        
        let response = LLMAPIClient.analyzeImage(imagePath: imagePath, textPrompt: quadrantInput)
        guard let sectionNum = Int(response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)) else {
            print("❌ Could not parse initial quadrant number: \(response)")
            return nil
        }
        
        guard let centerPoint = calculateCoordinatesFromQuadrant(sectionNum, imagePath: imagePath, spacing: Config.initialGridSpacing) else {
            return nil
        }
        
        return QuadrantResult(quadrantNumber: sectionNum, centerPoint: centerPoint)
    }
    
    /// Second stage: Analyze cropped image for precise positioning
    static func analyzeImageForRefinedQuadrant(imagePath: String, target: String) -> QuadrantResult? {
        let quadrantInput = """
        <task>
        This is a cropped, zoomed-in view. Identify which numbered section contains the \(target) in the provided image.
        </task>

        <instructions>
        1. Locate your target: the \(target) in this cropped image
        2. You are a user. When interacting with the \(target), which
        red-numbered section would you click in to interact with it?
        3. Look for the exact clickable area
        4. This is a detailed view, so be precise about the location
        </instructions>

        <format>
        Return only the section number that best represents the precise location of the \(target).
        </format>
        """
        
        let response = LLMAPIClient.analyzeImage(imagePath: imagePath, textPrompt: quadrantInput)
        guard let sectionNum = Int(response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)) else {
            print("❌ Could not parse refined quadrant number: \(response)")
            return nil
        }
        
        guard let centerPoint = calculateCoordinatesFromQuadrant(sectionNum, imagePath: imagePath, spacing: Config.refinedGridSpacing) else {
            return nil
        }
        
        return QuadrantResult(quadrantNumber: sectionNum, centerPoint: centerPoint)
    }
    
    /// Iterative quadrant analysis with configurable iterations and grid size
    static func iterativeQuadrantAnalysis(topLeft: CGPoint, bottomRight: CGPoint, target: String, iterations: Int = 4, gridWidth: Int = 2) -> CGPoint? {
        var currentTopLeft = topLeft
        var currentBottomRight = bottomRight
        
        for iteration in 0..<iterations {
            let width = currentBottomRight.x - currentTopLeft.x
            let height = currentBottomRight.y - currentTopLeft.y
            
            let croppedImagePath = "iterative_cropped_\(iteration).png"
            let quadrantOverlayPath = "iterative_quadrant_\(iteration).png"
            
            do {
                // Crop the screenshot to the current region
                print("✂️ Iteration \(iteration): Cropping region (\(currentTopLeft.x), \(currentTopLeft.y)) to (\(currentBottomRight.x), \(currentBottomRight.y))")
                try ImageProcessor.cropImage(
                    inputPath: Config.screenshotPath,
                    outputPath: croppedImagePath,
                    centerPoint: CGPoint(x: (currentTopLeft.x + currentBottomRight.x) / 2, y: (currentTopLeft.y + currentBottomRight.y) / 2),
                    cropSize: Int(max(width, height))
                )
                
                // Create grid overlay on the cropped image
                print("🔢 Creating \(gridWidth)x\(gridWidth) grid overlay for iteration \(iteration)...")
                try QuadrantManager.drawGridOverlay(
                    inputPath: croppedImagePath,
                    outputPath: quadrantOverlayPath,
                    gridWidth: gridWidth
                )
                
                print("🧠 Analyzing grid choice for iteration \(iteration)...")
                let gridChoice = analyzeGridChoice(imagePath: quadrantOverlayPath, target: target, gridWidth: gridWidth)
                print("✅ Iteration \(iteration): Model chose grid cell \(gridChoice)")
                
                // Calculate new bounds based on grid choice
                guard let newBounds = QuadrantManager.calculateGridCellBounds(
                    topLeft: currentTopLeft,
                    bottomRight: currentBottomRight,
                    gridWidth: gridWidth,
                    cellNumber: gridChoice
                ) else {
                    print("❌ Failed to calculate new bounds for cell \(gridChoice)")
                    return nil
                }
                
                currentTopLeft = newBounds.topLeft
                currentBottomRight = newBounds.bottomRight
                
                print("📏 Next iteration bounds: (\(currentTopLeft.x), \(currentTopLeft.y)) to (\(currentBottomRight.x), \(currentBottomRight.y))")
                
            } catch {
                print("❌ Error in iterative quadrant analysis iteration \(iteration): \(error)")
                return nil
            }
        }
        
        // Return center of final region
        let centerX = (currentTopLeft.x + currentBottomRight.x) / 2
        let centerY = (currentTopLeft.y + currentBottomRight.y) / 2
        print("🎯 Final iteration complete, returning center: (\(centerX), \(centerY))")
        return CGPoint(x: centerX, y: centerY)
    }
    
    /// Analyze which grid cell contains the target
    static func analyzeGridChoice(imagePath: String, target: String, gridWidth: Int) -> Int {
        let gridInput = """
        <task>
        Look at this image with a \(gridWidth)x\(gridWidth) grid of numbered cells. Identify which cell contains the \(target).
        </task>

        <instructions>
        1. The image shows a rectangle divided into \(gridWidth * gridWidth) numbered cells in a \(gridWidth)x\(gridWidth) grid
        2. Cells are numbered from 1 to \(gridWidth * gridWidth), starting from top-left, going left-to-right, then top-to-bottom
        3. Find the \(target) in the image
        4. Determine which numbered cell it primarily occupies
        5. Look carefully at the numbers drawn on each cell
        </instructions>

        <format>
        Return only the cell number (1 to \(gridWidth * gridWidth)) that contains the \(target).
        </format>
        """
        
        let response = LLMAPIClient.analyzeImage(imagePath: imagePath, textPrompt: gridInput)
        let cellNumber = Int(response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)) ?? 1
        
        // Validate the response is within expected range
        if cellNumber < 1 || cellNumber > gridWidth * gridWidth {
            print("⚠️ Model returned invalid cell number \(cellNumber), defaulting to 1")
            return 1
        }
        
        return cellNumber
    }
    
    /// Analyze which quadrant (1-4) contains the target (legacy function for backward compatibility)
    static func analyzeQuadrantChoice(imagePath: String, target: String) -> Int {
        return analyzeGridChoice(imagePath: imagePath, target: target, gridWidth: 2)
    }
    
}

// MARK: - Screenshot Functions
class ScreenshotManager {
    
    /// Capture screenshot of specified app window
    static func captureAppWindow(appName: String, outputPath: String = Config.screenshotPath) throws {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

        guard let cfArray = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) else {
            throw NSError(domain: "CaptureError", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "Unable to fetch window list."])
        }
        guard let info = (cfArray as NSArray) as? [[String: Any]] else {
            throw NSError(domain: "CaptureError", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "Unexpected format for window list."])
        }

        guard let win = info.first(where: {
            ($0[kCGWindowOwnerName as String] as? String) == appName
        }),
        let winID = win[kCGWindowNumber as String] as? Int else {
            throw NSError(domain: "CaptureError", code: 2, 
                         userInfo: [NSLocalizedDescriptionKey: "No on-screen window found for \(appName)."])
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-l", "\(winID)", outputPath]
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            throw NSError(domain: "CaptureError", code: 3, 
                         userInfo: [NSLocalizedDescriptionKey: 
                           "screencapture exited with status \(task.terminationStatus)."])
        }
    }
}

// MARK: - Image Processing Functions
class ImageProcessor {
    
    /// Crop image to specified rectangle
    static func cropImage(inputPath: String, outputPath: String, centerPoint: CGPoint, cropSize: Int = Config.cropSize) throws {
        guard let srcImage = NSImage(contentsOfFile: inputPath) else {
            throw NSError(domain: "ImageError", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "Could not load image at \(inputPath)"])
        }

        guard let cg = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "ImageError", code: 2, 
                         userInfo: [NSLocalizedDescriptionKey: "Could not get CGImage from NSImage"])
        }

        // Calculate crop rectangle centered on the point
        let halfSize = CGFloat(cropSize) / 2
        let cropRect = CGRect(
            x: max(0, centerPoint.x - halfSize),
            y: max(0, centerPoint.y - halfSize),
            width: CGFloat(cropSize),
            height: CGFloat(cropSize)
        )

        // Ensure crop rect is within image bounds
        let imageRect = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let finalCropRect = cropRect.intersection(imageRect)

        guard let croppedCG = cg.cropping(to: finalCropRect) else {
            throw NSError(domain: "ImageError", code: 3, 
                         userInfo: [NSLocalizedDescriptionKey: "Cropping failed"])
        }

        let croppedImage = NSImage(cgImage: croppedCG, size: finalCropRect.size)

        guard let tiffData = croppedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ImageError", code: 4, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to encode cropped image as PNG"])
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath))
        print("✅ Cropped image saved to \(outputPath)")
    }
}

// MARK: - Quadrant Grid Functions
class QuadrantManager {
    
    /// Create quadrant overlay on image
    static func createQuadrantOverlay(inputPath: String, outputPath: String, spacing: Int) throws {
        guard let inputImage = NSImage(contentsOfFile: inputPath),
              let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { 
            throw NSError(domain: "QuadrantError", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "Could not load image at \(inputPath)"])
        }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { 
            throw NSError(domain: "QuadrantError", code: 2, 
                         userInfo: [NSLocalizedDescriptionKey: "Could not create graphics context"])
        }

        // Draw original image
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Draw grid lines
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)

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

        // Draw cell numbers
        let fontSize: CGFloat = spacing > 200 ? 36 : 24
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.red
        ]
        
        for rowIndex in 0..<rows {
            for colIndex in 0..<cols {
                let cellNumber = rowIndex * cols + colIndex + 1
                let xStart = colIndex * spacing
                let xEnd = min((colIndex + 1) * spacing, width)
                let centerX = CGFloat(xStart + xEnd) / 2
                
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

        // Export to PNG
        guard let outputCG = context.makeImage() else { 
            throw NSError(domain: "QuadrantError", code: 3, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create output image"])
        }
        
        let rep = NSBitmapImageRep(cgImage: outputCG)
        guard let data = rep.representation(using: .png, properties: [:]) else { 
            throw NSError(domain: "QuadrantError", code: 4, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG representation"])
        }
        
        try data.write(to: URL(fileURLWithPath: outputPath))
        print("✅ Quadrant overlay saved to \(outputPath)")
    }
}

// MARK: - Quadrant Rectangle Drawing
extension QuadrantManager {
    
    /// Draw a rectangle with quadrant divisions and labels
    static func drawQuadrantRectangle(inputPath: String, outputPath: String) throws {
        guard let inputImage = NSImage(contentsOfFile: inputPath),
              let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { 
            throw NSError(domain: "QuadrantError", code: 5, 
                         userInfo: [NSLocalizedDescriptionKey: "Could not load input image at \(inputPath)"])
        }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "QuadrantError", code: 6,
                         userInfo: [NSLocalizedDescriptionKey: "Could not create graphics context for quadrant rectangle"])
        }
        
        // Draw original image
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(2)
        
        let midX = width / 2
        let midY = height / 2
        
        context.beginPath()
        context.addRect(CGRect(x: 0, y: 0, width: width, height: height))
        context.strokePath()
        
        context.beginPath()
        context.move(to: CGPoint(x: midX, y: 0))
        context.addLine(to: CGPoint(x: midX, y: height))
        context.strokePath()
        
        context.beginPath()
        context.move(to: CGPoint(x: 0, y: midY))
        context.addLine(to: CGPoint(x: width, y: midY))
        context.strokePath()
        
        let fontSize: CGFloat = 36
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.red
        ]
        
        let quadrantCenters = [
            CGPoint(x: midX / 2, y: midY / 2),
            CGPoint(x: midX + midX / 2, y: midY / 2),
            CGPoint(x: midX / 2, y: midY + midY / 2),
            CGPoint(x: midX + midX / 2, y: midY + midY / 2)
        ]
        
        for (index, center) in quadrantCenters.enumerated() {
            let label = "\(index + 1)" as NSString
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            
            let textSize = label.size(withAttributes: textAttributes)
            let drawPoint = CGPoint(
                x: center.x - textSize.width / 2,
                y: center.y - textSize.height / 2
            )
            label.draw(at: drawPoint, withAttributes: textAttributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        
        guard let outputCG = context.makeImage() else {
            throw NSError(domain: "QuadrantError", code: 6,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create output image for quadrant rectangle"])
        }
        
        let rep = NSBitmapImageRep(cgImage: outputCG)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "QuadrantError", code: 7,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG representation for quadrant rectangle"])
        }
        
        try data.write(to: URL(fileURLWithPath: outputPath))
        print("✅ Quadrant rectangle saved to \(outputPath)")
    }
    
    /// Draw a grid overlay with configurable grid size
    static func drawGridOverlay(inputPath: String, outputPath: String, gridWidth: Int) throws {
        guard let inputImage = NSImage(contentsOfFile: inputPath),
              let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { 
            throw NSError(domain: "QuadrantError", code: 8, 
                         userInfo: [NSLocalizedDescriptionKey: "Could not load input image at \(inputPath)"])
        }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "QuadrantError", code: 9,
                         userInfo: [NSLocalizedDescriptionKey: "Could not create graphics context for grid overlay"])
        }
        
        // Draw original image
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Draw grid lines
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(2)
        
        let cellWidth = CGFloat(width) / CGFloat(gridWidth)
        let cellHeight = CGFloat(height) / CGFloat(gridWidth)
        
        // Draw vertical lines
        for i in 0...gridWidth {
            let xPos = CGFloat(i) * cellWidth
            context.beginPath()
            context.move(to: CGPoint(x: xPos, y: 0))
            context.addLine(to: CGPoint(x: xPos, y: CGFloat(height)))
            context.strokePath()
        }
        
        // Draw horizontal lines
        for j in 0...gridWidth {
            let yPos = CGFloat(j) * cellHeight
            context.beginPath()
            context.move(to: CGPoint(x: 0, y: yPos))
            context.addLine(to: CGPoint(x: CGFloat(width), y: yPos))
            context.strokePath()
        }
        
        // Draw cell numbers
        let fontSize: CGFloat = min(cellWidth, cellHeight) * 0.3
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.red
        ]
        
        for row in 0..<gridWidth {
            for col in 0..<gridWidth {
                let cellNumber = row * gridWidth + col + 1
                let centerX = (CGFloat(col) + 0.5) * cellWidth
                // Flip the Y coordinate so cell 1 appears at top-left
                let centerY = (CGFloat(gridWidth - 1 - row) + 0.5) * cellHeight
                
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
        
        guard let outputCG = context.makeImage() else {
            throw NSError(domain: "QuadrantError", code: 10,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create output image for grid overlay"])
        }
        
        let rep = NSBitmapImageRep(cgImage: outputCG)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "QuadrantError", code: 11,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG representation for grid overlay"])
        }
        
        try data.write(to: URL(fileURLWithPath: outputPath))
        print("✅ Grid overlay (\(gridWidth)x\(gridWidth)) saved to \(outputPath)")
    }
    
    /// Calculate bounds for a specific grid cell
    static func calculateGridCellBounds(topLeft: CGPoint, bottomRight: CGPoint, gridWidth: Int, cellNumber: Int) -> GridBounds? {
        guard cellNumber >= 1 && cellNumber <= gridWidth * gridWidth else {
            print("❌ Invalid cell number \(cellNumber) for \(gridWidth)x\(gridWidth) grid")
            return nil
        }
        
        let totalWidth = bottomRight.x - topLeft.x
        let totalHeight = bottomRight.y - topLeft.y
        let cellWidth = totalWidth / CGFloat(gridWidth)
        let cellHeight = totalHeight / CGFloat(gridWidth)
        
        // Convert cell number to row/col (1-based to 0-based)
        let row = (cellNumber - 1) / gridWidth
        let col = (cellNumber - 1) % gridWidth
        
        print("🔍 Cell \(cellNumber) maps to row \(row), col \(col) in \(gridWidth)x\(gridWidth) grid")
        
        let newTopLeft = CGPoint(
            x: topLeft.x + CGFloat(col) * cellWidth,
            y: topLeft.y + CGFloat(row) * cellHeight
        )
        
        let newBottomRight = CGPoint(
            x: topLeft.x + CGFloat(col + 1) * cellWidth,
            y: topLeft.y + CGFloat(row + 1) * cellHeight
        )
        
        print("🔍 Calculated bounds: (\(newTopLeft.x), \(newTopLeft.y)) to (\(newBottomRight.x), \(newBottomRight.y))")
        
        return GridBounds(topLeft: newTopLeft, bottomRight: newBottomRight)
    }
}

// MARK: - Automation Functions
class AutomationManager {
    
    /// Activate an app by name
    static func activateApp(named appName: String) -> Bool {
        // First, check if the app is already running
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == appName
        }) {
            // App is running, just activate it
            return app.activate(options: [.activateAllWindows])
        }
        
        // App is not running, try to launch it
        print("App \(appName) not running. Attempting to launch...")
        
        // Try to find the app bundle URL
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appName) ??
                        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.\(appName.lowercased())") {
            
            let configuration = NSWorkspace.OpenConfiguration()
            let semaphore = DispatchSemaphore(value: 0)
            var launchSuccess = false
            
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
                if let error = error {
                    print("Failed to launch \(appName): \(error)")
                } else {
                    print("Successfully launched \(appName)")
                    launchSuccess = true
                }
                semaphore.signal()
            }
            
            semaphore.wait()
            
            if launchSuccess {
                // Give the app time to start up
                usleep(2_000_000) // 2 seconds
                
                // Now try to activate it
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.localizedName == appName
                }) {
                    return app.activate(options: [.activateAllWindows])
                }
            }
        } else {
            // Fallback: try opening by name using URL scheme
            if let appURL = URL(string: "\(appName.lowercased())://") {
                NSWorkspace.shared.open(appURL)
                usleep(2_000_000) // 2 seconds
                
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.localizedName == appName
                }) {
                    return app.activate(options: [.activateAllWindows])
                }
            }
            print("Failed to find or launch \(appName)")
        }
        
        return false
    }

    /// Simulate mouse click at coordinates
    static func click(at point: CGPoint) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, 
                          mouseCursorPosition: point, mouseButton: .left)!
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, 
                          mouseCursorPosition: point, mouseButton: .left)!
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, 
                        mouseCursorPosition: point, mouseButton: .left)!
        
        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        print("✅ Clicked at (\(point.x), \(point.y))")
    }

    /// Type text using keyboard events
    static func typeText(_ text: String) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        for scalar in text.unicodeScalars {
            let chars = [UniChar](String(scalar).utf16)
            
            // Key down
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
            chars.withUnsafeBufferPointer { buf in
                keyDown.keyboardSetUnicodeString(stringLength: buf.count, 
                                               unicodeString: buf.baseAddress)
            }
            keyDown.post(tap: .cghidEventTap)
            
            // Key up
            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
            chars.withUnsafeBufferPointer { buf in
                keyUp.keyboardSetUnicodeString(stringLength: buf.count, 
                                             unicodeString: buf.baseAddress)
            }
            keyUp.post(tap: .cghidEventTap)
        }
        print("✅ Typed: \(text)")
    }

    /// Get window position and bounds for an app
    static func getWindowBounds(appName: String) -> CGRect? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

        guard let cfArray = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) else {
            print("❌ Unable to fetch window list for bounds")
            return nil
        }
        guard let info = (cfArray as NSArray) as? [[String: Any]] else {
            print("❌ Unexpected format for window list")
            return nil
        }

        guard let win = info.first(where: {
            ($0[kCGWindowOwnerName as String] as? String) == appName
        }),
        let boundsDict = win[kCGWindowBounds as String] as? [String: Any],
        let x = boundsDict["X"] as? CGFloat,
        let y = boundsDict["Y"] as? CGFloat,
        let width = boundsDict["Width"] as? CGFloat,
        let height = boundsDict["Height"] as? CGFloat else {
            print("❌ No window bounds found for \(appName)")
            return nil
        }

        let windowBounds = CGRect(x: x, y: y, width: width, height: height)
        print("📐 Window bounds for \(appName): \(windowBounds)")
        return windowBounds
    }
}

// MARK: - Utility Functions
/// Calculate coordinates from quadrant number
func calculateCoordinatesFromQuadrant(_ quadrantNumber: Int, imagePath: String, spacing: Int) -> CGPoint? {
    guard let image = NSImage(contentsOfFile: imagePath) else { return nil }
    
    let width = Int(image.size.width)
    let height = Int(image.size.height)
    let cols = Int(ceil(Double(width) / Double(spacing)))
    
    let rowIndex = (quadrantNumber - 1) / cols
    let colIndex = (quadrantNumber - 1) % cols
    
    let xStart = colIndex * spacing
    let xEnd = min((colIndex + 1) * spacing, width)
    let centerX = (xStart + xEnd) / 2
    
    let yStart = rowIndex * spacing
    let yEnd = min((rowIndex + 1) * spacing, height)
    let centerY = (yStart + yEnd) / 2
    
    return CGPoint(x: centerX, y: centerY)
}

// MARK: - Main Orchestrator
class UIAutomationOrchestrator {
    
    /// Main entry point for task execution
    static func executeTask(_ taskInput: String) {
        print("🚀 Starting task execution: \(taskInput)")
        
        // Step 1: Determine tool calls needed
        let toolCalls = LLMClient.determineToolCalls(for: taskInput)
        print("📋 Determined \(toolCalls.count) tool calls needed")
        
        // Step 2: Execute each tool call in sequence
        for (index, toolCall) in toolCalls.enumerated() {
            print("\n⚡ Executing tool call \(index + 1)/\(toolCalls.count): \(toolCall.type)")
            
            switch toolCall.type {
            case "click":
                // executeClickAction(toolCall)
                executeClickActionImproved(toolCall)
            case "type":
                executeTypeAction(toolCall)
            case "screenshot":
                executeScreenshotAction(toolCall)
            case "activate_app":
                executeActivateAppAction(toolCall)
            default:
                print("❌ Unknown tool call type: \(toolCall.type)")
            }
            
            // Small delay between actions
            usleep(500_000) // 0.5 seconds
        }
        
        print("\n✅ Task execution completed!")
    }
    
    /// Execute click action with recursive quadrant analysis
    private static func executeClickActionImproved(_ toolCall: ToolCall) {
        guard let target = toolCall.parameters["target"] as? String,
              let appName = toolCall.parameters["appName"] as? String else {
            print("❌ Invalid click parameters")
            return
        }
        
        print("🎯 Executing improved click on '\(target)' in '\(appName)'")
        
        // Activate the target app
        guard AutomationManager.activateApp(named: appName) else {
            print("❌ Failed to activate app: \(appName)")
            return
        }
        usleep(300_000) // Wait for app to come to front
        
        do {
            // Take full screenshot
            print("📸 Taking full screenshot...")
            try ScreenshotManager.captureAppWindow(appName: appName, outputPath: Config.screenshotPath)
            
            // Get image dimensions for initial bounds
            guard let image = NSImage(contentsOfFile: Config.screenshotPath) else {
                print("❌ Failed to load screenshot")
                return
            }
            
            let topLeft = CGPoint(x: 0, y: 0)
            let bottomRight = CGPoint(x: image.size.width, y: image.size.height)
            
            print("🔄 Starting iterative quadrant analysis...")
            print("📏 Initial bounds: (\(topLeft.x), \(topLeft.y)) to (\(bottomRight.x), \(bottomRight.y))")
            
            // Use iterative quadrant analysis
            guard let relativeClickPoint = LLMClient.iterativeQuadrantAnalysis(
                topLeft: topLeft,
                bottomRight: bottomRight,
                target: target,
                iterations: 3,
                gridWidth: 4
            ) else {
                print("❌ Failed to determine click coordinates through iterative analysis")
                return
            }
            
            print("📍 Relative click coordinates: (\(relativeClickPoint.x), \(relativeClickPoint.y))")
            
            // Get window bounds to adjust coordinates
            guard let windowBounds = AutomationManager.getWindowBounds(appName: appName) else {
                print("❌ Failed to get window bounds, using relative coordinates")
                AutomationManager.click(at: relativeClickPoint)
                return
            }
            
            // Calculate scaling factors for each dimension
            let scaleX = image.size.width / windowBounds.width  // e.g., 3024 / 1511 ≈ 2.0
            let scaleY = image.size.height / windowBounds.height // e.g., 1964 / 981 ≈ 2.0
            
            print("📐 Image size: \(image.size.width) × \(image.size.height)")
            print("📐 Window size: \(windowBounds.width) × \(windowBounds.height)")
            print("📐 Scale factors: X=\(scaleX), Y=\(scaleY)")
            
            // Adjust coordinates: scale down by dimension-specific factors, then add window offset
            let finalClickPoint = CGPoint(
                x: windowBounds.origin.x + (relativeClickPoint.x / scaleX),
                y: windowBounds.origin.y + (relativeClickPoint.y / scaleY)
            )
            
            print("🎯 Final adjusted click coordinates: (\(finalClickPoint.x), \(finalClickPoint.y))")
            print("📐 Window offset: (\(windowBounds.origin.x), \(windowBounds.origin.y))")
            
            // Execute the click
            AutomationManager.click(at: finalClickPoint)
            
        } catch {
            print("❌ Error during improved click execution: \(error)")
        }
    }

    /// Execute click action with two-stage screenshot analysis
    private static func executeClickAction(_ toolCall: ToolCall) {
        guard let target = toolCall.parameters["target"] as? String,
              let appName = toolCall.parameters["appName"] as? String else {
            print("❌ Invalid click parameters")
            return
        }
        
        print("🎯 Executing click on '\(target)' in '\(appName)'")
        
        // Activate the target app
        guard AutomationManager.activateApp(named: appName) else {
            print("❌ Failed to activate app: \(appName)")
            return
        }
        usleep(300_000) // Wait for app to come to front
        
        do {
            // Stage 1: Take full screenshot and get initial quadrant
            print("📸 Stage 1: Taking full screenshot...")
            try ScreenshotManager.captureAppWindow(appName: appName, outputPath: Config.screenshotPath)
            
            print("🔢 Creating initial quadrant overlay...")
            try QuadrantManager.createQuadrantOverlay(
                inputPath: Config.screenshotPath, 
                outputPath: Config.quadrantImagePath,
                spacing: Config.initialGridSpacing
            )
            
            print("🧠 Analyzing for initial target location...")
            guard let initialResult = LLMClient.analyzeImageForInitialQuadrant(
                imagePath: Config.quadrantImagePath, 
                target: target
            ) else {
                print("❌ Failed to determine initial quadrant")
                return
            }
            
            print("✅ Initial quadrant: \(initialResult.quadrantNumber), center: (\(initialResult.centerPoint.x), \(initialResult.centerPoint.y))")
            
            // Stage 2: Crop image around initial target area
            print("✂️ Stage 2: Cropping image around target area...")
            try ImageProcessor.cropImage(
                inputPath: Config.screenshotPath,
                outputPath: Config.croppedImagePath,
                centerPoint: initialResult.centerPoint,
                cropSize: Config.cropSize
            )
            
            print("🔢 Creating refined quadrant overlay...")
            try QuadrantManager.createQuadrantOverlay(
                inputPath: Config.croppedImagePath,
                outputPath: Config.refinedQuadrantPath,
                spacing: Config.refinedGridSpacing
            )
            
            print("🧠 Analyzing refined target location...")
            guard let refinedResult = LLMClient.analyzeImageForRefinedQuadrant(
                imagePath: Config.refinedQuadrantPath,
                target: target
            ) else {
                print("❌ Failed to determine refined quadrant")
                return
            }
            
            print("✅ Refined quadrant: \(refinedResult.quadrantNumber), center: (\(refinedResult.centerPoint.x), \(refinedResult.centerPoint.y))")
            
            // Stage 3: Calculate final coordinates
            let cropOffset = CGPoint(
                x: max(0, initialResult.centerPoint.x - CGFloat(Config.cropSize) / 2),
                y: max(0, initialResult.centerPoint.y - CGFloat(Config.cropSize) / 2)
            )
            
            let finalClickPoint = CGPoint(
                x: cropOffset.x + refinedResult.centerPoint.x,
                y: cropOffset.y + refinedResult.centerPoint.y
            )
            
            print("🎯 Final click coordinates: (\(finalClickPoint.x), \(finalClickPoint.y))")
            
            // Step 4: Execute the click
            AutomationManager.click(at: finalClickPoint)
            
        } catch {
            print("❌ Error during click execution: \(error)")
        }
    }
    
    /// Execute type action
    private static func executeTypeAction(_ toolCall: ToolCall) {
        guard let text = toolCall.parameters["text"] as? String,
              let appName = toolCall.parameters["appName"] as? String else {
            print("❌ Invalid type parameters")
            return
        }
        
        print("⌨️ Typing '\(text)' in '\(appName)'")
        
        // Activate the target app
        guard AutomationManager.activateApp(named: appName) else {
            print("❌ Failed to activate app: \(appName)")
            return
        }
        usleep(200_000) // Wait for app to be ready
        
        AutomationManager.typeText(text)
    }
    
    /// Execute screenshot action
    private static func executeScreenshotAction(_ toolCall: ToolCall) {
        guard let appName = toolCall.parameters["appName"] as? String else {
            print("❌ Invalid screenshot parameters")
            return
        }
        
        print("📸 Taking screenshot of '\(appName)'")
        
        do {
            try ScreenshotManager.captureAppWindow(appName: appName)
            print("✅ Screenshot saved to \(Config.screenshotPath)")
        } catch {
            print("❌ Error taking screenshot: \(error)")
        }
    }
    
    private static func executeActivateAppAction(_ toolCall: ToolCall) {
        guard let appName = toolCall.parameters["appName"] as? String else {
            print("❌ Invalid activate_app parameters")
            return
        }
        
        print("🔄 Activating app '\(appName)'")
        
        if AutomationManager.activateApp(named: appName) {
            print("✅ App '\(appName)' activated successfully")
        } else {
            print("❌ Failed to activate app '\(appName)'")
        }
    }
}

// MARK: - Command Line Interface
func main() {
    // let args = CommandLine.arguments
    // 
    // if args.count < 2 {
    //     print("Usage: swift automation.swift \"<task>\"")
    //     print("Example: swift automation.swift \"enter 'hello' into Claude\"")
    //     exit(1)
    // }
    
    // let task = args[1]

    let task = "enter '1+1=?\n' into Claude" // Example task, replace with actual input
    print("🔍 Analyzing task: \(task)")
    UIAutomationOrchestrator.executeTask(task)
    // _ = AutomationManager.activateApp(named: "Claude")
}

// MARK: - Entry Point
main()
