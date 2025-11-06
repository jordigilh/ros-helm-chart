#!/usr/bin/env bash
# Script to pull amd64 images from Docker Hub and push to OpenShift internal registry
# This avoids Docker Hub rate limits by caching images in the cluster
#
# Prerequisites:
#   1. Authenticated to Docker Hub: docker login docker.io
#   2. Authenticated to OpenShift: oc login
#   3. Access to OpenShift internal registry

set -e

NAMESPACE="${NAMESPACE:-cost-mgmt}"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
PUSH_OPTS=""
USE_OC_MIRROR=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# Images to pull (Docker Hub -> OpenShift internal registry)
# Using parallel arrays for compatibility
SOURCE_IMAGES=(
    "docker.io/trinodb/trino:latest"
    "docker.io/apache/hive:3.1.3"
)
TARGET_NAMES=(
    "trino:latest"
    "hive:3.1.3"
)

echo ""
log_info "=== AMD64 Image Pull and Push Plan ==="
echo ""
echo "Source:       Docker Hub (authenticated)"
echo "Destination:  OpenShift Internal Registry"
echo "Namespace:    ${NAMESPACE}"
echo "Architecture: linux/amd64 (forced)"
echo "Method:       podman/docker pull -> tag -> push"
echo ""

# Check if docker or podman is available
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
else
    log_error "Neither podman nor docker found. Install one of them:"
    echo "  macOS:   brew install podman"
    echo "          podman machine init && podman machine start"
    exit 1
fi

log_info "Using container runtime: ${CONTAINER_CMD}"
echo ""

# Check Docker Hub authentication
log_info "Checking Docker Hub authentication..."
if ! ${CONTAINER_CMD} login docker.io --get-login 2>/dev/null | grep -q "."; then
    log_error "Not authenticated to Docker Hub"
    echo ""
    echo "Please login first:"
    echo "  ${CONTAINER_CMD} login docker.io"
    echo ""
    exit 1
fi
log_success "Authenticated to Docker Hub"

# Check OpenShift authentication
log_info "Checking OpenShift authentication..."
if ! oc whoami &>/dev/null; then
    log_error "Not authenticated to OpenShift"
    echo ""
    echo "Please login first:"
    echo "  oc login <cluster-url>"
    echo ""
    exit 1
fi
log_success "Authenticated to OpenShift as $(oc whoami)"

# Check namespace exists
if ! oc get namespace "${NAMESPACE}" &>/dev/null; then
    log_error "Namespace '${NAMESPACE}' does not exist"
    exit 1
fi

# Expose internal registry route if needed
log_info "Checking OpenShift internal registry access..."
REGISTRY_ROUTE=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$REGISTRY_ROUTE" ]; then
    log_warning "Internal registry route not exposed. Exposing it..."
    oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"defaultRoute":true}}'
    sleep 3
    REGISTRY_ROUTE=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
    log_success "Registry route: ${REGISTRY_ROUTE}"
else
    log_success "Registry route: ${REGISTRY_ROUTE}"
fi

# Authenticate to internal registry
log_info "Authenticating to OpenShift internal registry..."
OC_TOKEN=$(oc whoami -t)
# Try standard login first
if echo "${OC_TOKEN}" | ${CONTAINER_CMD} login -u $(oc whoami) --password-stdin ${REGISTRY_ROUTE} 2>/dev/null; then
    log_success "Authenticated to internal registry"
elif echo "${OC_TOKEN}" | ${CONTAINER_CMD} login -u unused --password-stdin ${REGISTRY_ROUTE} 2>/dev/null; then
    log_success "Authenticated to internal registry (with token)"
else
    log_warning "Standard authentication failed, will try TLS verification skip"
    if echo "${OC_TOKEN}" | ${CONTAINER_CMD} login -u unused --password-stdin --tls-verify=false ${REGISTRY_ROUTE} 2>/dev/null; then
        log_success "Authenticated to internal registry (insecure)"
        # Set flag to skip TLS for push
        PUSH_OPTS="--tls-verify=false"
    else
        log_error "Failed to authenticate to internal registry"
        log_info "Trying alternative: using oc image mirror instead..."
        USE_OC_MIRROR=true
    fi
fi

echo ""
log_info "=== Pulling and Pushing Images ==="
echo ""

FAILED_IMAGES=()
SUCCEEDED_IMAGES=()

for i in "${!SOURCE_IMAGES[@]}"; do
    source="${SOURCE_IMAGES[$i]}"
    target_name="${TARGET_NAMES[$i]}"
    internal_image="${REGISTRY_ROUTE}/${NAMESPACE}/${target_name}"

    log_info "Processing: $(basename "$source")"
    echo "  Source:       $source"
    echo "  Architecture: linux/amd64"
    echo "  Destination:  $internal_image"
    echo ""

    # Pull with amd64 platform
    log_info "  Pulling amd64 image from Docker Hub..."
    if ! ${CONTAINER_CMD} pull --platform linux/amd64 "$source"; then
        log_error "  Failed to pull $source"
        FAILED_IMAGES+=("$source")
        echo ""
        continue
    fi
    log_success "  Pulled successfully"

    # Tag for internal registry
    log_info "  Tagging for internal registry..."
    if ! ${CONTAINER_CMD} tag "$source" "$internal_image"; then
        log_error "  Failed to tag image"
        FAILED_IMAGES+=("$source")
        echo ""
        continue
    fi
    log_success "  Tagged successfully"

    # Push to internal registry
    log_info "  Pushing to OpenShift internal registry..."
    if [ "${USE_OC_MIRROR}" = "true" ]; then
        # Use oc image mirror as fallback
        if ! oc image mirror "$source" "$internal_image" --filter-by-os='linux/amd64' --insecure=true; then
            log_error "  Failed to push to internal registry"
            FAILED_IMAGES+=("$source")
            echo ""
            continue
        fi
    else
        # Use podman/docker push
        if ! ${CONTAINER_CMD} push ${PUSH_OPTS} "$internal_image"; then
            log_error "  Failed to push to internal registry"
            FAILED_IMAGES+=("$source")
            echo ""
            continue
        fi
    fi
    log_success "  Pushed successfully"

    # Create ImageStream if it doesn't exist
    log_info "  Creating/updating ImageStream..."
    cat <<EOF | oc apply -f - >/dev/null
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: $(echo ${target_name} | cut -d: -f1)
  namespace: ${NAMESPACE}
spec:
  lookupPolicy:
    local: true
EOF
    log_success "  ImageStream ready"

    SUCCEEDED_IMAGES+=("$source -> $internal_image")
    echo ""
done

echo ""
log_info "=== Summary ==="
echo ""
echo "Total images:     ${#SOURCE_IMAGES[@]}"
echo "Succeeded:        ${GREEN}${#SUCCEEDED_IMAGES[@]}${NC}"
echo "Failed:           ${RED}${#FAILED_IMAGES[@]}${NC}"
echo ""

if [ ${#FAILED_IMAGES[@]} -gt 0 ]; then
    log_error "The following images failed:"
    for img in "${FAILED_IMAGES[@]}"; do
        echo "  ✗ $img"
    done
    echo ""
    exit 1
fi

log_success "All images successfully cached in OpenShift!"
echo ""

# Generate updated values.yaml snippet
log_info "=== Updated values.yaml Configuration ==="
echo ""
echo "Use internal registry images (no external pulls needed):"
echo ""
echo "---8<--- CUT HERE ---8<---"
echo "trino:"
echo "  coordinator:"
echo "    image:"
echo "      repository: ${INTERNAL_REGISTRY}/${NAMESPACE}/trino"
echo "      tag: \"latest\""
echo "  worker:"
echo "    image:"
echo "      repository: ${INTERNAL_REGISTRY}/${NAMESPACE}/trino"
echo "      tag: \"latest\""
echo ""
echo "  metastore:"
echo "    image:"
echo "      repository: ${INTERNAL_REGISTRY}/${NAMESPACE}/hive"
echo "      tag: \"3.1.3\""
echo "---8<--- CUT HERE ---8<---"
echo ""

log_info "Next steps:"
echo "  1. Update cost-management-onprem/values-koku.yaml with above config"
echo "  2. Run: helm upgrade cost-mgmt ./cost-management-onprem -f cost-management-onprem/values-koku.yaml"
echo "  3. Delete Trino/Hive pods to force restart with internal images"
echo ""
log_success "Done! No more Docker Hub rate limits!"

