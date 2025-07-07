#!/usr/bin/env python3
"""
Dynamic PII Detection Script for Elasticsearch

This script reads a YAML configuration file and generates Elasticsearch queries
to detect PII patterns that may be separated by spaces or dashes, working around
regex limitations in the document_text field mapping.

Usage: python pii_detector.py config.yml
"""

import yaml
import json
import sys
import requests
import time
import os
import re
from typing import Dict, List, Any

def load_config(config_file: str) -> Dict[str, Any]:
    """Load configuration from YAML file."""
    try:
        with open(config_file, 'r') as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        print(f"Error: Configuration file '{config_file}' not found.")
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"Error parsing YAML file: {e}")
        sys.exit(1)

def build_pattern_query(pattern_chunks: List[str], field: str = "document_text") -> Dict[str, Any]:
    """
    Build a span query for pattern chunks that can handle separated digits.
    
    Args:
        pattern_chunks: List of regex patterns (e.g., ["[0-9]{3}", "[0-9]{3}", "[0-9]{3}"])
        field: The field to search in
    
    Returns:
        Dict representing the span query for the pattern
    """
    if len(pattern_chunks) == 1:
        # Single chunk, use span_multi directly
        return {
            "span_multi": {
                "match": {
                    "regexp": {
                        field: pattern_chunks[0]
                    }
                }
            }
        }
    
    # Multiple chunks, use span_near to find them close together
    span_clauses = []
    for chunk in pattern_chunks:
        span_clauses.append({
            "span_multi": {
                "match": {
                    "regexp": {
                        field: chunk
                    }
                }
            }
        })
    
    return {
        "span_near": {
            "clauses": span_clauses,
            "slop": 0,  # Adjacent matches only - separators are handled by token boundaries
            "in_order": True
        }
    }

def build_context_query(context_words: List[str], field: str = "document_text") -> List[Dict[str, Any]]:
    """
    Build span queries for context words, handling phrases with spaces.
    Uses span_term for simple string matching (more efficient than regexp).
    
    Args:
        context_words: List of context words/phrases to search for
        field: The field to search in
    
    Returns:
        List of span queries for context words
    """
    context_clauses = []
    for word in context_words:
        if ' ' in word:
            # Handle phrases with spaces using span_near
            word_parts = word.split()
            if len(word_parts) > 1:
                span_parts = []
                for part in word_parts:
                    span_parts.append({
                        "span_term": {
                            field: part.lower()  # Convert to lowercase for case-insensitive matching
                        }
                    })
                context_clauses.append({
                    "span_near": {
                        "clauses": span_parts,
                        "slop": 0,  # Exact phrase match
                        "in_order": True
                    }
                })
            else:
                # Single word after splitting (shouldn't happen but safe fallback)
                context_clauses.append({
                    "span_term": {
                        field: word.lower()
                    }
                })
        else:
            # Single word, use span_term directly
            context_clauses.append({
                "span_term": {
                    field: word.lower()
                }
            })
    
    # Use span_or to match any of the context words/phrases
    return [{
        "span_or": {
            "clauses": context_clauses
        }
    }]

def build_complete_query(config: Dict[str, Any], field: str = "document_text", field_name: str = None) -> Dict[str, Any]:
    """
    Build the complete Elasticsearch query combining context and pattern matching.
    Also filters out documents that already have the PII field set to prevent duplication.
    
    Args:
        config: Configuration dictionary from YAML
        field: The field to search in
        field_name: The PII field name to check for existence (e.g., 'HasTFN')
    
    Returns:
        Complete Elasticsearch query
    """
    pattern_chunks = config.get('patternRegex', [])
    context_words = config.get('contextWords', [])
    
    # Build the pattern query (handles both continuous and separated patterns)
    continuous_pattern = "".join(pattern_chunks)  # Join chunks for continuous matching
    
    # Create two pattern matching approaches:
    # 1. Continuous pattern (for cases like "288946270")
    # 2. Separated chunks (for cases like "288 946 270" or "288-946-270")
    
    pattern_queries = []
    
    # Add continuous pattern match
    pattern_queries.append({
        "span_multi": {
            "match": {
                "regexp": {
                    field: continuous_pattern
                }
            }
        }
    })
    
    # Add separated chunks match if we have multiple chunks
    if len(pattern_chunks) > 1:
        pattern_queries.append(build_pattern_query(pattern_chunks, field))
    
    # Combine pattern queries with span_or
    pattern_clause = {
        "span_or": {
            "clauses": pattern_queries
        }
    } if len(pattern_queries) > 1 else pattern_queries[0]
    
    # Build context clauses
    context_clauses = build_context_query(context_words, field) if context_words else []
    
    # Build the final span_near query combining context and pattern
    span_clauses = context_clauses + [pattern_clause]
    
    span_query = {
        "span_near": {
            "clauses": span_clauses,
            "slop": 5,  # Default proximity, can be made configurable
            "in_order": True
        }
    }
    
    # If field_name is provided, add filter to exclude documents that already have this PII field
    if field_name:
        return {
            "bool": {
                "must": [span_query],
                "must_not": [
                    {
                        "exists": {
                            "field": f"PII.{field_name}"
                        }
                    }
                ]
            }
        }
    else:
        return span_query

def load_checksum_algorithm(algorithm_name: str) -> str:
    """
    Load checksum algorithm from painless file.
    Trims test lines marked by specific comments to preserve core algorithm logic.
    
    Args:
        algorithm_name: Name of the checksum algorithm
    
    Returns:
        Painless script code as a single line
    """
    script_path = os.path.join("checksums", f"{algorithm_name}.painless")
    
    if not os.path.exists(script_path):
        raise FileNotFoundError(f"Checksum algorithm file not found: {script_path}")
    
    try:
        with open(script_path, 'r') as f:
            script_content = f.read()
        
        # Trim test lines based on comment markers
        script_content = trim_test_lines(script_content)
        
        # Remove line breaks and extra whitespace, replace with single spaces
        script_content = re.sub(r'\s+', ' ', script_content.strip())
        
        return script_content
    except Exception as e:
        raise Exception(f"Error loading checksum algorithm '{algorithm_name}': {e}")

def trim_test_lines(script_content: str) -> str:
    """
    Trim test lines from painless script content based on comment markers.
    
    Removes:
    - Everything from start up to and including "// Anything on this line or above will be removed"
    - Everything from "// Return statement goes here..." to the end
    
    Args:
        script_content: Raw script content from file
    
    Returns:
        Trimmed script content with only core algorithm logic
    """
    lines = script_content.split('\n')
    
    # Find the start marker (remove everything up to and including this line)
    start_marker = "// Anything on this line or above will be removed"
    start_index = None
    for i, line in enumerate(lines):
        if start_marker in line:
            start_index = i + 1  # Start after this line
            break
    
    # Find the end marker (remove everything from this line onwards)
    end_marker = "// Return statement goes here so you can validate if passChecksum is working in your lab"
    end_index = None
    for i, line in enumerate(lines):
        if end_marker in line:
            end_index = i  # End before this line
            break
    
    # Extract the core algorithm logic
    if start_index is not None and end_index is not None:
        # Both markers found - extract content between them
        core_lines = lines[start_index:end_index]
    elif start_index is not None:
        # Only start marker found - extract everything after it
        core_lines = lines[start_index:]
    elif end_index is not None:
        # Only end marker found - extract everything before it
        core_lines = lines[:end_index]
    else:
        # No markers found - return original content (no test lines)
        core_lines = lines
    
    return '\n'.join(core_lines)

def build_checksum_regex(pattern_chunks: List[str], context_words: List[str]) -> str:
    """
    Build regex pattern for checksum validation.
    
    Args:
        pattern_chunks: List of pattern chunks (e.g., ["[0-9]{3}", "[0-9]{3}", "[0-9]{3}"])
        context_words: List of context words
    
    Returns:
        Regex pattern string
    """
    # Join context words with pipe for OR logic
    context_regex = "|".join(context_words) if context_words else ".*"
    
    # Build pattern with optional separators
    pattern_parts = []
    for i, chunk in enumerate(pattern_chunks):
        pattern_parts.append(chunk)
        if i < len(pattern_chunks) - 1:  # Add separator except for last chunk
            pattern_parts.append("[\\s\\-]?")
    
    pattern_regex = "".join(pattern_parts)
    
    # Build complete regex - use capturing groups instead of lookbehind
    # This finds context words followed by the pattern within reasonable distance
    return f"(?i)({context_regex})[\\s\\S]{{0,50}}?({pattern_regex})"

def build_update_query(config: Dict[str, Any]) -> Dict[str, Any]:
    """
    Build the complete update_by_query request.
    
    Args:
        config: Configuration dictionary from YAML
    
    Returns:
        Complete update_by_query payload
    """
    field_name = config.get('fieldName', 'HasPII')
    checksum_algorithm = config.get('checksum')
    
    if checksum_algorithm:
        # Build checksum-enabled script
        pattern_chunks = config.get('patternRegex', [])
        context_words = config.get('contextWords', [])
        
        # Load checksum algorithm
        checksum_script = load_checksum_algorithm(checksum_algorithm)
        
        # Build regex pattern
        regex_pattern = build_checksum_regex(pattern_chunks, context_words)
        
        # Build the complete painless script with generic cleaning logic
        script_source = f"boolean passChecksum = false; Pattern pattern = /{regex_pattern}/; Matcher matcher = pattern.matcher(ctx._source.document_text); while (matcher.find()) {{ String rawMatch = matcher.group(2); String cleanMatch = /[^0-9]/.matcher(rawMatch).replaceAll(''); {checksum_script} if (passChecksum == true) {{ break; }} }} if (ctx._source.PII == null) {{ ctx._source.PII = new HashMap(); }} ctx._source.PII.put('{field_name}', passChecksum);"
        
        return {
            "script": {
                "source": script_source,
                "lang": "painless"
            },
            "query": build_complete_query(config, field_name=field_name)
        }
    else:
        # Original behavior without checksum
        return {
            "script": {
                "source": f"if (ctx._source.PII == null) {{ ctx._source.PII = new HashMap(); }} ctx._source.PII.put('{field_name}', true);",
                "lang": "painless"
            },
            "query": build_complete_query(config, field_name=field_name)
        }

def monitor_task(task_id: str, es_url: str = "http://localhost:9200", poll_interval: int = 2) -> None:
    """
    Monitor the progress of an Elasticsearch task.
    
    Args:
        task_id: The task ID to monitor
        es_url: Elasticsearch URL
        poll_interval: Polling interval in seconds
    """
    url = f"{es_url}/_tasks/{task_id}"
    
    print(f"Monitoring task: {task_id}")
    print("Press Ctrl+C to stop monitoring (task will continue running)\n")
    
    try:
        while True:
            try:
                response = requests.get(url)
                if response.status_code == 404:
                    print("Task completed or not found.")
                    break
                elif response.status_code == 200:
                    task_info = response.json()
                    
                    if 'task' in task_info:
                        task = task_info['task']
                        status = task.get('status', {})
                        
                        # Display progress information
                        print(f"\rStatus: {task.get('action', 'unknown')} | "
                              f"Total: {status.get('total', 0)} | "
                              f"Updated: {status.get('updated', 0)} | "
                              f"Batches: {status.get('batches', 0)} | "
                              f"Version Conflicts: {status.get('version_conflicts', 0)}", end="")
                        
                        # Check if task is completed
                        if task.get('completed', False):
                            print(f"\n\nTask completed successfully!")
                            if 'response' in task_info:
                                print(json.dumps(task_info['response'], indent=2))
                            break
                    else:
                        # Task might be completed, try to get final result
                        print("\nTask appears to be completed.")
                        break
                        
                else:
                    print(f"\nError checking task status: {response.status_code}")
                    print(response.text)
                    break
                    
            except requests.RequestException as e:
                print(f"\nError connecting to Elasticsearch: {e}")
                break
                
            time.sleep(poll_interval)
            
    except KeyboardInterrupt:
        print(f"\n\nStopped monitoring task {task_id}. Task continues running in background.")
        print(f"You can check status manually at: {url}")

def execute_search(config: Dict[str, Any], index: str, es_url: str = "http://localhost:9200", dry_run: bool = False) -> None:
    """
    Execute a search query against Elasticsearch.
    
    Args:
        config: Configuration dictionary from YAML
        index: Elasticsearch index name
        es_url: Elasticsearch URL
        dry_run: If True, print query instead of executing
    """
    query_payload = {
        "query": build_complete_query(config)
    }
    
    if dry_run:
        print("Generated Elasticsearch Query:")
        print(json.dumps(query_payload, indent=2))
        return
    
    url = f"{es_url}/{index}/_search?pretty=true"
    headers = {"Content-Type": "application/json"}
    
    try:
        response = requests.post(url, json=query_payload, headers=headers)
        print(f"Search response status: {response.status_code}")
        print(response.text)
            
    except requests.RequestException as e:
        print(f"Error executing search: {e}")
        sys.exit(1)

def execute_update(config: Dict[str, Any], index: str, es_url: str = "http://localhost:9200", dry_run: bool = False, async_mode: bool = False) -> None:
    """
    Execute the update_by_query against Elasticsearch.
    
    Args:
        config: Configuration dictionary from YAML
        index: Elasticsearch index name
        es_url: Elasticsearch URL
        dry_run: If True, print query instead of executing
        async_mode: If True, run asynchronously and monitor progress
    """
    update_payload = build_update_query(config)
    
    if dry_run:
        print("Generated Elasticsearch Query:")
        print(json.dumps(update_payload, indent=2))
        return
    
    # Add async parameter if in async mode
    async_param = "&wait_for_completion=false" if async_mode else ""
    url = f"{es_url}/{index}/_update_by_query?pretty=true{async_param}"
    headers = {"Content-Type": "application/json"}
    
    try:
        response = requests.post(url, json=update_payload, headers=headers)
        print(f"Update response status: {response.status_code}")
        
        if async_mode and response.status_code == 200:
            # Parse task ID from response and start monitoring
            response_data = response.json()
            task_id = response_data.get('task')
            
            if task_id:
                print(f"Task started with ID: {task_id}")
                print(response.text)
                print("\n" + "="*50)
                monitor_task(task_id, es_url)
            else:
                print("No task ID found in response:")
                print(response.text)
        else:
            print(response.text)
            
    except requests.RequestException as e:
        print(f"Error executing update: {e}")
        sys.exit(1)

def main():
    """Main function."""
    if len(sys.argv) < 3 or len(sys.argv) > 6:
        print("Usage: python pii_detector.py [--dry-run] [--async] [--search] <index> <config.yml>")
        print("  --dry-run: Preview query without executing")
        print("  --async:   Run asynchronously and monitor progress")
        print("  --search:  Execute search query instead of update")
        sys.exit(1)
    
    dry_run = False
    async_mode = False
    search_mode = False
    args = sys.argv[1:]
    
    # Parse flags
    if "--dry-run" in args:
        dry_run = True
        args.remove("--dry-run")
    
    if "--async" in args:
        async_mode = True
        args.remove("--async")
    
    if "--search" in args:
        search_mode = True
        args.remove("--search")
    
    # Validate remaining arguments
    if len(args) != 2:
        print("Usage: python pii_detector.py [--dry-run] [--async] [--search] <index> <config.yml>")
        print("  --dry-run: Preview query without executing")
        print("  --async:   Run asynchronously and monitor progress")
        print("  --search:  Execute search query instead of update")
        sys.exit(1)
    
    index = args[0]
    config_file = args[1]
    
    # Don't allow incompatible flags
    if dry_run and async_mode:
        print("Error: Cannot use both --dry-run and --async flags together")
        sys.exit(1)
    
    if search_mode and async_mode:
        print("Error: Cannot use both --search and --async flags together")
        sys.exit(1)
    
    config = load_config(config_file)
    
    # Validate required fields
    required_fields = ['fieldName', 'patternRegex']
    for field in required_fields:
        if field not in config:
            print(f"Error: Required field '{field}' not found in configuration.")
            sys.exit(1)
    
    print(f"Processing PII detection for index: {index}")
    print(f"Field name: {config['fieldName']}")
    print(f"Pattern chunks: {config['patternRegex']}")
    print(f"Context words: {config.get('contextWords', 'None')}")
    print(f"Checksum algorithm: {config.get('checksum', 'None')}")
    
    if search_mode:
        execute_search(config, index, dry_run=dry_run)
    else:
        execute_update(config, index, dry_run=dry_run, async_mode=async_mode)

if __name__ == "__main__":
    main()