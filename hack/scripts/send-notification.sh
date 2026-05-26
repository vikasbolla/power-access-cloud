#!/usr/bin/env bash
# Script to send Slack notifications about the automation status

set -o nounset
set -o pipefail

# Configuration
WORK_DIR="${WORK_DIR:-/tmp/centos-images}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
JOB_STATUS="${JOB_STATUS:-unknown}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Slack webhook is configured
check_slack_config() {
    if [ -z "$SLACK_WEBHOOK_URL" ]; then
        log_warn "SLACK_WEBHOOK_URL not configured, skipping notification"
        return 1
    fi
    return 0
}

# Get image metadata
get_metadata() {
    local metadata_file="${WORK_DIR}/image-metadata.json"
    
    if [ -f "$metadata_file" ]; then
        cat "$metadata_file"
    else
        echo "{}"
    fi
}

# Build success message
build_success_message() {
    local metadata=$(get_metadata)
    local image_name=$(echo "$metadata" | jq -r '.image_name // "N/A"')
    local centos_version=$(echo "$metadata" | jq -r '.centos_version // "N/A"')
    local powervs_image_id=$(echo "$metadata" | jq -r '.powervs_image_id // "N/A"')
    local cos_bucket=$(echo "$metadata" | jq -r '.cos_bucket // "N/A"')
    local cos_object=$(echo "$metadata" | jq -r '.cos_object_name // "N/A"')
    
    local workflow_url=""
    if [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_REPOSITORY" ]; then
        workflow_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    fi
    
    cat <<EOF
{
  "text": "✅ CentOS Image Automation - Success",
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "✅ CentOS Image Update - Success",
        "emoji": true
      }
    },
    {
      "type": "section",
      "fields": [
        {
          "type": "mrkdwn",
          "text": "*Image Name:*\n\`${image_name}\`"
        },
        {
          "type": "mrkdwn",
          "text": "*CentOS Version:*\n${centos_version}"
        },
        {
          "type": "mrkdwn",
          "text": "*PowerVS Image ID:*\n\`${powervs_image_id}\`"
        },
        {
          "type": "mrkdwn",
          "text": "*COS Bucket:*\n\`${cos_bucket}\`"
        }
      ]
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*COS Object:* \`${cos_object}\`"
      }
    },
    {
      "type": "divider"
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Next Steps:*\n• Verify image in PowerVS console\n• Test deploy a VM with the new image\n• Update Catalog CRD with new image ID"
      }
    }
EOF

    if [ -n "$workflow_url" ]; then
        cat <<EOF
    ,
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "<${workflow_url}|View Workflow Run>"
      }
    }
EOF
    fi

    cat <<EOF
  ]
}
EOF
}

# Build failure message
build_failure_message() {
    local workflow_url=""
    if [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_REPOSITORY" ]; then
        workflow_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    fi
    
    # Try to get error from logs
    local error_msg="Check workflow logs for details"
    if [ -f "${WORK_DIR}/conversion.log" ]; then
        error_msg=$(tail -20 "${WORK_DIR}/conversion.log" | grep -i "error" | head -5 | sed 's/"/\\"/g' || echo "Check conversion.log for details")
    fi
    
    cat <<EOF
{
  "text": "❌ CentOS Image Automation - Failed",
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "❌ CentOS Image Update - Failed",
        "emoji": true
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Status:* Failed\n*Error:* ${error_msg}"
      }
    },
    {
      "type": "divider"
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Action Required:*\n• Review workflow logs\n• Check PowerVM connectivity\n• Verify IBM Cloud credentials\n• Check disk space on PowerVM"
      }
    }
EOF

    if [ -n "$workflow_url" ]; then
        cat <<EOF
    ,
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "<${workflow_url}|View Workflow Run>"
      }
    }
EOF
    fi

    cat <<EOF
  ]
}
EOF
}

# Send notification to Slack
send_notification() {
    local message="$1"
    
    log_info "Sending notification to Slack..."
    
    local response=$(curl -s -X POST \
        -H 'Content-Type: application/json' \
        -d "$message" \
        "$SLACK_WEBHOOK_URL")
    
    if [ "$response" == "ok" ]; then
        log_info "Notification sent successfully"
        return 0
    else
        log_error "Failed to send notification: $response"
        return 1
    fi
}

# Main execution
main() {
    log_info "Preparing notification"
    log_info "Job status: $JOB_STATUS"
    
    # Check if Slack is configured
    if ! check_slack_config; then
        log_info "Skipping notification"
        exit 0
    fi
    
    # Build message based on status
    local message=""
    case "$JOB_STATUS" in
        success)
            log_info "Building success message..."
            message=$(build_success_message)
            ;;
        failure)
            log_info "Building failure message..."
            message=$(build_failure_message)
            ;;
        *)
            log_warn "Unknown job status: $JOB_STATUS"
            message=$(build_failure_message)
            ;;
    esac
    
    # Send notification
    if send_notification "$message"; then
        log_info "Notification process completed"
    else
        log_warn "Notification failed but continuing"
    fi
}

# Run main function
main "$@"


