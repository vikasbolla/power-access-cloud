#!/usr/bin/env bash
# Update the PAC Catalog CRD spec.vm.image field with the newly imported
# CentOS image name so the operator picks it up on next reconcile.
#
# Required environment variables:
#   WORK_DIR           - path containing image-metadata.json
#   CATALOG_NAME       - name of the Catalog CR to update (e.g. centos-10)
#   CATALOG_NAMESPACE  - namespace where the Catalog CR lives (e.g. pac-system)
#   KUBECONFIG         - path to kubeconfig (or use in-cluster service account)
#
# Optional:
#   DRY_RUN            - set to "true" to print the patch without applying it

set -o errexit
set -o nounset

WORK_DIR="${WORK_DIR:-/data/centos-images}"
CATALOG_NAME="${CATALOG_NAME:?CATALOG_NAME environment variable is required}"
CATALOG_NAMESPACE="${CATALOG_NAMESPACE:?CATALOG_NAMESPACE environment variable is required}"
DRY_RUN="${DRY_RUN:-false}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ── Read image name from metadata written by download-and-convert-centos.sh ──
get_image_name() {
    local metadata_file="${WORK_DIR}/image-metadata.json"

    if [ ! -f "$metadata_file" ]; then
        log_error "Metadata file not found: $metadata_file"
        exit 1
    fi

    local image_name
    image_name=$(jq -r '.image_name // empty' "$metadata_file")

    if [ -z "$image_name" ]; then
        log_error "image_name not found in $metadata_file"
        exit 1
    fi

    echo "$image_name"
}

# ── Read image ID from metadata (for logging/audit only) ──
get_image_id() {
    local metadata_file="${WORK_DIR}/image-metadata.json"
    jq -r '.powervs_image_id // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown"
}

# ── Verify the Catalog CR exists before patching ──
verify_catalog_exists() {
    if ! kubectl get catalog "$CATALOG_NAME" \
            --namespace "$CATALOG_NAMESPACE" \
            --output name \
            > /dev/null 2>&1; then
        log_error "Catalog CR '$CATALOG_NAME' not found in namespace '$CATALOG_NAMESPACE'"
        log_error "Available catalogs:"
        kubectl get catalogs --namespace "$CATALOG_NAMESPACE" 2>&1 >&2 || true
        exit 1
    fi
    log_info "Catalog CR '$CATALOG_NAME' found in namespace '$CATALOG_NAMESPACE'"
}

# ── Read the current image name in the CRD ──
get_current_image() {
    kubectl get catalog "$CATALOG_NAME" \
        --namespace "$CATALOG_NAMESPACE" \
        --output jsonpath='{.spec.vm.image}' 2>/dev/null || echo ""
}

# ── Patch spec.vm.image ──
patch_catalog() {
    local new_image="$1"

    local patch
    patch=$(printf '{"spec":{"vm":{"image":"%s"}}}' "$new_image")

    if [ "$DRY_RUN" = "true" ]; then
        log_warn "DRY RUN — would apply patch:"
        log_warn "  kubectl patch catalog $CATALOG_NAME -n $CATALOG_NAMESPACE --type=merge -p '$patch'"
        return 0
    fi

    log_info "Applying patch: $patch"
    kubectl patch catalog "$CATALOG_NAME" \
        --namespace "$CATALOG_NAMESPACE" \
        --type merge \
        --patch "$patch"

    log_info "Patch applied successfully"
}

# ── Verify the patch took effect ──
verify_patch() {
    local expected_image="$1"

    local actual_image
    actual_image=$(get_current_image)

    if [ "$actual_image" = "$expected_image" ]; then
        log_info "Verification passed: spec.vm.image = '$actual_image'"
    else
        log_error "Verification failed: expected '$expected_image', got '$actual_image'"
        exit 1
    fi
}

# ── Main ──
main() {
    log_info "Starting Catalog CRD update"
    log_info "Catalog     : $CATALOG_NAME"
    log_info "Namespace   : $CATALOG_NAMESPACE"

    local image_name
    image_name=$(get_image_name)
    local image_id
    image_id=$(get_image_id)

    log_info "New image name : $image_name"
    log_info "New image ID   : $image_id  (audit only — CRD stores name)"

    verify_catalog_exists

    local current_image
    current_image=$(get_current_image)
    log_info "Current image  : ${current_image:-<not set>}"

    # ── Idempotency check ──
    if [ "$current_image" = "$image_name" ]; then
        log_info "=========================================="
        log_info "Catalog already references '$image_name'"
        log_info "No update needed — skipping patch"
        log_info "=========================================="
        return 0
    fi

    patch_catalog "$image_name"

    if [ "$DRY_RUN" != "true" ]; then
        verify_patch "$image_name"
    fi

    log_info "=========================================="
    log_info "Catalog CRD updated successfully!"
    log_info "  $CATALOG_NAME  spec.vm.image: $current_image → $image_name"
    log_info "=========================================="
}

main "$@"
