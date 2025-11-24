#!/bin/bash
# Script to mirror Docker Hub images to Quay.io to avoid rate limits
#
# Usage:
#   QUAY_ORG=insights-onprem QUAY_USER=myuser QUAY_PASS=mypass ./mirror-images-to-quay.sh
#
# Or with skopeo:
#   QUAY_ORG=insights-onprem skopeo login quay.io
#   ./mirror-images-to-quay.sh

set -e

# Configuration
QUAY_ORG="${QUAY_ORG:-insights-onprem}"  # Change to your Quay.io organization
QUAY_REGISTRY="quay.io"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# Images to mirror (source -> target name)
declare -A IMAGES=(
    ["docker.io/trinodb/trino:latest"]="trino:latest"
    ["docker.io/apache/hive:3.1.3"]="hive:3.1.3"
)

# Check if skopeo is installed
if ! command -v skopeo &> /dev/null; then
    log_error "skopeo is not installed. Install it first:"
    echo "  macOS:    brew install skopeo"
    echo "  RHEL/CentOS: dnf install skopeo"
    echo "  Ubuntu:   apt install skopeo"
    exit 1
fi

# Check Quay.io authentication
log_info "Checking Quay.io authentication..."
if ! skopeo inspect "docker://${QUAY_REGISTRY}/${QUAY_ORG}/test:latest" &>/dev/null; then
    log_warning "Not authenticated to Quay.io or test repository doesn't exist"
    log_info "Please authenticate first:"
    echo ""
    echo "  Option 1: Interactive login"
    echo "    skopeo login quay.io"
    echo ""
    echo "  Option 2: Environment variables"
    echo "    export QUAY_USER=your-username"
    echo "    export QUAY_PASS=your-password"
    echo "    skopeo login -u \$QUAY_USER -p \$QUAY_PASS quay.io"
    echo ""
    read -p "Do you want to continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo ""
log_info "=== Image Mirroring Plan ==="
echo ""
echo "Source Registry:      docker.io (Docker Hub)"
echo "Destination Registry: ${QUAY_REGISTRY}/${QUAY_ORG}"
echo "Architecture:         linux/amd64"
echo "Images to mirror:     ${#IMAGES[@]}"
echo ""

for source in "${!IMAGES[@]}"; do
    target_name="${IMAGES[$source]}"
    echo "  • ${source}"
    echo "    → ${QUAY_REGISTRY}/${QUAY_ORG}/${target_name}"
done

echo ""
read -p "Proceed with mirroring? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_warning "Cancelled by user"
    exit 0
fi

echo ""
log_info "=== Starting Image Mirror ==="
echo ""

FAILED_IMAGES=()
SUCCEEDED_IMAGES=()

for source in "${!IMAGES[@]}"; do
    target_name="${IMAGES[$source]}"
    destination="${QUAY_REGISTRY}/${QUAY_ORG}/${target_name}"

    log_info "Mirroring: $(basename "$source")"
    echo "  Source:      $source"
    echo "  Destination: $destination"

    # Copy with skopeo (preserves all layers, multi-arch manifests, etc.)
    if skopeo copy \
        --override-os linux \
        --override-arch amd64 \
        --multi-arch all \
        --preserve-digests \
        "docker://$source" \
        "docker://$destination" 2>&1; then

        log_success "Successfully mirrored: $(basename "$source")"
        SUCCEEDED_IMAGES+=("$source -> $destination")
    else
        log_error "Failed to mirror: $(basename "$source")"
        FAILED_IMAGES+=("$source")
    fi
    echo ""
done

echo ""
log_info "=== Mirror Summary ==="
echo ""
echo "Total images:     ${#IMAGES[@]}"
echo "Succeeded:        ${GREEN}${#SUCCEEDED_IMAGES[@]}${NC}"
echo "Failed:           ${RED}${#FAILED_IMAGES[@]}${NC}"
echo ""

if [ ${#FAILED_IMAGES[@]} -gt 0 ]; then
    log_error "The following images failed to mirror:"
    for img in "${FAILED_IMAGES[@]}"; do
        echo "  ✗ $img"
    done
    echo ""
    exit 1
fi

log_success "All images successfully mirrored!"
echo ""

# Generate updated values.yaml snippet
log_info "=== Updated values.yaml Configuration ==="
echo ""
echo "Copy this to your values-koku.yaml:"
echo ""
echo "---8<--- CUT HERE ---8<---"
echo "trino:"
echo "  coordinator:"
echo "    image:"
echo "      repository: ${QUAY_REGISTRY}/${QUAY_ORG}/trino"
echo "      tag: \"latest\""
echo "  worker:"
echo "    image:"
echo "      repository: ${QUAY_REGISTRY}/${QUAY_ORG}/trino"
echo "      tag: \"latest\""
echo ""
echo "  metastore:"
echo "    image:"
echo "      repository: ${QUAY_REGISTRY}/${QUAY_ORG}/hive"
echo "      tag: \"3.1.3\""
echo "---8<--- CUT HERE ---8<---"
echo ""

log_info "Next steps:"
echo "  1. Update cost-management-onprem/values-koku.yaml with the above config"
echo "  2. Run: helm upgrade cost-mgmt ./cost-management-onprem -f cost-management-onprem/values-koku.yaml"
echo "  3. Verify pods start successfully without rate limit errors"
echo ""
log_success "Done!"

