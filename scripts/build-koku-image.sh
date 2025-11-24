#!/bin/bash
# Script to build Koku image in OpenShift from local source

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KOKU_SOURCE="${KOKU_SOURCE:-$(cd "${PROJECT_ROOT}/../koku" && pwd)}"
NAMESPACE="${NAMESPACE:-cost-mgmt}"
BUILD_NAME="${BUILD_NAME:-cost-mgmt-cost-management-onprem-koku-api}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ ${NC}$1"
}

log_success() {
    echo -e "${GREEN}✅${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠️ ${NC}$1"
}

log_error() {
    echo -e "${RED}❌${NC} $1"
}

# Check if we're logged into OpenShift
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift. Please run 'oc login' first."
    exit 1
fi

# Check if Koku source exists
if [ ! -d "$KOKU_SOURCE" ]; then
    log_error "Koku source directory not found: $KOKU_SOURCE"
    log_info "Set KOKU_SOURCE environment variable to the correct path"
    exit 1
fi

if [ ! -f "$KOKU_SOURCE/Dockerfile" ]; then
    log_error "Dockerfile not found in: $KOKU_SOURCE"
    exit 1
fi

log_success "Found Koku source at: $KOKU_SOURCE"

# Check if namespace exists
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    log_error "Namespace '$NAMESPACE' not found"
    exit 1
fi

# Check if BuildConfig exists
if ! oc get buildconfig "$BUILD_NAME" -n "$NAMESPACE" &>/dev/null; then
    log_error "BuildConfig '$BUILD_NAME' not found in namespace '$NAMESPACE'"
    log_info "Deploy the Helm chart first to create the BuildConfig"
    exit 1
fi

log_success "BuildConfig found: $BUILD_NAME"

# Start the build
log_info "Starting binary build from local source..."
log_info "This will upload ~100MB of source code and may take 5-10 minutes"

cd "$KOKU_SOURCE"

# Start build with local source
if oc start-build "$BUILD_NAME" -n "$NAMESPACE" --from-dir=. --follow; then
    log_success "Build completed successfully!"
    log_info "Image available as: ${BUILD_NAME}:${IMAGE_TAG}"
else
    log_error "Build failed. Check logs with: oc logs -f bc/$BUILD_NAME -n $NAMESPACE"
    exit 1
fi

# Check if image was pushed
if oc get imagestream "$BUILD_NAME" -n "$NAMESPACE" &>/dev/null; then
    log_success "Image pushed to ImageStream: $BUILD_NAME"

    # Show image details
    log_info "Image details:"
    oc get imagestream "$BUILD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.tags[?(@.tag=="'"$IMAGE_TAG"'")].items[0].dockerImageReference}{"\n"}'
else
    log_warn "ImageStream not found, but build may have succeeded"
fi

log_success "Done! You can now deploy/upgrade the Helm chart"
log_info "The deployment will automatically use the built image from the ImageStream"

