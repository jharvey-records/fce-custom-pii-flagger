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

# Legacy span query functions removed - no longer needed with keyword regex approach

def build_complete_query(config: Dict[str, Any], field: str = "document_text", field_name: str = None, reverse: bool = False, search_mode: bool = False, ner_mode: bool = False) -> Dict[str, Any]:
    """
    Build the complete Elasticsearch query using simplified keyword regex approach.
    Uses document_text.keyword for regex patterns and query_string for context words.
    
    Args:
        config: Configuration dictionary from YAML
        field: The field to search in (must have .keyword subfield)
        field_name: The PII field name to check for existence (e.g., 'HasTFN')
        reverse: If True, find documents that don't match the patterns
        search_mode: If True, exclude PII field existence check (for --search flag)
        ner_mode: If True, use named_entities field instead of PII field
    
    Returns:
        Complete Elasticsearch query
    """
    pattern_regex = config.get('patternRegex', '')
    context_words = config.get('contextWords', [])
    
    # Always require document_text field to exist for PII analysis
    document_text_exists = {
        "exists": {
            "field": "document_text"
        }
    }
    
    # Build must clauses
    must_clauses = [document_text_exists]
    
    # Add context query if context words exist
    if context_words:
        # Build query_string for context words, handling phrases
        context_query_parts = []
        for word in context_words:
            if ' ' in word:
                # Phrase with spaces - use quotes
                context_query_parts.append(f'"{word}"')
            else:
                # Single word
                context_query_parts.append(word)
        
        context_query = {
            "query_string": {
                "query": " OR ".join(context_query_parts),
                "default_field": "document_text"
            }
        }
        must_clauses.append(context_query)
    
    # Add pattern regex query for normal mode (reverse mode excludes this)
    if not reverse:
        pattern_query = {
            "regexp": {
                f"{field}.keyword": f".*{pattern_regex}.*"
            }
        }
        must_clauses.append(pattern_query)
    
    # Build must_not clauses
    must_not_clauses = []
    
    # Add field existence check to prevent duplication, except in search mode
    if field_name and not search_mode:
        field_prefix = "named_entities" if ner_mode else "PII"
        must_not_clauses.append({
            "exists": {
                "field": f"{field_prefix}.{field_name}"
            }
        })
    
    # For reverse mode, exclude documents that match the pattern
    if reverse:
        pattern_query = {
            "regexp": {
                f"{field}.keyword": f".*{pattern_regex}.*"
            }
        }
        must_not_clauses.append(pattern_query)
    
    return {
        "bool": {
            "must": must_clauses,
            "must_not": must_not_clauses
        }
    }

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

def build_checksum_regex(pattern_regex: str, context_words: List[str]) -> str:
    """
    Build regex pattern for checksum validation.
    
    Args:
        pattern_regex: Single regex pattern (e.g., "[0-9]{3}[\\s\\-]?[0-9]{3}[\\s\\-]?[0-9]{3}")
        context_words: List of context words
    
    Returns:
        Regex pattern string
    """
    # Join context words with pipe for OR logic
    context_regex = "|".join(context_words) if context_words else ".*"
    
    # Escape slashes in pattern for Painless regex
    escaped_pattern = pattern_regex.replace('/', '\\/')
    
    # Build complete regex - use capturing groups instead of lookbehind
    # This finds context words followed by the pattern within reasonable distance
    return f"(?i)({context_regex})[\\s\\S]{{0,50}}?({escaped_pattern})"

def build_update_query(config: Dict[str, Any], reverse: bool = False, ner_mode: bool = False) -> Dict[str, Any]:
    """
    Build the complete update_by_query request using proximity regex in scripts.
    
    Args:
        config: Configuration dictionary from YAML
        reverse: If True, generate reverse mode query (set field to false)
        ner_mode: If True, extract actual regex matches instead of boolean values
    
    Returns:
        Complete update_by_query payload
    """
    field_name = config.get('fieldName', 'HasPII')
    checksum_algorithm = config.get('checksum')
    pattern_regex = config.get('patternRegex', '')
    context_words = config.get('contextWords', [])
    
    if reverse:
        # Reverse mode: always set field to false, no checksum validation needed
        field_prefix = "named_entities" if ner_mode else "PII"
        return {
            "script": {
                "source": f"if (ctx._source.{field_prefix} == null) {{ ctx._source.{field_prefix} = new HashMap(); }} ctx._source.{field_prefix}.put('{field_name}', false);",
                "lang": "painless"
            },
            "query": build_complete_query(config, field_name=field_name, reverse=True, ner_mode=ner_mode)
        }
    elif checksum_algorithm:
        # Build checksum-enabled script with proximity regex
        checksum_script = load_checksum_algorithm(checksum_algorithm)
        regex_pattern = build_checksum_regex(pattern_regex, context_words)
        field_prefix = "named_entities" if ner_mode else "PII"
        
        if ner_mode:
            # NER mode: extract first valid match that passes checksum
            script_source = f"boolean passChecksum = false; String firstMatch = null; Pattern pattern = /{regex_pattern}/; Matcher matcher = pattern.matcher(ctx._source.document_text); while (matcher.find()) {{ String rawMatch = matcher.group(2); String cleanMatch = /[^0-9]/.matcher(rawMatch).replaceAll(''); {checksum_script} if (passChecksum == true) {{ firstMatch = rawMatch; break; }} }} if (ctx._source.{field_prefix} == null) {{ ctx._source.{field_prefix} = new HashMap(); }} if (firstMatch != null) {{ ctx._source.{field_prefix}.put('{field_name}', firstMatch); }}"
        else:
            # PII mode: boolean result if any match passes checksum
            script_source = f"boolean passChecksum = false; Pattern pattern = /{regex_pattern}/; Matcher matcher = pattern.matcher(ctx._source.document_text); while (matcher.find()) {{ String rawMatch = matcher.group(2); String cleanMatch = /[^0-9]/.matcher(rawMatch).replaceAll(''); {checksum_script} if (passChecksum == true) {{ break; }} }} if (ctx._source.{field_prefix} == null) {{ ctx._source.{field_prefix} = new HashMap(); }} ctx._source.{field_prefix}.put('{field_name}', passChecksum);"
        
        return {
            "script": {
                "source": script_source,
                "lang": "painless"
            },
            "query": build_complete_query(config, field_name=field_name, ner_mode=ner_mode)
        }
    else:
        # Build proximity regex for non-checksum detection
        regex_pattern = build_checksum_regex(pattern_regex, context_words)
        field_prefix = "named_entities" if ner_mode else "PII"
        
        if ner_mode:
            # NER mode: extract first match without checksum validation
            script_source = f"String firstMatch = null; Pattern pattern = /{regex_pattern}/; Matcher matcher = pattern.matcher(ctx._source.document_text); if (matcher.find()) {{ firstMatch = matcher.group(2); }} if (ctx._source.{field_prefix} == null) {{ ctx._source.{field_prefix} = new HashMap(); }} if (firstMatch != null) {{ ctx._source.{field_prefix}.put('{field_name}', firstMatch); }}"
        else:
            # PII mode: boolean result if any match found
            script_source = f"boolean foundMatch = false; Pattern pattern = /{regex_pattern}/; Matcher matcher = pattern.matcher(ctx._source.document_text); if (matcher.find()) {{ foundMatch = true; }} if (ctx._source.{field_prefix} == null) {{ ctx._source.{field_prefix} = new HashMap(); }} ctx._source.{field_prefix}.put('{field_name}', foundMatch);"
        
        return {
            "script": {
                "source": script_source,
                "lang": "painless"
            },
            "query": build_complete_query(config, field_name=field_name, ner_mode=ner_mode)
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
                if response.status_code == 200:
                    task_info = response.json()
                    
                    # Check if task is completed (completed flag is at root level)
                    if task_info.get('completed', False):
                        print(f"\n\nTask completed successfully!")
                        if 'response' in task_info:
                            print(json.dumps(task_info['response'], indent=2))
                        break
                    
                    # Display progress information if task is still running
                    if 'task' in task_info:
                        task = task_info['task']
                        status = task.get('status', {})
                        
                        # Display progress information
                        print(f"\rStatus: {task.get('action', 'unknown')} | "
                              f"Total: {status.get('total', 0)} | "
                              f"Updated: {status.get('updated', 0)} | "
                              f"Batches: {status.get('batches', 0)} | "
                              f"Version Conflicts: {status.get('version_conflicts', 0)}", end="")
                        
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

def execute_search(config: Dict[str, Any], index: str, es_url: str = "http://localhost:9200", dry_run: bool = False, reverse: bool = False, ner_mode: bool = False) -> None:
    """
    Execute a search query against Elasticsearch.
    
    Args:
        config: Configuration dictionary from YAML
        index: Elasticsearch index name
        es_url: Elasticsearch URL
        dry_run: If True, print query instead of executing
        reverse: If True, search for documents that don't match patterns
        ner_mode: If True, use named_entities field instead of PII field
    """
    field_name = config.get('fieldName', 'HasPII')
    
    # Ensure correct field mapping for NER mode
    if not dry_run and ner_mode:
        ensure_field_mapping(field_name, index, es_url, ner_mode=ner_mode)
    
    query_payload = {
        "query": build_complete_query(config, field_name=field_name, reverse=reverse, search_mode=True, ner_mode=ner_mode)
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

def ensure_field_mapping(field_name: str, index: str, es_url: str = "http://localhost:9200", ner_mode: bool = False) -> None:
    """
    Ensure the field has the correct mapping in the index.
    
    Args:
        field_name: The field name (e.g., 'HasTFN')
        index: Elasticsearch index name
        es_url: Elasticsearch URL
        ner_mode: If True, use text mapping for named_entities, otherwise boolean for PII
    """
    mapping_url = f"{es_url}/{index}/_mapping"
    headers = {"Content-Type": "application/json"}
    
    # Check current mapping
    try:
        response = requests.get(mapping_url)
        if response.status_code == 200:
            mapping = response.json()
            
            # Check if PII field mapping already exists and is boolean
            index_mapping = mapping.get(index, {})
            mappings = index_mapping.get('mappings', {})
            
            # Handle both new (_doc) and legacy mapping styles
            properties = mappings.get('properties', {})
            if not properties and '_doc' in mappings:
                properties = mappings['_doc'].get('properties', {})
            
            # Check if field object exists and field has correct mapping
            field_prefix = "named_entities" if ner_mode else "PII"
            field_properties = properties.get(field_prefix, {}).get('properties', {})
            field_mapping = field_properties.get(field_name, {})
            
            expected_type = "text" if ner_mode else "boolean"
            if field_mapping.get('type') == expected_type:
                print(f"Field mapping for {field_prefix}.{field_name} already exists as {expected_type}")
                return
        
        # Create or update the mapping using the _mapping/_doc endpoint
        mapping_endpoint = f"{es_url}/{index}/_mapping/_doc"
        field_prefix = "named_entities" if ner_mode else "PII"
        field_type = "text" if ner_mode else "boolean"
        
        mapping_payload = {
            "properties": {
                field_prefix: {
                    "properties": {
                        field_name: {
                            "type": field_type
                        }
                    }
                }
            }
        }
        
        put_response = requests.put(mapping_endpoint, json=mapping_payload, headers=headers)
        if put_response.status_code in [200, 201]:
            print(f"Successfully set {field_type} mapping for {field_prefix}.{field_name}")
        else:
            print(f"Warning: Failed to set mapping for {field_prefix}.{field_name}: {put_response.status_code}")
            print(put_response.text)
            
    except requests.RequestException as e:
        print(f"Warning: Error setting field mapping: {e}")

def validate_keyword_mapping(index: str, es_url: str = "http://localhost:9200") -> bool:
    """
    Validate that document_text.keyword field exists and is properly configured.
    
    Args:
        index: Elasticsearch index name
        es_url: Elasticsearch URL
    
    Returns:
        True if keyword mapping exists, False otherwise
    """
    mapping_url = f"{es_url}/{index}/_mapping"
    
    try:
        response = requests.get(mapping_url)
        if response.status_code == 200:
            mapping = response.json()
            
            # Navigate to document_text field mapping
            index_mapping = mapping.get(index, {})
            mappings = index_mapping.get('mappings', {})
            
            # Handle both new (_doc) and legacy mapping styles
            properties = mappings.get('properties', {})
            if not properties and '_doc' in mappings:
                properties = mappings['_doc'].get('properties', {})
            
            # Check if document_text has keyword subfield
            doc_text_mapping = properties.get('document_text', {})
            fields = doc_text_mapping.get('fields', {})
            keyword_field = fields.get('keyword', {})
            
            if keyword_field.get('type') == 'keyword':
                print(f"✓ document_text.keyword field is properly configured")
                return True
            else:
                print(f"✗ document_text.keyword field not found or not configured as keyword type")
                print(f"Current document_text mapping: {doc_text_mapping}")
                return False
        else:
            print(f"Error retrieving index mapping: {response.status_code}")
            print(response.text)
            return False
            
    except requests.RequestException as e:
        print(f"Error checking index mapping: {e}")
        return False

def execute_update(config: Dict[str, Any], index: str, es_url: str = "http://localhost:9200", dry_run: bool = False, async_mode: bool = False, monitor_mode: bool = False, reverse: bool = False, ner_mode: bool = False) -> None:
    """
    Execute the update_by_query against Elasticsearch with keyword mapping validation.
    
    Args:
        config: Configuration dictionary from YAML
        index: Elasticsearch index name
        es_url: Elasticsearch URL
        dry_run: If True, print query instead of executing
        async_mode: If True, run asynchronously without monitoring
        monitor_mode: If True, run asynchronously with progress monitoring
        reverse: If True, update documents that don't match patterns with false
        ner_mode: If True, extract named entities instead of boolean PII flags
    """
    field_name = config.get('fieldName', 'HasPII')
    
    # Validate keyword mapping before proceeding
    if not dry_run:
        if not validate_keyword_mapping(index, es_url):
            print("\nERROR: document_text.keyword mapping is required but not found.")
            print("Please ensure your Elasticsearch configuration includes:")
            print("- TEXT_KEYWORD_SIZE=32000 in diskover container")
            print("- script.painless.regex.enabled=true in elasticsearch containers")
            print("\nThe document_text field must be mapped with a keyword subfield:")
            print('"document_text": {')
            print('  "type": "text",')
            print('  "fields": {')
            print('    "keyword": {')
            print('      "type": "keyword",')
            print('      "ignore_above": 32000')
            print('    }')
            print('  }')
            print('}') 
            sys.exit(1)
        
        ensure_field_mapping(field_name, index, es_url, ner_mode=ner_mode)
    
    update_payload = build_update_query(config, reverse=reverse, ner_mode=ner_mode)
    
    if dry_run:
        print("Generated Elasticsearch Query:")
        print(json.dumps(update_payload, indent=2))
        return
    
    # Add async parameter if in async or monitor mode
    async_param = "&wait_for_completion=false" if (async_mode or monitor_mode) else ""
    url = f"{es_url}/{index}/_update_by_query?pretty=true&conflicts=proceed{async_param}"
    headers = {"Content-Type": "application/json"}
    
    try:
        response = requests.post(url, json=update_payload, headers=headers)
        print(f"Update response status: {response.status_code}")
        
        if (async_mode or monitor_mode) and response.status_code == 200:
            # Parse task ID from response
            response_data = response.json()
            task_id = response_data.get('task')
            
            if task_id:
                print(f"Task started with ID: {task_id}")
                print(response.text)
                
                if monitor_mode:
                    # Start monitoring for monitor mode
                    print("\n" + "="*50)
                    monitor_task(task_id, es_url)
                else:
                    # For async mode, just print task ID and exit
                    print(f"\nTask running in background. Monitor manually at: {es_url}/_tasks/{task_id}")
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
    if len(sys.argv) < 3 or len(sys.argv) > 9:
        print("Usage: python pii_detector.py [--dry-run] [--async] [--monitor] [--search] [--reverse] [--ner] <index> <config.yml>")
        print("  --dry-run: Preview query without executing")
        print("  --async:   Run asynchronously without monitoring")
        print("  --monitor: Run asynchronously with progress monitoring")
        print("  --search:  Execute search query instead of update")
        print("  --reverse: Set PII field to false for documents that don't match patterns")
        print("  --ner:     Extract named entities instead of boolean PII flags")
        sys.exit(1)
    
    dry_run = False
    async_mode = False
    monitor_mode = False
    search_mode = False
    reverse_mode = False
    ner_mode = False
    args = sys.argv[1:]
    
    # Parse flags
    if "--dry-run" in args:
        dry_run = True
        args.remove("--dry-run")
    
    if "--async" in args:
        async_mode = True
        args.remove("--async")
    
    if "--monitor" in args:
        monitor_mode = True
        args.remove("--monitor")
    
    if "--search" in args:
        search_mode = True
        args.remove("--search")
    
    if "--reverse" in args:
        reverse_mode = True
        args.remove("--reverse")
    
    if "--ner" in args:
        ner_mode = True
        args.remove("--ner")
    
    # Validate remaining arguments
    if len(args) != 2:
        print("Usage: python pii_detector.py [--dry-run] [--async] [--monitor] [--search] [--reverse] [--ner] <index> <config.yml>")
        print("  --dry-run: Preview query without executing")
        print("  --async:   Run asynchronously without monitoring")
        print("  --monitor: Run asynchronously with progress monitoring")
        print("  --search:  Execute search query instead of update")
        print("  --reverse: Set PII field to false for documents that don't match patterns")
        print("  --ner:     Extract named entities instead of boolean PII flags")
        sys.exit(1)
    
    index = args[0]
    config_file = args[1]
    
    # Don't allow incompatible flags
    if dry_run and (async_mode or monitor_mode):
        print("Error: Cannot use --dry-run with --async or --monitor flags")
        sys.exit(1)
    
    if search_mode and (async_mode or monitor_mode):
        print("Error: Cannot use --search with --async or --monitor flags")
        sys.exit(1)
    
    if async_mode and monitor_mode:
        print("Error: Cannot use both --async and --monitor flags together")
        sys.exit(1)
    
    if ner_mode and reverse_mode:
        print("Error: Cannot use --ner with --reverse flag")
        sys.exit(1)
    
    config = load_config(config_file)
    
    # Validate required fields
    required_fields = ['fieldName', 'patternRegex']
    for field in required_fields:
        if field not in config:
            print(f"Error: Required field '{field}' not found in configuration.")
            sys.exit(1)
    
    # Ensure patternRegex is a string (not list for backward compatibility check)
    if isinstance(config['patternRegex'], list):
        print(f"Error: patternRegex must be a single string, not a list. Update your YAML file.")
        print(f"Example: patternRegex: '[0-9]{{3}}[\\s\\-/]?[0-9]{{3}}[\\s\\-/]?[0-9]{{3}}'")
        sys.exit(1)
    
    if ner_mode:
        print(f"Processing NER extraction for index: {index}")
    else:
        print(f"Processing PII detection for index: {index}")
    print(f"Field name: {config['fieldName']}")
    print(f"Pattern regex: {config['patternRegex']}")
    print(f"Context words: {config.get('contextWords', 'None')}")
    print(f"Checksum algorithm: {config.get('checksum', 'None')}")
    print(f"Reverse mode: {reverse_mode}")
    print(f"NER mode: {ner_mode}")
    
    if search_mode:
        execute_search(config, index, dry_run=dry_run, reverse=reverse_mode, ner_mode=ner_mode)
    else:
        execute_update(config, index, dry_run=dry_run, async_mode=async_mode, monitor_mode=monitor_mode, reverse=reverse_mode, ner_mode=ner_mode)

if __name__ == "__main__":
    main()