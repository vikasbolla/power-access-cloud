#!/usr/bin/env bash
# Script to download latest CentOS Stream image and convert to OVA using pvsadm
# This script runs directly on a PowerVM with ppc64le architecture

set -o errexit
set -o nounset
set -o pipefail

# Configuration
CENTOS_VERSION="${CENTOS_VERSION:-10}"
WORK_DIR="${WORK_DIR:-/tmp/centos-images}"
IMAGE_PREP_TEMPLATE="${IMAGE_PREP_TEMPLATE:-./image-prep.template.static}"
IMAGE_SIZE="${IMAGE_SIZE:-120}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if running on ppc64le
check_architecture() {
    local arch=$(uname -m)
    if [[ "$arch" != "ppc64le" ]]; then
        log_error "This script must run on ppc64le architecture. Current: $arch"
        exit 1
    fi
    log_info "Architecture check passed: $arch"
}

# Check required tools
check_requirements() {
    local missing_tools=()
    local need_install=()
    
    # Check which tools are missing
    for tool in curl jq; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
            need_install+=($tool)
        fi
    done
    
    # Check wget or curl (at least one needed)
    if ! command -v wget &> /dev/null && ! command -v curl &> /dev/null; then
        missing_tools+=(wget)
        need_install+=(wget)
    fi
    
    # Check qemu-img (required by pvsadm)
    if ! command -v qemu-img &> /dev/null; then
        missing_tools+=(qemu-img)
        need_install+=(qemu-img)
    fi
    
    # Check pvsadm separately
    if ! command -v pvsadm &> /dev/null; then
        missing_tools+=(pvsadm)
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_warn "Missing tools: ${missing_tools[*]}"
        log_info "Installing missing tools..."
        
        # Install system packages first
        if [ ${#need_install[@]} -ne 0 ]; then
            log_info "Installing system packages: ${need_install[*]}"
            if command -v dnf &> /dev/null; then
                sudo dnf install -y "${need_install[@]}" || log_warn "Some packages failed to install"
            elif command -v yum &> /dev/null; then
                sudo yum install -y "${need_install[@]}" || log_warn "Some packages failed to install"
            else
                log_error "No package manager found (yum/dnf). Please install: ${need_install[*]}"
                exit 1
            fi
        fi
        
        # Install pvsadm if missing
        if [[ " ${missing_tools[*]} " =~ " pvsadm " ]]; then
            install_pvsadm
        fi
    fi
    
    log_info "All required tools are available"
}

# Install pvsadm
install_pvsadm() {
    log_info "Installing pvsadm..."
    local PVSADM_VERSION="v0.1.13"
    local ARCH="ppc64le"
    local DOWNLOAD_URL="https://github.com/ppc64le-cloud/pvsadm/releases/download/${PVSADM_VERSION}/pvsadm-linux-${ARCH}.tar.gz"
    local TAR_FILE="pvsadm-linux-${ARCH}.tar.gz"
    
    # Try wget first, fall back to curl
    if command -v wget &> /dev/null; then
        wget -q "$DOWNLOAD_URL" -O "$TAR_FILE"
    elif command -v curl &> /dev/null; then
        curl -sL "$DOWNLOAD_URL" -o "$TAR_FILE"
    else
        log_error "Neither wget nor curl is available. Please install one of them."
        exit 1
    fi
    
    tar -xzf "$TAR_FILE"
    sudo mv pvsadm /usr/local/bin/ 2>/dev/null || mv pvsadm /usr/local/bin/
    rm -f "$TAR_FILE"
    
    pvsadm version
    log_info "pvsadm installed successfully"
}

# Check disk space
check_disk_space() {
    local required_space_gb=100
    local available_space_gb=$(df -BG "$WORK_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [ "$available_space_gb" -lt "$required_space_gb" ]; then
        log_error "Insufficient disk space. Required: ${required_space_gb}GB, Available: ${available_space_gb}GB"
        exit 1
    fi
    
    log_info "Disk space check passed: ${available_space_gb}GB available"
}

# Get latest CentOS Stream image URL
get_latest_image_url() {
    log_info "Detecting latest CentOS Stream ${CENTOS_VERSION} image..."
    
    local base_url="https://cloud.centos.org/centos/${CENTOS_VERSION}-stream/ppc64le/images"
    
    # Get the latest image filename
    local latest_image=$(curl -s "$base_url/" | \
        grep -oP 'CentOS-Stream-GenericCloud-'"${CENTOS_VERSION}"'-[0-9]{8}\.[0-9]+\.ppc64le\.qcow2' | \
        sort -V | tail -1)
    
    if [ -z "$latest_image" ]; then
        log_error "Could not detect latest CentOS Stream ${CENTOS_VERSION} image"
        exit 1
    fi
    
    echo "${base_url}/${latest_image}"
}

# Download CentOS image
download_image() {
    local image_url="$1"
    local image_name=$(basename "$image_url")
    local image_path="${WORK_DIR}/${image_name}"
    
    log_info "Downloading image: $image_name"
    log_info "URL: $image_url"
    
    # Download with progress - try wget first, fall back to curl
    if command -v wget &> /dev/null; then
        log_info "Using wget for download..."
        wget -c -O "$image_path" "$image_url" >&2
    elif command -v curl &> /dev/null; then
        log_info "Using curl for download (this may take 5-10 minutes)..."
        # Use --progress-bar for simpler output, or -s for silent
        curl -# -L -C - -o "$image_path" "$image_url" >&2
    else
        log_error "Neither wget nor curl is available"
        exit 1
    fi
    
    # Check if download succeeded
    if [ ! -f "$image_path" ]; then
        log_error "Download failed: $image_path does not exist"
        exit 1
    fi
    
    log_info "Download completed: $(du -h "$image_path" | cut -f1)"
    
    # Download checksum if available
    local checksum_url="${image_url}.SHA256SUM"
    local checksum_exists=false
    
    if command -v wget &> /dev/null; then
        wget -q --spider "$checksum_url" 2>&1 && checksum_exists=true
    elif command -v curl &> /dev/null; then
        curl -s -I "$checksum_url" 2>&1 | grep -q "200 OK" && checksum_exists=true
    fi
    
    if [ "$checksum_exists" = true ]; then
        log_info "Downloading checksum..."
        if command -v wget &> /dev/null; then
            wget -q -O "${image_path}.SHA256SUM" "$checksum_url" >&2
        else
            curl -sL -o "${image_path}.SHA256SUM" "$checksum_url" >&2
        fi
        
        # Verify checksum
        log_info "Verifying checksum..."
        cd "$WORK_DIR"
        if sha256sum -c "${image_name}.SHA256SUM" 2>&1 | grep -q "OK"; then
            log_info "Checksum verification passed"
        else
            log_warn "Checksum verification failed or not available"
        fi
        cd - >/dev/null
    else
        log_warn "Checksum file not available, skipping verification"
    fi
    
    echo "$image_path"
}

# Convert qcow2 to OVA using pvsadm
convert_to_ova() {
    local qcow2_path="$1"
    local image_name=$(basename "$qcow2_path" .qcow2)
    
    # Extract date from image name (e.g., CentOS-Stream-GenericCloud-10-20251215.0.ppc64le.qcow2)
    local date_part=$(echo "$image_name" | grep -oP '\d{8}' | head -1)
    local ova_name="centos-${CENTOS_VERSION}-stream-${date_part}"
    
    # Check if OVA already exists
    local existing_ova=$(find "$WORK_DIR" -name "${ova_name}*.ova.gz" -type f 2>/dev/null | head -1)
    if [ -n "$existing_ova" ] && [ -f "$existing_ova" ]; then
        log_info "=========================================="
        log_info "OVA already exists: $(basename "$existing_ova")"
        log_info "Skipping conversion to save time"
        log_info "To force reconversion, delete: $existing_ova"
        log_info "=========================================="
        echo "$existing_ova"
        return 0
    fi
    
    log_info "Converting image to OVA format..."
    log_info "Image name: $ova_name"
    log_info "Source: $qcow2_path"
    
    # Check if prep template exists
    if [ ! -f "$IMAGE_PREP_TEMPLATE" ]; then
        log_error "Image prep template not found: $IMAGE_PREP_TEMPLATE"
        exit 1
    fi
    
    # Run pvsadm conversion
    cd "$WORK_DIR"
    
    log_info "Running pvsadm qcow2ova..."
    log_info "This may take 30-60 minutes..."
    
    # Run pvsadm and redirect all output to log file and stderr
    if pvsadm image qcow2ova \
        --image-name "$ova_name" \
        --image-url "$qcow2_path" \
        --image-dist centos \
        --prep-template "$IMAGE_PREP_TEMPLATE" \
        --skip-os-password \
        --image-size "$IMAGE_SIZE" \
        2>&1 | tee "${WORK_DIR}/conversion.log" >&2; then
        log_info "pvsadm conversion completed"
    else
        log_error "pvsadm conversion failed. Check ${WORK_DIR}/conversion.log for details"
        exit 1
    fi
    
    # Find the generated OVA file
    local ova_file=$(find "$WORK_DIR" -name "${ova_name}*.ova.gz" -type f 2>/dev/null | head -1)
    
    if [ -z "$ova_file" ] || [ ! -f "$ova_file" ]; then
        log_error "OVA file not found after conversion"
        log_error "Expected pattern: ${ova_name}*.ova.gz"
        log_error "Files in work directory:"
        ls -lh "$WORK_DIR" >&2
        exit 1
    fi
    
    log_info "Conversion completed successfully"
    log_info "OVA file: $ova_file"
    
    # Save metadata
    cat > "${WORK_DIR}/image-metadata.json" <<EOF
{
  "image_name": "$ova_name",
  "centos_version": "$CENTOS_VERSION",
  "source_qcow2": "$qcow2_path",
  "ova_file": "$ova_file",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "disk_size_gb": $IMAGE_SIZE
}
EOF
    
    echo "$ova_file"
}

# Main execution
main() {
    log_info "Starting CentOS Stream ${CENTOS_VERSION} image download and conversion"
    log_info "Work directory: $WORK_DIR"
    
    # Create work directory
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # Pre-flight checks
    check_architecture
    check_requirements
    check_disk_space
    
    # Get latest image URL
    local image_url=$(get_latest_image_url)
    log_info "Latest image URL: $image_url"
    
    # Download image
    local qcow2_path=$(download_image "$image_url")
    log_info "Downloaded to: $qcow2_path"
    
    # Convert to OVA
    local ova_file=$(convert_to_ova "$qcow2_path")
    
    log_info "=========================================="
    log_info "Process completed successfully!"
    log_info "OVA file: $ova_file"
    log_info "Metadata: ${WORK_DIR}/image-metadata.json"
    log_info "=========================================="
    
    # Display file sizes
    log_info "File sizes:"
    ls -lh "$qcow2_path" "$ova_file"
}

# Run main function
main "$@"


