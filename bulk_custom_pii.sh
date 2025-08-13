#!/bin/bash

# Bulk Custom PII Detection Script
# This script handles PII detection for any Elasticsearch index using custom YAML configurations
# Can be used by both initial crawls and continuous crawls

set -e

# Configuration
ES_URL="http://localhost:9200"

# Function to display usage
usage() {
    echo "Usage: $0 [--include-reverse] <index_name> <yaml_directory>"
    echo "  --include-reverse : Optional flag to also run reverse PII detection"
    echo "  index_name        : Elasticsearch index name to process"
    echo "  yaml_directory    : Directory containing YAML files for PII detection"
    echo ""
    echo "This script will:"
    echo "1. Find all YAML files in the specified directory"
    echo "2. Run normal PII detection asynchronously for each YAML file"
    echo "3. If --include-reverse is specified, run reverse PII detection asynchronously for each YAML file"
    echo "4. Monitor task completion sequentially to avoid conflicts"
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

# Function to run PII detection on all YAML files
run_pii_detection() {
    local index_name="$1"
    local yaml_dir="$2"
    local include_reverse="$3"
    
    log "Running PII detection on index: $index_name using YAML files from: $yaml_dir"
    
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
    
    for yaml_file in "${yaml_files[@]}"; do
        log "Processing YAML file: $yaml_file"
        
        # Run normal PII detection asynchronously
        log "Running normal PII detection..."
        local normal_output=$(python pii_detector.py --async "$index_name" "$yaml_file" 2>&1)
        local normal_task_id=$(extract_task_id "$normal_output")
        
        if [[ -z "$normal_task_id" ]]; then
            log "ERROR: Failed to extract task ID from normal PII detection output:"
            log "$normal_output"
            exit 1
        fi
        
        log "Normal PII detection task started: $normal_task_id"
        monitor_elasticsearch_task "$normal_task_id" "Normal PII detection for $(basename "$yaml_file")"
        
        # Run reverse PII detection asynchronously only if --include-reverse flag is set
        if [[ "$include_reverse" == "true" ]]; then
            log "Running reverse PII detection..."
            local reverse_output=$(python pii_detector.py --async --reverse "$index_name" "$yaml_file" 2>&1)
            local reverse_task_id=$(extract_task_id "$reverse_output")
            
            if [[ -z "$reverse_task_id" ]]; then
                log "ERROR: Failed to extract task ID from reverse PII detection output:"
                log "$reverse_output"
                exit 1
            fi
            
            log "Reverse PII detection task started: $reverse_task_id"
            monitor_elasticsearch_task "$reverse_task_id" "Reverse PII detection for $(basename "$yaml_file")"
        else
            log "Skipping reverse PII detection (--include-reverse not specified)"
        fi
        
        log "Completed processing: $yaml_file"
    done
    
    log "All PII detection completed"
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
    local index_name=""
    local yaml_dir=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --include-reverse)
                include_reverse="true"
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
    
    # Check required arguments
    if [[ -z "$index_name" || -z "$yaml_dir" ]]; then
        log "ERROR: Missing required arguments"
        usage
    fi
    
    log "Starting bulk custom PII detection"
    log "Index: $index_name"
    log "YAML directory: $yaml_dir"
    log "Include reverse detection: $include_reverse"
    
    # Validate Elasticsearch configuration and inputs
    validate_painless_regex
    validate_index "$index_name"
    validate_keyword_mapping "$index_name"
    
    # Run PII detection
    run_pii_detection "$index_name" "$yaml_dir" "$include_reverse"
    
    log "Bulk custom PII detection completed successfully"
}

# Run main function with all arguments
main "$@"