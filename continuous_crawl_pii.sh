#!/bin/bash

# Continuous Crawl PII Detection Script
# This script performs continuous crawl with custom PII detection

set -e

# Configuration
API_KEY="ApiKey"
BASE_URL="http://localhost:8001"
ES_URL="http://localhost:9200"

# Function to display usage
usage() {
    echo "Usage: $0 [--test|--no-submit] [--include-reverse] [--ner] <index> <yaml_dir>"
    echo "  --test           : Test mode - don't submit, delete index after, rollback stages"
    echo "  --no-submit      : Skip submission but keep index and don't rollback stages"
    echo "  --include-reverse: Include reverse PII detection (optional)"
    echo "  --ner            : Run NER extraction instead of PII detection (optional)"
    echo "  index            : Base index name for continuous crawl"
    echo "  yaml_dir         : Directory containing YAML files for PII detection"
    echo ""
    echo "Note: --include-reverse cannot be used with --ner flag"
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

# Function to configure continuous crawl stages
configure_crawl_stages() {
    log "Configuring continuous crawl to only do document cracking..."
    
    local response=$(curl -s --request POST \
        --url "${BASE_URL}/v1/continuous_crawl/stages?stages=crack_docs" \
        --header 'accept: application/json' \
        --header "api-key: ${API_KEY}")
    
    log "Continuous crawl stages configured: $response"
}

# Function to start continuous crawl
start_continuous_crawl() {
    local index="$1"
    
    log "Starting continuous crawl for index: $index" >&2
    
    local response=$(curl -s --request POST \
        --url "${BASE_URL}/v1/indexes/continuous_crawl?max_hours_to_run=48&diskover_prefix=${index}" \
        --header 'accept: application/json' \
        --header "api-key: ${API_KEY}")
    
    log "Continuous crawl response: $response" >&2
    
    # Extract new index name from response
    local new_index=$(echo "$response" | jq -r '.index_name')
    
    if [[ "$new_index" == "null" || -z "$new_index" ]]; then
        log "ERROR: Failed to extract new index name from response" >&2
        exit 1
    fi
    
    log "New index created: $new_index" >&2
    echo "$new_index"
}

# Function to monitor cracking completion
monitor_cracking() {
    local new_index="$1"
    
    log "Monitoring cracking completion for index: $new_index"
    
    while true; do
        local status_response=$(curl -s --request GET \
            --url "${BASE_URL}/v1/index_status?index_name=${new_index}" \
            --header 'accept: application/json' \
            --header "api-key: ${API_KEY}")
        
        # Debug: show raw response
        log "Raw status response: $status_response" >&2
        
        local step=$(echo "$status_response" | jq -r '.[0].step' 2>/dev/null || echo "unknown")
        local cracked_count=$(echo "$status_response" | jq -r '.[0].cracked_count' 2>/dev/null || echo "unknown")
        local crawled_count=$(echo "$status_response" | jq -r '.[0].crawled_count' 2>/dev/null || echo "unknown")
        
        log "Current step: $step, $cracked_count out of $crawled_count cracked."
        
        if [[ "$step" == "finished_cracking" ]]; then
            log "Document cracking completed!"
            break
        fi
        
        log "Waiting for cracking to complete... (checking again in 60 seconds)"
        sleep 60
    done
}

# Function to run PII detection on all YAML files
run_pii_detection() {
    local new_index="$1"
    local yaml_dir="$2"
    local include_reverse="$3"
    local ner_mode="$4"
    
    if [[ "$ner_mode" == "true" ]]; then
        log "Running NER extraction using bulk_custom_pii.sh"
    else
        log "Running PII detection using bulk_custom_pii.sh"
    fi
    
    # Check if bulk_custom_pii.sh exists
    if [[ ! -f "./bulk_custom_pii.sh" ]]; then
        log "ERROR: bulk_custom_pii.sh not found in current directory"
        exit 1
    fi
    
    # Run bulk processing with appropriate flags
    if [[ "$ner_mode" == "true" ]]; then
        log "Running NER extraction"
        ./bulk_custom_pii.sh --ner "$new_index" "$yaml_dir"
    elif [[ "$include_reverse" == "true" ]]; then
        log "Including reverse PII detection"
        ./bulk_custom_pii.sh --include-reverse "$new_index" "$yaml_dir"
    else
        log "Running normal PII detection only"
        ./bulk_custom_pii.sh "$new_index" "$yaml_dir"
    fi
}

# Function to clean document_text
clean_document_text() {
    local new_index="$1"
    
    log "Cleaning document_text from index: $new_index"
    
    local response=$(curl -s --request POST \
        --url "${BASE_URL}/v1/indexes/${new_index}/clean_document_text" \
        --header "api-key: ${API_KEY}")
    
    log "Clean document_text response: $response"
    
    # Wait for cleaning to complete
    log "Waiting 10 seconds for document_text cleaning to complete..."
    sleep 10
}

# Function to submit index
submit_index() {
    local new_index="$1"
    
    log "Submitting index: $new_index"
    
    local response=$(curl -s --request POST \
        --url "${BASE_URL}/v1/indexes/${new_index}/submit" \
        --header "api-key: ${API_KEY}")
    
    log "Submit index response: $response"
}

# Function to delete index (for test mode)
delete_index() {
    local new_index="$1"
    
    log "Deleting test index: $new_index"
    
    local response=$(curl -s --request DELETE \
        --url "${ES_URL}/${new_index}" \
        --header 'authorization: Basic ZWxhc3RpYzpjaGFuZ2VtZQ==' \
        --header 'content-type: application/json')
    
    log "Delete index response: $response"
}

# Function to rollback continuous crawl stages (for test mode)
rollback_crawl_stages() {
    log "Rolling back continuous crawl stages to default..."
    
    local stages="find_dupes%2C%20apply_rules%2C%20crack_docs%2C%20find_named_entities%2C%20find_pii%2C%20clean_documents_text%2C%20submit_docs%2C%20submit_binaries"
    
    local response=$(curl -s --request POST \
        --url "${BASE_URL}/v1/continuous_crawl/stages?stages=${stages}" \
        --header 'accept: application/json' \
        --header "api-key: ${API_KEY}")
    
    log "Rollback stages response: $response"
}

# Main function
main() {
    check_jq
    
    # Parse command line arguments
    local test_mode=false
    local no_submit=false
    local include_reverse=false
    local ner_mode=false
    local args=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --test)
                test_mode=true
                shift
                ;;
            --no-submit)
                no_submit=true
                shift
                ;;
            --include-reverse)
                include_reverse=true
                shift
                ;;
            --ner)
                ner_mode=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    
    # Check required arguments
    if [[ ${#args[@]} -ne 2 ]]; then
        log "ERROR: Missing required arguments"
        usage
    fi
    
    local index="${args[0]}"
    local yaml_dir="${args[1]}"
    
    # Validate flag combinations
    if [[ "$include_reverse" == "true" && "$ner_mode" == "true" ]]; then
        log "ERROR: --include-reverse cannot be used with --ner flag"
        exit 1
    fi
    
    if [[ "$ner_mode" == "true" ]]; then
        log "Starting continuous crawl NER extraction script"
    else
        log "Starting continuous crawl PII detection script"
    fi
    log "Test mode: $test_mode"
    log "No submit mode: $no_submit"
    log "Include reverse detection: $include_reverse"
    log "NER mode: $ner_mode"
    log "Index: $index"
    log "YAML directory: $yaml_dir"
    
    # Configure continuous crawl stages
    configure_crawl_stages

    # Prune old continuous crawl indices
    log "Pruning old continuous crawl indices with prefix: $index"
    local prune_response=$(curl -s --request DELETE \
        --url "${BASE_URL}/v1/indexes/prune_stale_indices?index_prefix=${index}" \
        --header 'accept: application/json' \
        --header "api-key: ${API_KEY}")
    
    log "Prune response: $prune_response" 

    # Start continuous crawl
    local new_index=$(start_continuous_crawl "$index")

    echo Waiting 20 seconds for the crawl to start...
    sleep 20
    
    # Monitor cracking completion
    monitor_cracking "$new_index"
    
    # Run PII detection
    run_pii_detection "$new_index" "$yaml_dir" "$include_reverse" "$ner_mode"
    
    if [[ "$test_mode" == true ]]; then
        log "Test mode: Skipping submission but keeping index for review"
        log "Index '$new_index' will be pruned on next run"
        rollback_crawl_stages
    elif [[ "$no_submit" == true ]]; then
        log "No submit mode: Skipping submission but keeping index"
    else
        # Submit index
        submit_index "$new_index"
    fi
    
    log "Script completed successfully"
}

# Run main function with all arguments
main "$@"