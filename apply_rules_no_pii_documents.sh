#!/bin/bash

# Script to mark documents without PII as "Do not submit"
# Usage: ./mark_no_pii_documents.sh <index_name> [--watch-timeout=SECONDS]

set -e

WATCH_TIMEOUT=""
INDEX_NAME=""
RATE_LIMIT="500"  # Default aggressive rate
SCROLL_SIZE="1000"  # Default large scroll size

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --watch-timeout=*)
            WATCH_TIMEOUT="${1#*=}"
            shift
            ;;
        --rate-limit=*)
            RATE_LIMIT="${1#*=}"
            shift
            ;;
        --scroll-size=*)
            SCROLL_SIZE="${1#*=}"
            shift
            ;;
        *)
            if [ -z "$INDEX_NAME" ]; then
                INDEX_NAME="$1"
            else
                echo "Error: Unknown argument '$1'"
                echo "Usage: $0 <index_name> [OPTIONS]"
                echo "Options:"
                echo "  --watch-timeout=SECONDS    Stop monitoring after SECONDS (default: unlimited)"
                echo "  --rate-limit=REQUESTS      Requests per second (default: 500)"
                echo "  --scroll-size=DOCUMENTS    Documents per batch (default: 1000)"
                echo "Examples:"
                echo "  $0 my_index"
                echo "  $0 my_index --rate-limit=100 --watch-timeout=30"
                echo "  $0 my_index --rate-limit=10 --scroll-size=100  # Conservative settings"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$INDEX_NAME" ]; then
    echo "Usage: $0 <index_name> [OPTIONS]"
    echo "Options:"
    echo "  --watch-timeout=SECONDS    Stop monitoring after SECONDS (default: unlimited)"
    echo "  --rate-limit=REQUESTS      Requests per second (default: 500)"
    echo "  --scroll-size=DOCUMENTS    Documents per batch (default: 1000)"
    echo "Examples:"
    echo "  $0 my_index"
    echo "  $0 my_index --rate-limit=100 --watch-timeout=30"
    echo "  $0 my_index --rate-limit=10 --scroll-size=100  # Conservative settings"
    exit 1
fi

echo "Marking documents without PII in index '$INDEX_NAME' as 'Do not submit'..."
echo "This will add rule_outcome='Do not submit' and rules_name='Has no PII' to documents without PII"
echo "Settings: Rate limit=${RATE_LIMIT} req/sec, Scroll size=${SCROLL_SIZE} docs/batch"
echo

# Execute the update_by_query request
RESPONSE=$(curl --silent --request POST \
    --url "http://localhost:9200/${INDEX_NAME}/_update_by_query?pretty=true&scroll_size=${SCROLL_SIZE}&requests_per_second=${RATE_LIMIT}&wait_for_completion=false" \
    --header 'content-type: application/json' \
    --data '{
        "script": {
            "source": "if (ctx._source.containsKey('\''PII'\'') && ctx._source.PII != null) { def pii = ctx._source.PII; int sum = 0; for (entry in pii.entrySet()) { if (entry.getValue() instanceof Boolean && entry.getValue() == true) { sum += 1; } } if (sum == 0) { ctx._source.rule_outcome = '\''Do not submit'\''; ctx._source.rules_name = '\''Has no PII'\''; } } else { ctx._source.rule_outcome = '\''Do not submit'\''; ctx._source.rules_name = '\''Has no PII'\''; }"
        },
        "query": {
            "bool": {
                "must": [
                    {"term": {"doctype": "file"}}
                ],
                "must_not": [
                    {"exists": {"field": "rule_outcome"}}
                ]
            }
        }
    }')

echo "Response from Elasticsearch:"
echo "$RESPONSE"
echo

# Extract task ID from the response
TASK_ID=$(echo "$RESPONSE" | grep -o '"task" : "[^"]*"' | sed 's/"task" : "//' | sed 's/"//')

if [ -z "$TASK_ID" ]; then
    echo "Error: Could not extract task ID from response. Task may have completed immediately or failed."
    exit 1
fi

echo "Task ID: $TASK_ID"
if [ -n "$WATCH_TIMEOUT" ]; then
    echo "Monitoring task progress for $WATCH_TIMEOUT seconds... (Press Ctrl+C to stop monitoring, task will continue running)"
else
    echo "Monitoring task progress... (Press Ctrl+C to stop monitoring, task will continue running)"
fi
echo

# Monitor the task until completion
START_TIME=$(date +%s)
LAST_UPDATED=0
LAST_TIME=$START_TIME
CHECK_COUNT=0

while true; do
    CHECK_COUNT=$((CHECK_COUNT + 1))
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    TASK_STATUS=$(curl --silent --request GET "http://localhost:9200/_tasks/${TASK_ID}?pretty")
    
    # Check if task still exists (completed tasks are removed from _tasks API)
    if echo "$TASK_STATUS" | grep -q "resource_not_found_exception"; then
        echo "✓ Task completed successfully after ${ELAPSED} seconds!"
        echo
        echo "Final verification - checking if any documents were updated:"
        FINAL_COUNT=$(curl --silent --request GET "http://localhost:9200/${INDEX_NAME}/_search?size=0" \
            --header 'content-type: application/json' \
            --data '{
                "query": {
                    "bool": {
                        "must": [
                            {"term": {"rule_outcome": "Do not submit"}},
                            {"term": {"rules_name": "Has no PII"}}
                        ]
                    }
                }
            }' | grep -o '"total":[0-9]*' | sed 's/"total"://')
        echo "Documents marked as 'Do not submit': $FINAL_COUNT"
        break
    fi
    
    # Check for task errors or completion status
    if echo "$TASK_STATUS" | grep -q '"completed" : true'; then
        # Task completed but still in API, extract final results
        FINAL_TOTAL=$(echo "$TASK_STATUS" | grep -o '"total" : [0-9]*' | head -1 | sed 's/"total" : //')
        FINAL_UPDATED=$(echo "$TASK_STATUS" | grep -o '"updated" : [0-9]*' | sed 's/"updated" : //')
        echo "✓ Task completed successfully after ${ELAPSED} seconds!"
        echo "Final results: $FINAL_UPDATED/$FINAL_TOTAL documents updated"
        break
    fi
    
    # Extract detailed progress information (handle pretty-printed JSON with spaces)
    TOTAL=$(echo "$TASK_STATUS" | grep -o '"total" : [0-9]*' | head -1 | sed 's/"total" : //')
    UPDATED=$(echo "$TASK_STATUS" | grep -o '"updated" : [0-9]*' | sed 's/"updated" : //')
    CREATED=$(echo "$TASK_STATUS" | grep -o '"created" : [0-9]*' | sed 's/"created" : //')
    DELETED=$(echo "$TASK_STATUS" | grep -o '"deleted" : [0-9]*' | sed 's/"deleted" : //')
    BATCHES=$(echo "$TASK_STATUS" | grep -o '"batches" : [0-9]*' | sed 's/"batches" : //')
    VERSION_CONFLICTS=$(echo "$TASK_STATUS" | grep -o '"version_conflicts" : [0-9]*' | sed 's/"version_conflicts" : //')
    THROTTLED_MILLIS=$(echo "$TASK_STATUS" | grep -o '"throttled_millis" : [0-9]*' | sed 's/"throttled_millis" : //')
    REQUESTS_PER_SECOND=$(echo "$TASK_STATUS" | grep -o '"requests_per_second" : [0-9.-]*' | sed 's/"requests_per_second" : //')
    
    # Check timeout if specified
    if [ -n "$WATCH_TIMEOUT" ]; then
        if [ $ELAPSED -ge $WATCH_TIMEOUT ]; then
            echo "⏱ Watch timeout reached ($WATCH_TIMEOUT seconds). Task is still running in background."
            echo "Task ID: $TASK_ID"
            echo "Current progress: ${UPDATED:-0}/${TOTAL:-?} documents processed"
            echo "You can check task status manually with:"
            echo "  curl -X GET 'http://localhost:9200/_tasks/${TASK_ID}?pretty'"
            echo "Or monitor all tasks with:"
            echo "  curl -X GET 'http://localhost:9200/_tasks?pretty'"
            exit 0
        fi
    fi
    
    # Calculate processing rates and estimates
    if [ -n "$TOTAL" ] && [ -n "$UPDATED" ]; then
        DOCS_PER_SECOND=0
        if [ $ELAPSED -gt 0 ]; then
            DOCS_PER_SECOND=$((UPDATED / ELAPSED))
        fi
        
        # Calculate rate since last check
        DOCS_SINCE_LAST=$((UPDATED - LAST_UPDATED))
        TIME_SINCE_LAST=$((CURRENT_TIME - LAST_TIME))
        RECENT_RATE=0
        if [ $TIME_SINCE_LAST -gt 0 ] && [ $DOCS_SINCE_LAST -gt 0 ]; then
            RECENT_RATE=$((DOCS_SINCE_LAST / TIME_SINCE_LAST))
        fi
        
        # Estimate completion time
        REMAINING=$((TOTAL - UPDATED))
        ETA_SECONDS=0
        if [ $DOCS_PER_SECOND -gt 0 ] && [ $REMAINING -gt 0 ]; then
            ETA_SECONDS=$((REMAINING / DOCS_PER_SECOND))
        fi
        
        PERCENTAGE=0
        if [ $TOTAL -gt 0 ]; then
            PERCENTAGE=$((UPDATED * 100 / TOTAL))
        fi
        
        # Enhanced progress display
        printf "\r\033[K[%02d:%02d:%02d] " $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) $((ELAPSED%60))
        printf "Progress: %d/%d (%d%%) | " $UPDATED $TOTAL $PERCENTAGE
        printf "Batches: %d | " ${BATCHES:-0}
        
        if [ $DOCS_PER_SECOND -gt 0 ]; then
            printf "Rate: %d docs/sec " $DOCS_PER_SECOND
        fi
        
        if [ $ETA_SECONDS -gt 0 ] && [ $ETA_SECONDS -lt 3600 ]; then
            printf "| ETA: %dm%ds" $((ETA_SECONDS/60)) $((ETA_SECONDS%60))
        fi
        
        # Show additional details on every 3rd check
        if [ $((CHECK_COUNT % 3)) -eq 0 ]; then
            echo ""
            if [ -n "$VERSION_CONFLICTS" ] && [ "$VERSION_CONFLICTS" -gt 0 ]; then
                echo "  ⚠ Version conflicts: $VERSION_CONFLICTS"
            fi
            if [ -n "$THROTTLED_MILLIS" ] && [ "$THROTTLED_MILLIS" -gt 0 ]; then
                THROTTLED_SECONDS=$((THROTTLED_MILLIS / 1000))
                echo "  🕒 Throttled time: ${THROTTLED_SECONDS}s"
            fi
            if [ -n "$REQUESTS_PER_SECOND" ] && [ "$REQUESTS_PER_SECOND" != "-1.0" ]; then
                echo "  📈 Rate limit: $REQUESTS_PER_SECOND req/sec"
            fi
        fi
        
        LAST_UPDATED=$UPDATED
        LAST_TIME=$CURRENT_TIME
    else
        # Fallback display for when detailed metrics aren't available
        printf "\r\033[K[%02d:%02d:%02d] " $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) $((ELAPSED%60))
        if [ -n "$TOTAL" ] && [ -n "$UPDATED" ]; then
            printf "Progress: %d/%d documents | Batches: %d" ${UPDATED:-0} ${TOTAL:-0} ${BATCHES:-0}
        else
            printf "Task is initializing..."
        fi
    fi
    
    sleep 5
done

echo
echo "Script completed successfully!"
echo "Documents without PII have been marked with:"
echo "  - rule_outcome: 'Do not submit'"
echo "  - rules_name: 'Has no PII'"
echo "These documents will be exempt from RecordPoint submission."