#!/bin/bash

# Bulk Custom PII Detection Script
# This script handles PII detection for any Elasticsearch index using custom YAML configurations
# Can be used by both initial crawls and continuous crawls

# Configuration
ES_URL="http://localhost:9200"

# Function to display usage
usage() {
    echo "Usage: $0 [--include-reverse] [--ner] [--validation-only] [--proximity-chars=N] [index_name] <yaml_directory>"
    echo "  --include-reverse  : Optional flag to also run reverse PII detection"
    echo "  --ner              : Optional flag to run NER extraction instead of PII detection"
    echo "  --validation-only  : Optional flag to only run validation checks and exit (no processing)"
    echo "  --proximity-chars=N: Optional proximity distance between context words and patterns (default: 50)"
    echo "  index_name         : Elasticsearch index name to process (optional with --validation-only)"
    echo "  yaml_directory     : Directory containing YAML files for detection"
    echo ""
    echo "This script will:"
    echo "1. Find all YAML files in the specified directory"
    echo "2. Run detection asynchronously for each YAML file (PII or NER mode)"
    echo "3. If --include-reverse is specified, run reverse PII detection asynchronously for each YAML file"
    echo "4. Monitor task completion sequentially to avoid conflicts"
    echo ""
    echo "Validation-only mode:"
    echo "  When --validation-only is specified, the script will:"
    echo "  - Validate Elasticsearch painless regex setting"
    echo "  - Validate index exists and has documents (if index_name provided)"
    echo "  - Validate document_text keyword mapping (if index_name provided)"
    echo "  - Validate all YAML files (syntax + regex patterns + Elasticsearch compatibility)"
    echo "  - Exit with success/failure status without running any detection"
    echo ""
    echo "Notes:"
    echo "  - --include-reverse cannot be used with --ner flag"
    echo "  - For --validation-only, index_name is optional (omit to skip index validation)"
    exit 1
}

# Function to log messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if jq is available
check_jq() {
    if ! command -v jq &> /dev/null; then
        log "ERROR: jq is required but not installed. Please install jq."
        exit 1
    fi
}

# Function to monitor Elasticsearch task completion
get_task_result() {
    local task_id="$1"

    local task_response=$(curl -s --request GET \
        --url "${ES_URL}/_tasks/${task_id}" \
        --header 'accept: application/json')

    echo "$task_response"
}

monitor_elasticsearch_task() {
    local task_id="$1"
    local description="$2"

    log "Monitoring Elasticsearch task: $task_id ($description)"
    
    while true; do
        local task_response=$(curl -s -w "%{http_code}" --request GET \
            --url "${ES_URL}/_tasks/${task_id}" \
            --header 'accept: application/json')
        
        if [[ $? -ne 0 ]]; then
            log "ERROR: Failed to check task status for $task_id"
            exit 1
        fi
        
        # Extract HTTP status code from response
        local http_code="${task_response: -3}"
        local json_response="${task_response%???}"
        
        # For 200 responses, check if task is completed
        if [[ "$http_code" == "200" ]]; then
            # Check if task has completed flag set to true
            local completed=$(echo "$json_response" | jq -r '.completed // false' 2>/dev/null || echo "false")
            if [[ "$completed" == "true" ]]; then
                # Extract final results
                local total=$(echo "$json_response" | jq -r '.response.total // 0' 2>/dev/null || echo "0")
                local updated=$(echo "$json_response" | jq -r '.response.updated // 0' 2>/dev/null || echo "0")
                log "Task completed successfully: $task_id ($description) - Total: $total, Updated: $updated"
                break
            fi
            
            # Extract and display progress information if available
            local status=$(echo "$json_response" | jq -r '.task.status // empty' 2>/dev/null || echo "")
            if [[ -n "$status" ]]; then
                local total=$(echo "$status" | jq -r '.total // 0' 2>/dev/null || echo "0")
                local updated=$(echo "$status" | jq -r '.updated // 0' 2>/dev/null || echo "0")
                local batches=$(echo "$status" | jq -r '.batches // 0' 2>/dev/null || echo "0")
                log "Task $task_id progress: $updated/$total documents processed ($batches batches)"
            fi
        elif [[ "$http_code" == "404" ]]; then
            # Task not found - it may have completed very quickly or been cleaned up
            log "WARNING: Task $task_id not found (404). Task may have completed quickly."
            log "Checking if task completed successfully by looking for results..."
            
            # Give it a moment for any final writes to complete
            sleep 2
            
            log "Task $task_id appears to have completed (task no longer tracked by Elasticsearch)"
            break
        else
            log "ERROR: Unexpected HTTP status code: $http_code"
            log "Response: $json_response"
            exit 1
        fi
        
        log "Waiting for task to complete... (checking again in 10 seconds)"
        sleep 10
    done
}

# Function to extract task ID from pii_detector.py output
extract_task_id() {
    local output="$1"
    echo "$output" | grep -o "Task started with ID: [^[:space:]]*" | sed 's/Task started with ID: //'
}

# Function to validate YAML files before processing
validate_yaml_files() {
    local yaml_dir="$1"
    
    log "Validating YAML files in directory: $yaml_dir"
    
    # Find all YAML files in the directory
    local yaml_files=($(find "$yaml_dir" -name "*.yml" -o -name "*.yaml"))
    
    if [[ ${#yaml_files[@]} -eq 0 ]]; then
        log "ERROR: No YAML files found in directory: $yaml_dir"
        exit 1
    fi
    
    local invalid_files=()
    
    for yaml_file in "${yaml_files[@]}"; do
        log "Validating YAML syntax and regex patterns: $yaml_file"
        
        # Use Python to validate YAML syntax and regex patterns
        python3 -c "
import yaml
import sys
import re

try:
    with open(sys.argv[1], 'r') as f:
        config = yaml.safe_load(f)
    
    # Basic YAML syntax check passed
    print('YAML syntax: VALID')
    
    # Validate regex patterns if present
    if isinstance(config, dict) and 'patternRegex' in config:
        pattern_regex = config['patternRegex']
        
        if not pattern_regex:
            print('REGEX_ERROR: patternRegex field is empty', file=sys.stderr)
            sys.exit(1)
        
        if not isinstance(pattern_regex, str):
            print('REGEX_ERROR: patternRegex must be a string', file=sys.stderr)
            sys.exit(1)
        
        # Check for Elasticsearch incompatible patterns
        elasticsearch_issues = []
        
        # Check for case-insensitive flags (not supported in Elasticsearch regexp)
        if '(?i:' in pattern_regex:
            elasticsearch_issues.append('Contains (?i:...) case-insensitive flags - not supported in Elasticsearch regexp queries')
        
        # Check for double-escaped word boundaries
        if '\\\\\\\\b' in pattern_regex:
            elasticsearch_issues.append('Contains quadruple-escaped word boundaries (\\\\\\\\b) - should be \\\\b')
        elif '\\\\\\\\B' in pattern_regex:
            elasticsearch_issues.append('Contains quadruple-escaped non-word boundaries (\\\\\\\\B) - should be \\\\B')
        
        # Check for inconsistent word boundary escaping (mix of \\b and \\\\b in alternatives)
        if '|' in pattern_regex:
            alternatives = pattern_regex.split('|')
            has_single_escaped = any('\\\\b' in alt and '\\\\\\\\b' not in alt for alt in alternatives)
            has_double_escaped = any('\\\\\\\\b' in alt for alt in alternatives)
            if has_single_escaped and has_double_escaped:
                elasticsearch_issues.append('Inconsistent word boundary escaping - mix of \\\\b and \\\\\\\\b in alternatives')
        
        # Report Elasticsearch compatibility issues
        if elasticsearch_issues:
            print('ELASTICSEARCH_COMPATIBILITY_ERRORS:', file=sys.stderr)
            for issue in elasticsearch_issues:
                print(f'  - {issue}', file=sys.stderr)
            sys.exit(1)
        
        # Test if the regex pattern is valid Python regex
        try:
            # For Python validation, we need to handle the YAML-escaped pattern
            # Convert double-escaped patterns for Python testing
            python_pattern = pattern_regex.replace('\\\\\\\\b', '\\\\b').replace('\\\\\\\\B', '\\\\B')
            
            # Remove Elasticsearch-specific flags for Python testing
            python_pattern = re.sub(r'\\?\\?\(\?i:', '(?i:', python_pattern)
            
            # Test compilation
            re.compile(python_pattern)
            print('Regex pattern: VALID')
            
        except re.error as e:
            print(f'REGEX_ERROR: Invalid regex pattern - {e}', file=sys.stderr)
            sys.exit(1)
        
    else:
        print('No patternRegex field found - skipping regex validation')
    
    print('VALIDATION_COMPLETE')
    
except yaml.YAMLError as e:
    print(f'YAML_ERROR: {e}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'FILE_ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" "$yaml_file" > /tmp/yaml_validation_output 2>&1
        
        local validation_exit_code=$?
        local validation_output=$(cat /tmp/yaml_validation_output)
        
        if [[ $validation_exit_code -ne 0 ]]; then
            log "ERROR: Validation failed for $yaml_file:"
            log "$validation_output"
            invalid_files+=("$yaml_file")
        else
            log "File validation passed: $(basename "$yaml_file")"
            # Show validation details
            echo "$validation_output" | while read -r line; do
                if [[ "$line" != "VALIDATION_COMPLETE" ]]; then
                    log "  $line"
                fi
            done
        fi
    done
    
    if [[ ${#invalid_files[@]} -gt 0 ]]; then
        log "FATAL: Found ${#invalid_files[@]} files with validation errors:"
        for invalid_file in "${invalid_files[@]}"; do
            log "  - $invalid_file"
        done
        log "Please fix the validation errors before running bulk processing."
        log ""
        log "Common issues and fixes:"
        log "  YAML SYNTAX ERRORS:"
        log "    - Unescaped quotes in double-quoted strings (use single quotes or escape backslashes)"
        log "    - Missing quotes around special characters"
        log "    - Incorrect indentation"
        log "    - Missing colons after keys"
        log ""
        log "  REGEX PATTERN ERRORS:"
        log "    - Invalid regex syntax (check parentheses, brackets, escape sequences)"
        log "    - Double-escaped word boundaries (\\\\\\\\b should be \\\\b)"
        log "    - Case-insensitive flags (?i:...) not supported in Elasticsearch"
        log "    - Inconsistent escaping across regex alternatives"
        log ""
        log "  ELASTICSEARCH COMPATIBILITY:"
        log "    - Use simple patterns without (?i:...) flags"
        log "    - Use consistent \\\\b escaping for word boundaries"
        log "    - Test patterns with simple alternation (pattern1|pattern2)"
        log ""
        log "STOPPING EXECUTION DUE TO VALIDATION FAILURES"
        exit 1
    fi
    
    log "All ${#yaml_files[@]} files passed validation (YAML syntax + regex patterns + Elasticsearch compatibility)"
}

# Function to run PII detection on all YAML files
run_pii_detection() {
    local index_name="$1"
    local yaml_dir="$2"
    local include_reverse="$3"
    local ner_mode="$4"
    local proximity_chars="$5"
    
    if [[ "$ner_mode" == "true" ]]; then
        log "Running NER extraction on index: $index_name using YAML files from: $yaml_dir"
    else
        log "Running PII detection on index: $index_name using YAML files from: $yaml_dir"
    fi
    
    if [[ ! -d "$yaml_dir" ]]; then
        log "ERROR: YAML directory does not exist: $yaml_dir"
        exit 1
    fi
    
    # Find all YAML files in the directory
    local yaml_files=($(find "$yaml_dir" -name "*.yml" -o -name "*.yaml"))
    
    if [[ ${#yaml_files[@]} -eq 0 ]]; then
        log "ERROR: No YAML files found in directory: $yaml_dir"
        exit 1
    fi
    
    log "Found ${#yaml_files[@]} YAML files to process"
    
    local processed_count=0
    local failed_count=0
    
    for yaml_file in "${yaml_files[@]}"; do
        log "Processing YAML file: $yaml_file"

        # Build command flags
        local detection_flags="--async"
        if [[ "$ner_mode" == "true" ]]; then
            detection_flags="$detection_flags --ner"
        fi
        if [[ -n "$proximity_chars" ]]; then
            detection_flags="$detection_flags --proximity-chars=$proximity_chars"
        fi

        # Retry logic with count verification
        local max_attempts=3
        local attempt=1
        local update_success=false

        while [[ $attempt -le $max_attempts ]]; do
            # Get expected count before update
            log "Attempt $attempt/$max_attempts: Getting expected document count..."
            local count_output=$(python3 pii_detector.py --count "$index_name" "$yaml_file" 2>&1)
            local expected_count=$(echo "$count_output" | grep "Count:" | awk '{print $2}')

            if [[ -z "$expected_count" || "$expected_count" == "0" ]]; then
                log "No documents to process (expected count: ${expected_count:-0})"
                update_success=true
                break
            fi

            log "Expected to update $expected_count documents"

            # Run normal detection asynchronously
            if [[ "$ner_mode" == "true" ]]; then
                log "Running NER extraction..."
            else
                log "Running normal PII detection..."
            fi

            local normal_output=$(python3 pii_detector.py $detection_flags "$index_name" "$yaml_file" 2>&1)
            local normal_exit_code=$?

            # Check if the command failed before trying to extract task ID
            if [[ $normal_exit_code -ne 0 ]]; then
                if [[ "$ner_mode" == "true" ]]; then
                    log "ERROR: NER extraction command failed with exit code $normal_exit_code:"
                else
                    log "ERROR: PII detection command failed with exit code $normal_exit_code:"
                fi
                log "$normal_output"
                ((attempt++))
                if [[ $attempt -le $max_attempts ]]; then
                    log "Retrying..."
                    sleep 2
                fi
                continue
            fi

            local normal_task_id=$(extract_task_id "$normal_output")

            if [[ -z "$normal_task_id" ]]; then
                if [[ "$ner_mode" == "true" ]]; then
                    log "ERROR: Failed to extract task ID from NER extraction output:"
                else
                    log "ERROR: Failed to extract task ID from normal PII detection output:"
                fi
                log "$normal_output"
                ((attempt++))
                if [[ $attempt -le $max_attempts ]]; then
                    log "Retrying..."
                    sleep 2
                fi
                continue
            fi

            if [[ "$ner_mode" == "true" ]]; then
                log "NER extraction task started: $normal_task_id"
                monitor_elasticsearch_task "$normal_task_id" "NER extraction for $(basename "$yaml_file")"
            else
                log "Normal PII detection task started: $normal_task_id"
                monitor_elasticsearch_task "$normal_task_id" "Normal PII detection for $(basename "$yaml_file")"
            fi

            # Extract updated count from task result
            local task_result=$(get_task_result "$normal_task_id")
            local updated_count=$(echo "$task_result" | grep -oP '"updated"\s*:\s*\K\d+' | head -1)

            if [[ -z "$updated_count" ]]; then
                log "WARNING: Could not extract updated count from task result"
                updated_count=0
            fi

            # Verify count matches expectation
            if [[ "$updated_count" -ge "$expected_count" ]]; then
                log "✓ Success: Updated $updated_count/$expected_count documents"
                update_success=true
                break
            else
                local remaining=$((expected_count - updated_count))
                log "⚠ Mismatch: Updated $updated_count/$expected_count documents ($remaining remaining)"
                ((attempt++))
                if [[ $attempt -le $max_attempts ]]; then
                    log "Retrying remaining documents..."
                    sleep 2
                fi
            fi
        done

        # Check final result
        if [[ "$update_success" != "true" ]]; then
            log "✗ Failed: Could not process all documents after $max_attempts attempts"
            ((failed_count++))
            continue
        fi
        
        # Run reverse PII detection asynchronously only if --include-reverse flag is set and not in NER mode
        if [[ "$include_reverse" == "true" && "$ner_mode" != "true" ]]; then
            log "Running reverse PII detection..."
            local reverse_flags="--async --reverse"
            if [[ -n "$proximity_chars" ]]; then
                reverse_flags="$reverse_flags --proximity-chars=$proximity_chars"
            fi
            local reverse_output=$(python3 pii_detector.py $reverse_flags "$index_name" "$yaml_file" 2>&1)
            local reverse_exit_code=$?
            
            # Check if the reverse command failed before trying to extract task ID
            if [[ $reverse_exit_code -ne 0 ]]; then
                log "ERROR: Reverse PII detection command failed with exit code $reverse_exit_code:"
                log "$reverse_output"
                log "Skipping reverse detection for this YAML file and continuing..."
            else
                local reverse_task_id=$(extract_task_id "$reverse_output")
                
                if [[ -z "$reverse_task_id" ]]; then
                    log "ERROR: Failed to extract task ID from reverse PII detection output:"
                    log "$reverse_output"
                    log "Skipping reverse detection for this YAML file and continuing..."
                else
                    log "Reverse PII detection task started: $reverse_task_id"
                    monitor_elasticsearch_task "$reverse_task_id" "Reverse PII detection for $(basename "$yaml_file")"
                fi
            fi
        elif [[ "$include_reverse" == "true" && "$ner_mode" == "true" ]]; then
            log "Skipping reverse detection (not supported in NER mode)"
        else
            log "Skipping reverse PII detection (--include-reverse not specified)"
        fi
        
        log "Completed processing: $yaml_file"
        ((processed_count++))
    done
    
    log "Processing summary:"
    log "  Successfully processed: $processed_count YAML files"
    log "  Failed to process: $failed_count YAML files"
    log "  Total files: ${#yaml_files[@]}"
    
    if [[ "$ner_mode" == "true" ]]; then
        log "All NER extraction completed"
    else
        log "All PII detection completed"
    fi
}

# Function to validate Elasticsearch painless regex setting
validate_painless_regex() {
    log "Validating Elasticsearch painless regex setting..."
    
    local settings_response=$(curl -s "${ES_URL}/_cluster/settings?include_defaults=true")
    local regex_enabled=$(echo "$settings_response" | jq -r '.defaults.script.painless.regex.enabled // .persistent.script.painless.regex.enabled // .transient.script.painless.regex.enabled // "false"' 2>/dev/null || echo "false")
    
    if [[ "$regex_enabled" != "true" ]]; then
        log "ERROR: Elasticsearch painless regex is not enabled"
        log "Please set script.painless.regex.enabled=true in Elasticsearch configuration"
        log "You can enable it temporarily with:"
        log "curl -X PUT \"${ES_URL}/_cluster/settings\" -H 'Content-Type: application/json' -d '{\"transient\":{\"script.painless.regex.enabled\":true}}'"
        exit 1
    fi
    
    log "Painless regex is enabled"
}

# Function to validate document_text keyword mapping
validate_keyword_mapping() {
    local index_name="$1"
    
    log "Validating document_text keyword mapping for index: $index_name"
    
    local mapping_response=$(curl -s "${ES_URL}/${index_name}/_mapping")
    local has_keyword=$(echo "$mapping_response" | jq -r '.[].mappings._doc.properties.document_text.fields.keyword.type // .[].mappings.properties.document_text.fields.keyword.type // empty' 2>/dev/null || echo "")
    
    if [[ "$has_keyword" != "keyword" ]]; then
        log "ERROR: Index $index_name does not have proper document_text.keyword mapping"
        log "Expected mapping structure:"
        log "  \"document_text\": {"
        log "    \"type\": \"text\","
        log "    \"norms\": false,"
        log "    \"fields\": {"
        log "      \"keyword\": {"
        log "        \"type\": \"keyword\","
        log "        \"ignore_above\": 32000"
        log "      }"
        log "    }"
        log "  }"
        exit 1
    fi
    
    log "Document_text keyword mapping is properly configured"
}

# Function to validate index exists and has documents
validate_index() {
    local index_name="$1"
    
    log "Validating index: $index_name"
    
    # Check if index exists
    local index_exists=$(curl -s -o /dev/null -w "%{http_code}" "${ES_URL}/${index_name}")
    if [[ "$index_exists" != "200" ]]; then
        log "ERROR: Index $index_name does not exist"
        exit 1
    fi
    
    # Check if index has documents with document_text
    local doc_count=$(curl -s "${ES_URL}/${index_name}/_search?q=document_text:*&size=0" | jq -r '.hits.total' 2>/dev/null || echo "0")
    if [[ "$doc_count" -eq 0 ]]; then
        log "WARNING: Index $index_name has no documents with document_text field"
        log "PII detection requires documents with text content"
    else
        log "Index $index_name has $doc_count documents with text content"
    fi
}

# Main function
main() {
    check_jq
    
    # Parse arguments
    local include_reverse="false"
    local ner_mode="false"
    local validation_only="false"
    local proximity_chars=""
    local index_name=""
    local yaml_dir=""

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --include-reverse)
                include_reverse="true"
                shift
                ;;
            --ner)
                ner_mode="true"
                shift
                ;;
            --validation-only)
                validation_only="true"
                shift
                ;;
            --proximity-chars=*)
                proximity_chars="${1#*=}"
                # Validate that proximity_chars is a positive integer
                if ! [[ "$proximity_chars" =~ ^[0-9]+$ ]] || [[ "$proximity_chars" -lt 1 ]]; then
                    log "ERROR: --proximity-chars must be a positive integer"
                    usage
                fi
                shift
                ;;
            *)
                if [[ -z "$index_name" ]]; then
                    index_name="$1"
                elif [[ -z "$yaml_dir" ]]; then
                    yaml_dir="$1"
                else
                    log "ERROR: Too many arguments"
                    usage
                fi
                shift
                ;;
        esac
    done
    
    # Handle case where only one argument is provided with --validation-only
    if [[ "$validation_only" == "true" && -n "$index_name" && -z "$yaml_dir" ]]; then
        # If validation-only mode and only one argument, treat it as yaml_dir
        yaml_dir="$index_name"
        index_name=""
    fi
    
    # Check required arguments
    if [[ -z "$yaml_dir" ]]; then
        log "ERROR: Missing required yaml_directory argument"
        usage
    fi
    
    if [[ "$validation_only" != "true" && -z "$index_name" ]]; then
        log "ERROR: Missing required index_name argument"
        usage
    fi
    
    # Validate flag combinations
    if [[ "$include_reverse" == "true" && "$ner_mode" == "true" ]]; then
        log "ERROR: --include-reverse cannot be used with --ner flag"
        usage
    fi
    
    if [[ "$validation_only" == "true" ]]; then
        log "Starting validation-only mode"
        log "YAML directory: $yaml_dir"
        if [[ -n "$index_name" && "$index_name" != "skip" ]]; then
            log "Index validation: $index_name"
        else
            log "Index validation: SKIPPED"
        fi
    else
        if [[ "$ner_mode" == "true" ]]; then
            log "Starting bulk NER extraction"
        else
            log "Starting bulk custom PII detection"
        fi
        log "Index: $index_name"
        log "YAML directory: $yaml_dir"
        log "Include reverse detection: $include_reverse"
        log "NER mode: $ner_mode"
    fi
    
    # Validate Elasticsearch configuration and inputs
    validate_painless_regex
    
    # Only validate index if index_name is provided and not 'skip'
    if [[ -n "$index_name" && "$index_name" != "skip" ]]; then
        validate_index "$index_name"
        validate_keyword_mapping "$index_name"
    fi
    
    # Validate YAML files before processing
    log "About to run YAML validation on directory: $yaml_dir"
    validate_yaml_files "$yaml_dir"
    log "YAML validation completed successfully"
    
    # Exit early if validation-only mode
    if [[ "$validation_only" == "true" ]]; then
        log "Validation-only mode: All validation checks passed successfully"
        log "Validation summary:"
        log "  - Elasticsearch painless regex: ENABLED"
        if [[ -n "$index_name" && "$index_name" != "skip" ]]; then
            log "  - Index validation: PASSED"
            log "  - Keyword mapping: VALID"
        else
            log "  - Index validation: SKIPPED"
        fi
        log "  - YAML files validation: ALL PASSED"
        log "No processing performed (validation-only mode)"
        exit 0
    fi
    
    log "Proceeding with processing"

    # Run PII detection or NER extraction
    run_pii_detection "$index_name" "$yaml_dir" "$include_reverse" "$ner_mode" "$proximity_chars"
    
    if [[ "$ner_mode" == "true" ]]; then
        log "Bulk NER extraction completed successfully"
    else
        log "Bulk custom PII detection completed successfully"
    fi
}

# Run main function with all arguments
main "$@"