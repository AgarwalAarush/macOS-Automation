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
    static func sendRequest(messages: [[String: Any]], model: String = "gpt-4.1-mini-2025-04-14", temperature: Double = 0.7) -> String {
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
    
    /// Enhanced iterative quadrant analysis with configurable first iteration and padding
    static func iterativeQuadrantAnalysisEnhanced(
        topLeft: CGPoint, 
        bottomRight: CGPoint, 
        target: String, 
        iterations: Int = 3, 
        gridWidth: Int = 2,
        paddingFactor: CGFloat = 1.0
    ) -> CGPoint? {
        
        // PHASE 1: INITIALIZATION
        print("🚀 Phase 1: Initialization")
        
        // Starting inputs and state tracking
        let initialCroppedBounds = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        var imageCoordinateHistory: [CGRect] = []
        var gridOverlayHistory: [CGRect] = []
        var currentImageBounds = initialCroppedBounds
        
        print("📍 Initial region: (\(topLeft.x), \(topLeft.y)) to (\(bottomRight.x), \(bottomRight.y))")
        print("🔧 Parameters: iterations=\(iterations), gridWidth=\(gridWidth), paddingFactor=\(paddingFactor)")
        
        // PHASE 2: ITERATIVE REFINEMENT LOOP
        print("\n🔄 Phase 2: Iterative Refinement Loop")
        
        var currentImagePath = Config.screenshotPath  // Start with original screenshot
        var currentCropBounds = CGRect(x: 0, y: 0, width: 3216, height: 2080)  // Assume full screenshot bounds
        
        for iteration in 0..<iterations {
            print("\n--- 🔍 Iteration \(iteration + 1)/\(iterations) ---")
            
            let quadrantOverlayPath = "enhanced_quadrant_\(iteration).png"
            
            do {
                // Grid Overlay Application
                print("📸 Applying enhanced grid overlay to current image: \(currentImagePath)")
                
                // Always use enhanced grid overlay with boundary visualization
                // For iteration 0, the boundary covers the entire image so it won't be visible
                try QuadrantManager.drawEnhancedGridOverlay(
                    inputPath: currentImagePath,
                    outputPath: quadrantOverlayPath,
                    gridWidth: gridWidth,
                    originalTargetBounds: currentImageBounds,
                    actualCropBounds: currentCropBounds
                )
                
                // LLM Region Selection
                print("🧠 Sending grid-overlaid image to LLM for region selection...")
                let selectedGridCell = analyzeGridChoice(imagePath: quadrantOverlayPath, target: target, gridWidth: gridWidth)
                print("✅ LLM selected grid cell: \(selectedGridCell)")
                
                // Coordinate Calculation - Always use enhanced coordinate mapping
                print("🔄 Calculating new bounds from grid selection...")
                
                guard let newBounds = QuadrantManager.calculateEnhancedGridCellBoundsFromCrop(
                    originalTargetBounds: currentImageBounds,
                    actualCropBounds: currentCropBounds,
                    gridWidth: gridWidth,
                    cellNumber: selectedGridCell
                ) else {
                    print("❌ Failed to calculate bounds for cell \(selectedGridCell)")
                    return nil
                }
                
                // Update current target region to the selected box coordinates
                currentImageBounds = CGRect(
                    x: newBounds.topLeft.x, 
                    y: newBounds.topLeft.y, 
                    width: newBounds.bottomRight.x - newBounds.topLeft.x, 
                    height: newBounds.bottomRight.y - newBounds.topLeft.y
                )
                
                print("📏 New target region: (\(currentImageBounds.minX), \(currentImageBounds.minY)) to (\(currentImageBounds.maxX), \(currentImageBounds.maxY))")
                
                // Image Cropping & State Update (prepare for next iteration)
                if iteration < iterations - 1 {  // Don't crop after the last iteration
                    print("✂️ Cropping image for next iteration with boundary-aware padding...")
                    
                    let nextCroppedImagePath = "enhanced_cropped_\(iteration).png"
                    
                    // Apply padding with boundary checking and crop original screenshot
                    let actualCropBounds = try ImageProcessor.cropImageWithPadding(
                        inputPath: Config.screenshotPath,  // Always crop from original for coordinate consistency
                        outputPath: nextCroppedImagePath,
                        targetTopLeft: CGPoint(x: currentImageBounds.minX, y: currentImageBounds.minY),
                        targetBottomRight: CGPoint(x: currentImageBounds.maxX, y: currentImageBounds.maxY),
                        paddingFactor: paddingFactor
                    )
                    
                    // Update state for next iteration
                    currentImagePath = nextCroppedImagePath
                    currentCropBounds = actualCropBounds
                    
                    print("📦 Cropped image with padding: (\(actualCropBounds.minX), \(actualCropBounds.minY)) to (\(actualCropBounds.maxX), \(actualCropBounds.maxY))")
                }
                
                // Track coordinate history for final mapping
                imageCoordinateHistory.append(currentImageBounds)
                gridOverlayHistory.append(currentCropBounds)
                
            } catch {
                print("❌ Error in iteration \(iteration): \(error)")
                return nil
            }
        }
        
        // PHASE 3: FINAL COORDINATE RESOLUTION
        print("\n📍 Phase 3: Final Coordinate Resolution")
        
        // Grid-to-Image Mapping: Final grid selection already converted to image coordinates above
        let finalImageCoordinates = currentImageBounds
        print("🎯 Final image coordinates: (\(finalImageCoordinates.minX), \(finalImageCoordinates.minY)) to (\(finalImageCoordinates.maxX), \(finalImageCoordinates.maxY))")
        
        // Image-to-Screenshot Mapping: Coordinates are already relative to original screenshot
        // (This is maintained throughout our coordinate tracking)
        
        // Screenshot-to-Screen Mapping: Calculate final screen coordinates
        let centerX = (finalImageCoordinates.minX + finalImageCoordinates.maxX) / 2
        let centerY = (finalImageCoordinates.minY + finalImageCoordinates.maxY) / 2
        
        // Account for 30x30 padding in initial screenshot capture
        let finalScreenX = centerX + 30
        let finalScreenY = centerY + 30
        
        let finalCoordinates = CGPoint(x: finalScreenX, y: finalScreenY)
        print("🎯 Final screen coordinates (with 30x30 offset): (\(finalCoordinates.x), \(finalCoordinates.y))")
        print("✅ Enhanced iterative analysis complete!")
        
        return finalCoordinates
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
    
    /// Remove pixels from edges of an image with individual control per edge
    static func removeEdgePixels(inputPath: String, outputPath: String, top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) throws {
        guard let srcImage = NSImage(contentsOfFile: inputPath) else {
            throw NSError(domain: "ImageError", code: 9,
                         userInfo: [NSLocalizedDescriptionKey: "Could not load image at \(inputPath)"])
        }

        guard let cg = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "ImageError", code: 10,
                         userInfo: [NSLocalizedDescriptionKey: "Could not get CGImage from NSImage"])
        }

        let originalWidth = CGFloat(cg.width)
        let originalHeight = CGFloat(cg.height)
        
        let topFloat = CGFloat(top)
        let bottomFloat = CGFloat(bottom)
        let leftFloat = CGFloat(left)
        let rightFloat = CGFloat(right)
        
        // Calculate new dimensions by removing pixels from specified edges
        let newWidth = originalWidth - leftFloat - rightFloat
        let newHeight = originalHeight - topFloat - bottomFloat
        
        // Validate that we're not removing more pixels than the image has
        guard newWidth > 0 && newHeight > 0 else {
            throw NSError(domain: "ImageError", code: 13,
                         userInfo: [NSLocalizedDescriptionKey: "Cannot remove more pixels than image dimensions allow"])
        }
        
        // Create crop rectangle that removes pixels from specified edges
        // In Core Graphics coordinates, Y=0 is at bottom, so we start from bottom edge
        let cropRect = CGRect(
            x: leftFloat,
            y: bottomFloat, 
            width: newWidth,
            height: newHeight
        )

        guard let croppedCG = cg.cropping(to: cropRect) else {
            throw NSError(domain: "ImageError", code: 11,
                         userInfo: [NSLocalizedDescriptionKey: "Edge pixel removal failed"])
        }

        let croppedImage = NSImage(cgImage: croppedCG, size: CGSize(width: newWidth, height: newHeight))

        guard let tiffData = croppedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ImageError", code: 12,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to encode edge-processed image as PNG"])
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath))
        print("✅ Removed pixels from edges: top=\(top), bottom=\(bottom), left=\(left), right=\(right)")
        print("📐 Original: \(originalWidth) x \(originalHeight) → New: \(newWidth) x \(newHeight)")
    }
    
    /// Convenience method to remove the same number of pixels from all edges
    static func removeEdgePixels(inputPath: String, outputPath: String, pixelsToRemove: Int) throws {
        try removeEdgePixels(inputPath: inputPath, outputPath: outputPath, 
                           top: pixelsToRemove, bottom: pixelsToRemove, 
                           left: pixelsToRemove, right: pixelsToRemove)
    }
    
    /// Crop image with padding around target region for enhanced context
    static func cropImageWithPadding(inputPath: String, outputPath: String, targetTopLeft: CGPoint, targetBottomRight: CGPoint, paddingFactor: CGFloat = 2.0) throws -> CGRect {
        guard let srcImage = NSImage(contentsOfFile: inputPath) else {
            throw NSError(domain: "ImageError", code: 5,
                         userInfo: [NSLocalizedDescriptionKey: "Could not load image at \(inputPath)"])
        }

        guard let cg = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "ImageError", code: 6,
                         userInfo: [NSLocalizedDescriptionKey: "Could not get CGImage from NSImage"])
        }

        // Calculate target region dimensions
        let targetWidth = targetBottomRight.x - targetTopLeft.x
        let targetHeight = targetBottomRight.y - targetTopLeft.y
        
        // Calculate desired padded crop dimensions
        let desiredPaddedWidth = targetWidth * paddingFactor
        let desiredPaddedHeight = targetHeight * paddingFactor
        
        // Calculate target center
        let targetCenterX = (targetTopLeft.x + targetBottomRight.x) / 2
        let targetCenterY = (targetTopLeft.y + targetBottomRight.y) / 2
        
        // Calculate ideal padded crop rectangle (may extend beyond image bounds)
        let idealLeft = targetCenterX - desiredPaddedWidth / 2
        let idealTop = targetCenterY - desiredPaddedHeight / 2
        let idealRight = targetCenterX + desiredPaddedWidth / 2
        let idealBottom = targetCenterY + desiredPaddedHeight / 2
        
        // Image bounds
        let imageWidth = CGFloat(cg.width)
        let imageHeight = CGFloat(cg.height)
        
        // Calculate actual crop bounds considering all edge cases
        var actualLeft = idealLeft
        var actualTop = idealTop
        var actualRight = idealRight
        var actualBottom = idealBottom
        
        // Handle left edge: if ideal left < 0, shift the entire crop right
        if idealLeft < 0 {
            let leftShift = -idealLeft
            actualLeft = 0
            actualRight = min(imageWidth, idealRight + leftShift)
        }
        
        // Handle right edge: if ideal right > imageWidth, shift the entire crop left
        if idealRight > imageWidth {
            let rightShift = idealRight - imageWidth
            actualRight = imageWidth
            actualLeft = max(0, idealLeft - rightShift)
        }
        
        // Handle top edge: if ideal top < 0, shift the entire crop down
        if idealTop < 0 {
            let topShift = -idealTop
            actualTop = 0
            actualBottom = min(imageHeight, idealBottom + topShift)
        }
        
        // Handle bottom edge: if ideal bottom > imageHeight, shift the entire crop up
        if idealBottom > imageHeight {
            let bottomShift = idealBottom - imageHeight
            actualBottom = imageHeight
            actualTop = max(0, idealTop - bottomShift)
        }
        
        // Handle corner cases: ensure we don't exceed image bounds after shifting
        actualLeft = max(0, actualLeft)
        actualTop = max(0, actualTop)
        actualRight = min(imageWidth, actualRight)
        actualBottom = min(imageHeight, actualBottom)
        
        // Final crop rectangle
        let finalCropRect = CGRect(
            x: actualLeft,
            y: actualTop,
            width: actualRight - actualLeft,
            height: actualBottom - actualTop
        )
        
        print("🛡️ Boundary-aware padding calculation:")
        print("   📐 Desired padded bounds: (\(idealLeft), \(idealTop)) to (\(idealRight), \(idealBottom))")
        print("   🚧 Constrained to screenshot: (\(actualLeft), \(actualTop)) to (\(actualRight), \(actualBottom))")
        print("   ✂️ Final crop region: origin(\(finalCropRect.origin.x), \(finalCropRect.origin.y)) size(\(finalCropRect.width) x \(finalCropRect.height))")

        guard let croppedCG = cg.cropping(to: finalCropRect) else {
            throw NSError(domain: "ImageError", code: 7,
                         userInfo: [NSLocalizedDescriptionKey: "Enhanced cropping failed"])
        }

        let croppedImage = NSImage(cgImage: croppedCG, size: finalCropRect.size)

        guard let tiffData = croppedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ImageError", code: 8,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to encode enhanced cropped image as PNG"])
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath))
        print("✅ Enhanced cropped image with padding saved to \(outputPath)")
        print("📐 Target region: (\(targetTopLeft.x), \(targetTopLeft.y)) to (\(targetBottomRight.x), \(targetBottomRight.y))")
        print("📐 Padded crop: (\(finalCropRect.origin.x), \(finalCropRect.origin.y)) size (\(finalCropRect.width), \(finalCropRect.height))")
        
        return finalCropRect
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
        
        print("🎯 LLM selected cell \(cellNumber) → grid position [row \(row), col \(col)] in \(gridWidth)x\(gridWidth) grid")
        
        let newTopLeft = CGPoint(
            x: topLeft.x + CGFloat(col) * cellWidth,
            y: topLeft.y + CGFloat(row) * cellHeight
        )
        
        let newBottomRight = CGPoint(
            x: topLeft.x + CGFloat(col + 1) * cellWidth,
            y: topLeft.y + CGFloat(row + 1) * cellHeight
        )
        
        print("✅ Calculated new target region: (\(newTopLeft.x), \(newTopLeft.y)) to (\(newBottomRight.x), \(newBottomRight.y))")
        
        return GridBounds(topLeft: newTopLeft, bottomRight: newBottomRight)
    }
    
    /// Draw enhanced grid overlay with boundary box and padding context
    static func drawEnhancedGridOverlay(inputPath: String, outputPath: String, gridWidth: Int, originalTargetBounds: CGRect, actualCropBounds: CGRect) throws {
        guard let inputImage = NSImage(contentsOfFile: inputPath),
              let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { 
            throw NSError(domain: "QuadrantError", code: 12, 
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
            throw NSError(domain: "QuadrantError", code: 13,
                         userInfo: [NSLocalizedDescriptionKey: "Could not create graphics context for enhanced grid overlay"])
        }
        
        // Draw original image
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Grid area is always the same size as the original target
        let gridAreaWidth = originalTargetBounds.width
        let gridAreaHeight = originalTargetBounds.height
        
        // Position grid area exactly where the original target appears within the crop
        let gridAreaX = originalTargetBounds.origin.x - actualCropBounds.origin.x
        // Convert from image coordinates (Y=0 at top) to Core Graphics coordinates (Y=0 at bottom)
        let gridAreaY = CGFloat(height) - (originalTargetBounds.origin.y - actualCropBounds.origin.y) - gridAreaHeight
        
        print("📍 Target region in screenshot coords: origin(\(originalTargetBounds.origin.x), \(originalTargetBounds.origin.y)) size(\(originalTargetBounds.width) x \(originalTargetBounds.height))")
        print("📦 Cropped image bounds in screenshot coords: origin(\(actualCropBounds.origin.x), \(actualCropBounds.origin.y)) size(\(actualCropBounds.width) x \(actualCropBounds.height))")
        print("🎯 Target position within cropped image: (\(gridAreaX), \(gridAreaY)) size(\(gridAreaWidth) x \(gridAreaHeight))")
        
        let gridAreaRect = CGRect(x: gridAreaX, y: gridAreaY, width: gridAreaWidth, height: gridAreaHeight)
        
        // Draw boundary box around the grid area
        context.setStrokeColor(NSColor.blue.cgColor)
        context.setLineWidth(4)
        context.beginPath()
        context.addRect(gridAreaRect)
        context.strokePath()
        
        // Draw grid lines within the grid area only
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(2)
        
        let cellWidth = gridAreaWidth / CGFloat(gridWidth)
        let cellHeight = gridAreaHeight / CGFloat(gridWidth)
        
        // Draw vertical lines within grid area
        for i in 0...gridWidth {
            let xPos = gridAreaX + CGFloat(i) * cellWidth
            context.beginPath()
            context.move(to: CGPoint(x: xPos, y: gridAreaY))
            context.addLine(to: CGPoint(x: xPos, y: gridAreaY + gridAreaHeight))
            context.strokePath()
        }
        
        // Draw horizontal lines within grid area
        for j in 0...gridWidth {
            let yPos = gridAreaY + CGFloat(j) * cellHeight
            context.beginPath()
            context.move(to: CGPoint(x: gridAreaX, y: yPos))
            context.addLine(to: CGPoint(x: gridAreaX + gridAreaWidth, y: yPos))
            context.strokePath()
        }
        
        // Draw cell numbers within the grid area
        let fontSize: CGFloat = min(cellWidth, cellHeight) * 0.3
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.red
        ]
        
        for row in 0..<gridWidth {
            for col in 0..<gridWidth {
                let cellNumber = row * gridWidth + col + 1
                let centerX = gridAreaX + (CGFloat(col) + 0.5) * cellWidth
                // In Core Graphics coordinates (Y=0 at bottom), flip row order so cell 1 appears at top-left
                let centerY = gridAreaY + (CGFloat(gridWidth - 1 - row) + 0.5) * cellHeight
                
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
            throw NSError(domain: "QuadrantError", code: 14,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create output image for enhanced grid overlay"])
        }
        
        let rep = NSBitmapImageRep(cgImage: outputCG)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "QuadrantError", code: 15,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG representation for enhanced grid overlay"])
        }
        
        try data.write(to: URL(fileURLWithPath: outputPath))
        print("✅ Enhanced grid overlay (\(gridWidth)x\(gridWidth)) with boundary saved to \(outputPath)")
        print("📐 Grid area: (\(gridAreaX), \(gridAreaY)) size (\(gridAreaWidth), \(gridAreaHeight))")
    }
    
    /// Calculate bounds for enhanced grid cell with proper padding offset and edge handling
    static func calculateEnhancedGridCellBounds(
        originalTopLeft: CGPoint, 
        originalBottomRight: CGPoint, 
        gridWidth: Int, 
        cellNumber: Int, 
        paddingFactor: CGFloat = 2.0,
        gridCoverageRatio: CGFloat = 0.5,
        screenBounds: CGRect
    ) -> GridBounds? {
        guard cellNumber >= 1 && cellNumber <= gridWidth * gridWidth else {
            print("❌ Invalid cell number \(cellNumber) for \(gridWidth)x\(gridWidth) enhanced grid")
            return nil
        }
        
        // Original target region dimensions
        let originalWidth = originalBottomRight.x - originalTopLeft.x
        let originalHeight = originalBottomRight.y - originalTopLeft.y
        let originalCenterX = (originalTopLeft.x + originalBottomRight.x) / 2
        let originalCenterY = (originalTopLeft.y + originalBottomRight.y) / 2
        
        // Calculate desired padded crop dimensions
        let desiredPaddedWidth = originalWidth * paddingFactor
        let desiredPaddedHeight = originalHeight * paddingFactor
        
        // Calculate actual crop bounds considering screen edges
        let actualCropLeft = max(0, originalCenterX - desiredPaddedWidth / 2)
        let actualCropTop = max(0, originalCenterY - desiredPaddedHeight / 2)
        let actualCropRight = min(screenBounds.width, originalCenterX + desiredPaddedWidth / 2)
        let actualCropBottom = min(screenBounds.height, originalCenterY + desiredPaddedHeight / 2)
        
        let actualCropWidth = actualCropRight - actualCropLeft
        let actualCropHeight = actualCropBottom - actualCropTop
        
        // Calculate where the grid area appears within the actual crop
        let gridAreaWidth = actualCropWidth * gridCoverageRatio
        let gridAreaHeight = actualCropHeight * gridCoverageRatio
        let gridAreaLeft = actualCropLeft + (actualCropWidth - gridAreaWidth) / 2
        let gridAreaTop = actualCropTop + (actualCropHeight - gridAreaHeight) / 2
        
        // Calculate cell dimensions within the grid area
        let cellWidth = gridAreaWidth / CGFloat(gridWidth)
        let cellHeight = gridAreaHeight / CGFloat(gridWidth)
        
        // Convert cell number to row/col (1-based to 0-based)
        let row = (cellNumber - 1) / gridWidth
        let col = (cellNumber - 1) % gridWidth
        
        print("🎯 LLM selected cell \(cellNumber) → grid position [row \(row), col \(col)] in \(gridWidth)x\(gridWidth) grid")
        print("📏 Grid area bounds in screenshot coords: (\(gridAreaLeft), \(gridAreaTop)) to (\(gridAreaLeft + gridAreaWidth), \(gridAreaTop + gridAreaHeight))")
        
        // Calculate new bounds within the grid area (in screen coordinates)
        let newTopLeft = CGPoint(
            x: gridAreaLeft + CGFloat(col) * cellWidth,
            y: gridAreaTop + CGFloat(row) * cellHeight
        )
        
        let newBottomRight = CGPoint(
            x: gridAreaLeft + CGFloat(col + 1) * cellWidth,
            y: gridAreaTop + CGFloat(row + 1) * cellHeight
        )
        
        print("✅ Calculated new target region: (\(newTopLeft.x), \(newTopLeft.y)) to (\(newBottomRight.x), \(newBottomRight.y))")
        
        return GridBounds(topLeft: newTopLeft, bottomRight: newBottomRight)
    }
    
    /// Calculate bounds for enhanced grid cell using simplified logic
    static func calculateEnhancedGridCellBoundsFromCrop(
        originalTargetBounds: CGRect,
        actualCropBounds: CGRect,
        gridWidth: Int,
        cellNumber: Int
    ) -> GridBounds? {
        guard cellNumber >= 1 && cellNumber <= gridWidth * gridWidth else {
            print("❌ Invalid cell number \(cellNumber) for \(gridWidth)x\(gridWidth) enhanced grid")
            return nil
        }
        
        // Grid area is the original target size, positioned exactly where the target appears in the crop
        let gridAreaWidth = originalTargetBounds.width
        let gridAreaHeight = originalTargetBounds.height
        let gridAreaLeft = originalTargetBounds.origin.x
        let gridAreaTop = originalTargetBounds.origin.y
        
        // Calculate cell dimensions within the grid area
        let cellWidth = gridAreaWidth / CGFloat(gridWidth)
        let cellHeight = gridAreaHeight / CGFloat(gridWidth)
        
        // Convert cell number to row/col (1-based to 0-based)
        let row = (cellNumber - 1) / gridWidth
        let col = (cellNumber - 1) % gridWidth
        
        print("🎯 LLM selected cell \(cellNumber) → grid position [row \(row), col \(col)] in \(gridWidth)x\(gridWidth) grid")
        print("📏 Grid area bounds in screenshot coords: (\(gridAreaLeft), \(gridAreaTop)) to (\(gridAreaLeft + gridAreaWidth), \(gridAreaTop + gridAreaHeight))")
        
        // Calculate new bounds within the grid area (in screen coordinates)
        let newTopLeft = CGPoint(
            x: gridAreaLeft + CGFloat(col) * cellWidth,
            y: gridAreaTop + CGFloat(row) * cellHeight
        )
        
        let newBottomRight = CGPoint(
            x: gridAreaLeft + CGFloat(col + 1) * cellWidth,
            y: gridAreaTop + CGFloat(row + 1) * cellHeight
        )
        
        print("✅ Calculated new target region: (\(newTopLeft.x), \(newTopLeft.y)) to (\(newBottomRight.x), \(newBottomRight.y))")
        
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
                // executeClickActionImproved(toolCall)
                executeClickActionEnhanced(toolCall)
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

    /// Execute enhanced click action with contextual padding
    private static func executeClickActionEnhanced(_ toolCall: ToolCall) {
        guard let target = toolCall.parameters["target"] as? String,
              let appName = toolCall.parameters["appName"] as? String else {
            print("❌ Invalid click parameters")
            return
        }
        
        print("🎯 Executing enhanced click on '\(target)' in '\(appName)'")
        
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
            
            // Apply edge pixel removal transformation
            print("✂️ Applying edge pixel removal transformation...")
            try ImageProcessor.removeEdgePixels(
                inputPath: Config.screenshotPath,
                outputPath: Config.screenshotPath, // Overwrite the original
                top: 150,
                bottom: 80, 
                left: 120,
                right: 120
            )
            
            // Get image dimensions for initial bounds (after transformation)
            guard let image = NSImage(contentsOfFile: Config.screenshotPath) else {
                print("❌ Failed to load screenshot")
                return
            }
            
            let topLeft = CGPoint(x: 0, y: 0)
            let bottomRight = CGPoint(x: image.size.width, y: image.size.height)
            
            print("🔄 Starting enhanced iterative quadrant analysis...")
            print("📏 Initial bounds: (\(topLeft.x), \(topLeft.y)) to (\(bottomRight.x), \(bottomRight.y))")
            
            // Use enhanced iterative quadrant analysis
            guard let relativeClickPoint = LLMClient.iterativeQuadrantAnalysisEnhanced(
                topLeft: topLeft,
                bottomRight: bottomRight,
                target: target,
                iterations: 3,
                gridWidth: 4,
                paddingFactor: 2.0
            ) else {
                print("❌ Failed to determine click coordinates through enhanced analysis")
                return
            }
            
            print("📍 Enhanced relative click coordinates: (\(relativeClickPoint.x), \(relativeClickPoint.y))")
            
            // Get window bounds to adjust coordinates
            guard let windowBounds = AutomationManager.getWindowBounds(appName: appName) else {
                print("❌ Failed to get window bounds, using relative coordinates")
                AutomationManager.click(at: relativeClickPoint)
                return
            }
            
            // Calculate scaling factors for each dimension
            let scaleX = image.size.width / windowBounds.width
            let scaleY = image.size.height / windowBounds.height
            
            print("📐 Image size: \(image.size.width) × \(image.size.height)")
            print("📐 Window size: \(windowBounds.width) × \(windowBounds.height)")
            print("📐 Scale factors: X=\(scaleX), Y=\(scaleY)")
            
            // Adjust coordinates: scale down by dimension-specific factors, then add window offset
            let finalClickPoint = CGPoint(
                x: windowBounds.origin.x + (relativeClickPoint.x / scaleX),
                y: windowBounds.origin.y + (relativeClickPoint.y / scaleY)
            )
            
            print("🎯 Final enhanced click coordinates: (\(finalClickPoint.x), \(finalClickPoint.y))")
            print("📐 Window offset: (\(windowBounds.origin.x), \(windowBounds.origin.y))")
            
            // Execute the click
            AutomationManager.click(at: finalClickPoint)
            
        } catch {
            print("❌ Error during enhanced click execution: \(error)")
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

    let task = "enter 'What is a CNN?\n' into Claude" // Example task, replace with actual input
    print("🔍 Analyzing task: \(task)")
    UIAutomationOrchestrator.executeTask(task)
    
}

// MARK: - Entry Point
main()