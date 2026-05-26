#!/usr/bin/env bash
# Script to import OVA image from COS to PowerVS workspace

set -o errexit
set -o nounset
set -o pipefail

# Configuration
WORK_DIR="${WORK_DIR:-/tmp/centos-images}"
IBM_API_KEY="${IBM_API_KEY:?IBM_API_KEY environment variable is required}" # pragma: allowlist secret
POWERVS_WORKSPACE_CRN="${POWERVS_WORKSPACE_CRN:?POWERVS_WORKSPACE_CRN environment variable is required}"
COS_BUCKET_NAME="${COS_BUCKET_NAME:?COS_BUCKET_NAME environment variable is required}"
COS_REGION="${COS_REGION:-us-south}"
IMPORT_TIMEOUT="${IMPORT_TIMEOUT:-3600}"  # 1 hour timeout

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

# Check required tools
check_requirements() {
    local missing_tools=()
    
    for tool in pvsadm jq; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    log_info "All required tools are available"
}

# Get image metadata
get_image_metadata() {
    local metadata_file="${WORK_DIR}/image-metadata.json"
    
    if [ ! -f "$metadata_file" ]; then
        log_error "Metadata file not found: $metadata_file"
        exit 1
    fi
    
    cat "$metadata_file"
}

# Import image to PowerVS
import_image() {
    local image_name="$1"
    local cos_object_name="$2"
    
    log_info "Importing image to PowerVS workspace"
    log_info "Image name: $image_name"
    log_info "COS object: $cos_object_name"
    log_info "Workspace CRN: $POWERVS_WORKSPACE_CRN"
    
    # Set IBM Cloud API key
    export IBMCLOUD_API_KEY="$IBM_API_KEY"
    
    # Import using pvsadm
    log_info "Starting import with pvsadm..."
    
    local import_output="${WORK_DIR}/import-output.json"
    
    pvsadm image import \
        --workspace-crn "$POWERVS_WORKSPACE_CRN" \
        --bucket "$COS_BUCKET_NAME" \
        --bucket-region "$COS_REGION" \
        --object "$cos_object_name" \
        --pvs-image-name "$image_name" \
        --watch \
        2>&1 | tee "${WORK_DIR}/import.log"
    
    local import_status=$?
    
    if [ $import_status -eq 0 ]; then
        log_info "Import completed successfully"
    else
        log_error "Import failed with status: $import_status"
        exit 1
    fi
}

# Get imported image ID
get_image_id() {
    local image_name="$1"
    
    log_info "Retrieving image ID from PowerVS workspace..."
    
    export IBMCLOUD_API_KEY="$IBM_API_KEY"
    
    # List images and find the one we just imported
    local image_id=$(pvsadm get images --workspace-crn "$POWERVS_WORKSPACE_CRN" --json 2>/dev/null | \
        jq -r --arg name "$image_name" '.[] | select(.name == $name) | .imageID' | head -1)
    
    if [ -z "$image_id" ] || [ "$image_id" == "null" ]; then
        log_warn "Could not retrieve image ID automatically"
        return 1
    fi
    
    log_info "Image ID: $image_id"
    echo "$image_id"
}

# Update metadata with PowerVS information
update_metadata() {
    local image_id="$1"
    local metadata_file="${WORK_DIR}/image-metadata.json"
    local temp_file="${metadata_file}.tmp"
    
    jq --arg workspace "$POWERVS_WORKSPACE_CRN" \
       --arg image_id "$image_id" \
       '. + {
           powervs_workspace_crn: $workspace,
           powervs_image_id: $image_id,
           import_date: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
       }' "$metadata_file" > "$temp_file"
    
    mv "$temp_file" "$metadata_file"
    
    log_info "Metadata updated with PowerVS information"
}

# Main execution
main() {
    log_info "Starting image import to PowerVS workspace"
    log_info "Work directory: $WORK_DIR"
    
    # Check requirements
    check_requirements
    
    # Get metadata
    local metadata=$(get_image_metadata)
    local image_name=$(echo "$metadata" | jq -r '.image_name')
    local cos_object_name=$(echo "$metadata" | jq -r '.cos_object_name')
    
    if [ -z "$image_name" ] || [ "$image_name" == "null" ]; then
        log_error "Image name not found in metadata"
        exit 1
    fi
    
    if [ -z "$cos_object_name" ] || [ "$cos_object_name" == "null" ]; then
        log_error "COS object name not found in metadata"
        exit 1
    fi
    
    log_info "Image name: $image_name"
    log_info "COS object: $cos_object_name"
    
    # Import image
    import_image "$image_name" "$cos_object_name"
    
    # Get image ID
    local image_id=""
    if image_id=$(get_image_id "$image_name"); then
        # Update metadata
        update_metadata "$image_id"
    else
        log_warn "Could not retrieve image ID, but import may have succeeded"
    fi
    
    log_info "=========================================="
    log_info "Import completed successfully!"
    log_info "Workspace: $POWERVS_WORKSPACE_CRN"
    log_info "Image name: $image_name"
    if [ -n "$image_id" ]; then
        log_info "Image ID: $image_id"
    fi
    log_info "=========================================="
    
    # Display next steps
    log_info ""
    log_info "Next steps:"
    log_info "1. Verify the image in PowerVS console"
    log_info "2. Test deploy a VM with the new image"
    log_info "3. Update Catalog CRD with new image ID"
}

# Run main function
main "$@"


