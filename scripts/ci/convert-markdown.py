#!/usr/bin/env python3
import markdown
import sys
import os

def convert_markdown_to_html(markdown_file, output_html_file):
    """
    Convert markdown content to HTML with dark mode support

    Args:
        markdown_file (str): Path to the markdown file
        output_html_file (str): Path to output HTML file
    """
    # Read markdown content
    with open(markdown_file, 'r', encoding='utf-8') as f:
        content = f.read()

    # Convert markdown to HTML
    html_content = markdown.markdown(content, extensions=['fenced_code', 'tables', 'nl2br'])

    # Create HTML document with dark mode support
    html_document = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Release Notes</title>
    <style>
        :root {{
            color-scheme: light dark;
        }}

        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            line-height: 1.6;
            padding: 20px;
            max-width: 800px;
            margin: 0 auto;
        }}

        h1, h2, h3, h4, h5, h6 {{
            font-weight: 600;
        }}

        code {{
            font-family: monospace;
            background-color: rgba(150, 150, 150, 0.1);
            padding: 2px 4px;
            border-radius: 3px;
        }}

        pre {{
            background-color: rgba(150, 150, 150, 0.1);
            padding: 16px;
            border-radius: 5px;
            overflow-x: auto;
        }}

        pre code {{
            background-color: transparent;
            padding: 0;
        }}

        @media (prefers-color-scheme: dark) {{
            body {{
                background-color: #1a1a1a;
                color: #f0f0f0;
            }}
            a {{
                color: #4dabf7;
            }}
        }}

        @media (prefers-color-scheme: light) {{
            body {{
                background-color: #ffffff;
                color: #121212;
            }}
            a {{
                color: #0366d6;
            }}
        }}
    </style>
</head>
<body>
    {html_content}
</body>
</html>"""

    # Write HTML to file
    with open(output_html_file, 'w', encoding='utf-8') as f:
        f.write(html_document)

    print(f"Converted {markdown_file} to {output_html_file}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python convert-markdown.py <markdown_file> <output_html_file>")
        print("Example: python convert-markdown.py release_notes.md release_notes.html")
        sys.exit(1)

    markdown_file = sys.argv[1]
    output_html_file = sys.argv[2]

    convert_markdown_to_html(markdown_file, output_html_file)
