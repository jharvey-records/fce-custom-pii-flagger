#!/usr/bin/env python3
"""
Convert pii_detector.py --search output to highlighted HTML files.

Usage:
    python3 pii_detector.py --search <index> <config.yml> | python3 search_to_html.py

Output:
    Creates an HTML file in search_results/ directory with:
    - Purple for PII pattern matches
    - Green for context words near patterns
    - Red for context words far from patterns
"""

import sys
import re
import json
from datetime import datetime
from pathlib import Path
import html


def highlight_document_text_html(text, pattern_regex, context_words, proximity_chars):
    """
    Highlight patterns and context words in document text using HTML.

    Args:
        text: Document text to highlight
        pattern_regex: Regex pattern to match PII patterns
        context_words: List of context words
        proximity_chars: Maximum distance for context words to be "near"

    Returns:
        HTML-formatted text with highlighting
    """
    if not text or not pattern_regex:
        return html.escape(text)

    # Find all pattern matches with positions
    pattern_matches = []
    try:
        for match in re.finditer(pattern_regex, text, re.IGNORECASE):
            pattern_matches.append((match.start(), match.end(), match.group()))
    except re.error:
        return html.escape(text)

    # Find all context word matches with positions
    context_matches = []
    for word in context_words:
        escaped_word = re.escape(word)
        for match in re.finditer(rf'\b{escaped_word}\b', text, re.IGNORECASE):
            context_matches.append((match.start(), match.end(), match.group()))

    # Build list of highlighted ranges
    highlighted_ranges = []

    # Add pattern matches (purple)
    for start, end, matched_text in pattern_matches:
        highlighted_ranges.append((start, end, 'pattern', matched_text))

    # Add context words (green for near, red for far)
    # Match Elasticsearch Painless logic: context word must appear BEFORE pattern
    for start, end, matched_text in context_matches:
        is_near = False
        for pattern_start, pattern_end, _ in pattern_matches:
            # Only check if context word comes before the pattern
            if start < pattern_start:
                distance = pattern_start - end
                if distance <= proximity_chars:
                    is_near = True
                    break

        highlight_type = 'near' if is_near else 'far'
        highlighted_ranges.append((start, end, highlight_type, matched_text))

    # Sort by position (start, then by end descending to handle overlaps)
    highlighted_ranges.sort(key=lambda x: (x[0], -x[1]))

    # Build segments of text between highlights
    segments = []
    last_pos = 0

    # Remove overlapping ranges (keep first occurrence)
    seen_ranges = set()
    unique_ranges = []
    for start, end, highlight_type, matched_text in highlighted_ranges:
        overlap = False
        for s, e in seen_ranges:
            if not (end <= s or start >= e):  # Check for overlap
                overlap = True
                break
        if not overlap:
            unique_ranges.append((start, end, highlight_type, matched_text))
            seen_ranges.add((start, end))

    # Sort again after deduplication
    unique_ranges.sort(key=lambda x: x[0])

    # Build HTML with highlights
    for start, end, highlight_type, matched_text in unique_ranges:
        # Add text before this highlight
        if start > last_pos:
            segments.append(html.escape(text[last_pos:start]))

        # Add highlighted text
        escaped_text = html.escape(matched_text)
        if highlight_type == 'pattern':
            segments.append(f'<span class="pattern">{escaped_text}</span>')
        elif highlight_type == 'near':
            segments.append(f'<span class="context-near">{escaped_text}</span>')
        else:  # far
            segments.append(f'<span class="context-far">{escaped_text}</span>')

        last_pos = end

    # Add remaining text
    if last_pos < len(text):
        segments.append(html.escape(text[last_pos:]))

    return ''.join(segments)


def main():
    # Read all input from stdin
    input_text = sys.stdin.read()
    lines = input_text.split('\n')

    # Extract configuration from header
    index_name = None
    field_name = None
    pattern_regex = None
    context_words = []
    proximity_chars = 50

    for line in lines[:10]:
        if line.startswith('Processing PII detection for index:'):
            index_name = line.split('index:')[1].strip()
        elif line.startswith('Field name:'):
            field_name = line.split('Field name:')[1].strip()
        elif line.startswith('Pattern regex:'):
            pattern_regex = line.replace('Pattern regex:', '').strip()
        elif line.startswith('Context words:'):
            context_str = line.replace('Context words:', '').strip()
            if context_str != 'None' and context_str != '[]':
                context_str = context_str.strip('[]')
                context_words = [w.strip().strip('"\'') for w in context_str.split(',')]
        elif line.startswith('Proximity characters:'):
            try:
                proximity_chars = int(line.replace('Proximity characters:', '').strip())
            except ValueError:
                proximity_chars = 50

    # Parse JSON response (everything after "Search response status:")
    json_start = None
    for i, line in enumerate(lines):
        if line.startswith('Search response status:'):
            json_start = i + 1
            break

    if json_start is None:
        print("Error: Could not find search response in input", file=sys.stderr)
        sys.exit(1)

    json_text = '\n'.join(lines[json_start:])

    try:
        response_data = json.loads(json_text)
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON response: {e}", file=sys.stderr)
        sys.exit(1)

    # Extract hits
    hits = response_data.get('hits', {}).get('hits', [])
    total_hits = response_data.get('hits', {}).get('total', {}).get('value', 0)

    # Generate output filename
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    output_dir = Path('search_results')
    output_dir.mkdir(exist_ok=True)
    output_file = output_dir / f'search_{index_name}_{timestamp}.html'

    # Generate HTML content
    with open(output_file, 'w') as f:
        # HTML header with CSS
        f.write("""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PII Search Results: {index_name}</title>
    <style>
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            line-height: 1.6;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }}
        .header {{
            background: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 30px;
        }}
        h1 {{
            margin-top: 0;
            color: #333;
        }}
        .metadata {{
            color: #666;
            font-size: 14px;
            line-height: 1.8;
        }}
        .legend {{
            background: #fffbea;
            border-left: 4px solid #f59e0b;
            padding: 15px 20px;
            margin: 20px 0;
            border-radius: 4px;
        }}
        .legend h3 {{
            margin-top: 0;
            color: #92400e;
        }}
        .legend-item {{
            margin: 8px 0;
        }}
        .result {{
            background: white;
            padding: 25px;
            margin-bottom: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }}
        .result-header {{
            border-bottom: 2px solid #e5e7eb;
            padding-bottom: 15px;
            margin-bottom: 15px;
        }}
        .result-title {{
            font-size: 18px;
            font-weight: 600;
            color: #111827;
            margin-bottom: 10px;
        }}
        .result-meta {{
            color: #6b7280;
            font-size: 14px;
            margin: 5px 0;
        }}
        .document-text {{
            background: #f9fafb;
            padding: 20px;
            border-radius: 6px;
            border: 1px solid #e5e7eb;
            white-space: pre-wrap;
            word-wrap: break-word;
            font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
            font-size: 13px;
            line-height: 1.8;
        }}
        .pattern {{
            background-color: #f3e8ff;
            color: #7c3aed;
            padding: 2px 4px;
            border-radius: 3px;
            font-weight: bold;
            border: 1px solid #c4b5fd;
        }}
        .context-near {{
            background-color: #d1fae5;
            color: #059669;
            padding: 2px 4px;
            border-radius: 3px;
            font-weight: bold;
        }}
        .context-far {{
            background-color: #fee2e2;
            color: #dc2626;
            padding: 2px 4px;
            border-radius: 3px;
            text-decoration: line-through;
        }}
        code {{
            background: #f3f4f6;
            padding: 2px 6px;
            border-radius: 3px;
            font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
            font-size: 12px;
        }}
        .raw-json {{
            margin-top: 40px;
            padding-top: 20px;
            border-top: 2px solid #e5e7eb;
        }}
        details {{
            background: white;
            padding: 15px;
            border-radius: 6px;
            border: 1px solid #e5e7eb;
        }}
        summary {{
            cursor: pointer;
            font-weight: 600;
            color: #4b5563;
            user-select: none;
        }}
        summary:hover {{
            color: #111827;
        }}
        pre {{
            background: #1f2937;
            color: #f9fafb;
            padding: 15px;
            border-radius: 6px;
            overflow-x: auto;
            font-size: 12px;
        }}
    </style>
</head>
<body>
""".format(index_name=html.escape(index_name or 'Unknown')))

        # Header section
        f.write('<div class="header">\n')
        f.write(f'<h1>PII Search Results: {html.escape(index_name or "Unknown")}</h1>\n')
        f.write('<div class="metadata">\n')
        f.write(f'<strong>Generated:</strong> {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}<br>\n')
        f.write(f'<strong>Field name:</strong> {html.escape(field_name or "Unknown")}<br>\n')
        f.write(f'<strong>Pattern:</strong> <code>{html.escape(pattern_regex or "N/A")}</code><br>\n')

        if context_words:
            f.write(f'<strong>Context words:</strong> {html.escape(", ".join(context_words))}<br>\n')
        else:
            f.write(f'<strong>Context words:</strong> None<br>\n')

        f.write(f'<strong>Proximity threshold:</strong> {proximity_chars} characters<br>\n')
        f.write(f'<strong>Total results:</strong> {total_hits}\n')
        f.write('</div>\n')

        # Legend
        f.write('<div class="legend">\n')
        f.write('<h3>Highlighting Legend</h3>\n')
        f.write('<div class="legend-item"><span class="pattern">Pattern matches</span> - PII patterns (purple)</div>\n')
        f.write('<div class="legend-item"><span class="context-near">Context words</span> - Within proximity distance (green)</div>\n')
        f.write('<div class="legend-item"><span class="context-far">Context words</span> - Beyond proximity distance (red)</div>\n')
        f.write('</div>\n')
        f.write('</div>\n')

        # Process each hit
        for idx, hit in enumerate(hits, 1):
            f.write('<div class="result">\n')
            f.write('<div class="result-header">\n')
            f.write(f'<div class="result-title">Result {idx}/{total_hits}</div>\n')

            source = hit.get('_source', {})
            doc_id = hit.get('_id', 'unknown')
            filename = source.get('filename', source.get('file_path', 'unknown'))
            score = hit.get('_score')

            f.write(f'<div class="result-meta"><strong>Document ID:</strong> <code>{html.escape(doc_id)}</code></div>\n')
            f.write(f'<div class="result-meta"><strong>File:</strong> <code>{html.escape(filename)}</code></div>\n')

            if score is not None:
                f.write(f'<div class="result-meta"><strong>Relevance Score:</strong> {score}</div>\n')

            f.write('</div>\n')

            # Document text
            f.write('<h4>document_text:</h4>\n')
            f.write('<div class="document-text">\n')

            document_text = source.get('document_text', '')
            if document_text:
                highlighted_text = highlight_document_text_html(
                    document_text, pattern_regex, context_words, proximity_chars
                )
                f.write(highlighted_text)
            else:
                f.write('<em>(No document_text found)</em>')

            f.write('\n</div>\n')
            f.write('</div>\n')

        # Raw JSON
        f.write('<div class="raw-json">\n')
        f.write('<details>\n')
        f.write('<summary>Raw JSON Response</summary>\n')
        f.write('<pre>')
        f.write(html.escape(json.dumps(response_data, indent=2)))
        f.write('</pre>\n')
        f.write('</details>\n')
        f.write('</div>\n')

        # Close HTML
        f.write('</body>\n</html>\n')

    print(f"HTML output written to: {output_file}")


if __name__ == '__main__':
    main()
