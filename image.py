import openai
import base64


def analyze_image(image_path, text_prompt, api_key=OPENAI_API_KEY):
    client = openai.OpenAI(api_key=api_key)
    
    with open(image_path, "rb") as image_file:
        base64_image = base64.b64encode(image_file.read()).decode('utf-8')
    
    response = client.chat.completions.create(
        model="gpt-4.1-mini-2025-04-14",
		# model="o4-mini-2025-04-16",
        messages=[
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": text_prompt},
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:image/jpeg;base64,{base64_image}"
                        }
                    }
                ]
            }
        ]
    )
    
    print(response.choices[0].message.content)

target = "submit text button"

quadrant_input = f"""
<task>
Identify which numbered section contains the {target} in the provided image.
</task>

<instructions>
1. Locate your target: the {target} in the image
2. Determine which red-numbered section it primarily occupies
3. If the input field spans multiple sections, choose the section that contains the center/majority of the target
4. Look specifically for text input elements like search bars, text boxes, or prompt input areas
</instructions>

<format>
Return only the section number (1-40) that best represents the location of the text input field.
</format>
"""

analyze_image("claude-2-result-2.png", quadrant_input)
