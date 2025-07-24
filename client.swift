#!/usr/bin/env swift

import Foundation


func analyzeImage(imagePath: String, textPrompt: String, apiKey: String = OPENAI_API_KEY) {
    // 1. Read and Base64-encode the image
    guard let imageData = FileManager.default.contents(atPath: imagePath) else {
        print("❌ Failed to read image at \(imagePath)")
        return
    }
    let base64Image = imageData.base64EncodedString()

    // 2. Prepare the HTTP request
    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // 3. Build the JSON payload
    let messageContent: [Any] = [
        ["type": "text", "text": textPrompt],
        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]]
    ]
    let message: [String: Any] = [
        "role": "user",
        "content": messageContent
    ]
    let payload: [String: Any] = [
        // "model": "gpt-4.1-mini-2025-04-14",
        "model": "gpt-4.1-2025-04-14",
        "messages": [message]
    ]

    guard let httpBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
        print("❌ Failed to serialize JSON payload")
        return
    }
    request.httpBody = httpBody

    // 4. Send the request synchronously
    let semaphore = DispatchSemaphore(value: 0)
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

        // 5. Parse the JSON response
        do {
            if
                let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let first = choices.first,
                let message = first["message"] as? [String: Any],
                let content = message["content"] as? String
            {
                print(content)
            } else {
                let text = String(data: data, encoding: .utf8) ?? "<invalid UTF-8>"
                print("❌ Unexpected response format:\n\(text)")
            }
        } catch {
            print("❌ JSON decode error:", error)
        }
    }.resume()
    semaphore.wait()
}

// ——————————————————————————————————————————
// Usage
let target = "input text field"
let quadrantInput = """
<task>
Identify which numbered section contains the \(target) in the provided image.
</task>

<instructions>
1. Locate your target: the \(target) in the image
2. Determine which red-numbered section it primarily occupies
3. If the input field spans multiple sections, choose the section that contains the center/majority of the target
4. Look specifically for text input elements like search bars, text boxes, or prompt input areas
</instructions>

<format>
Return only the section number (1-40) that best represents the location of the text input field.
</format>
"""

let finalInput = """
<task>
Identify which numbered section contains the \(target) in the provided image.
</task>

<instructions>
1. Locate your target: the \(target) in the image
2. Determine which red-number lies directly on top of the \(target)
3. Remember, this is for a mouse click, so the section number should be where the user mouse
would click on the interactive element: \(target)
3. Return that section number
</instructions>

<format>
Return only the section number (1-40) that best represents the location of the text input field.
</format>
"""

analyzeImage(imagePath: "claude-final-result.png", textPrompt: quadrantInput)
