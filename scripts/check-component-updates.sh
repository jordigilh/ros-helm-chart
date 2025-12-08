#!/bin/bash
# Check for component updates referenced in values.yaml
# Queries container registries to detect newer versions

set -euo pipefail

VALUES_FILE="${1:-cost-onprem/values.yaml}"
VERBOSE="${VERBOSE:-false}"

log() { echo "[INFO] $*"; }
error() { echo "[ERROR] $*" >&2; }
debug() { [[ "$VERBOSE" == "true" ]] && echo "[DEBUG] $*" || true; }

# Extract image references from values.yaml
extract_images() {
    grep -E '^\s+repository:' "$VALUES_FILE" | sed 's/.*repository:\s*//' | tr -d '"' | tr -d "'" | sort -u
}

# Get latest tag for quay.io images
check_quay_image() {
    local image="$1"
    local current_tag="$2"
    local repo_path="${image#quay.io/}"
    
    # Skip if current tag is a digest
    [[ "$current_tag" == sha256:* ]] && return 0
    
    local api_url="https://quay.io/api/v1/repository/${repo_path}/tag/?limit=10&onlyActiveTags=true"
    debug "Checking $api_url"
    
    local response
    response=$(curl -sf "$api_url" 2>/dev/null) || return 1
    
    local latest_tag
    latest_tag=$(echo "$response" | jq -r '.tags[0].name // empty')
    
    if [[ -n "$latest_tag" && "$latest_tag" != "$current_tag" ]]; then
        echo "UPDATE_AVAILABLE|$image|$current_tag|$latest_tag"
    fi
}

# Get latest tag for registry.redhat.io images (requires auth)
check_redhat_image() {
    local image="$1"
    local current_tag="$2"
    
    # Skip digest-based references
    [[ "$current_tag" == sha256:* ]] && return 0
    
    # Red Hat registry requires authentication; skip if no token
    if [[ -z "${REDHAT_REGISTRY_TOKEN:-}" ]]; then
        debug "Skipping $image (no REDHAT_REGISTRY_TOKEN)"
        return 0
    fi
    
    local repo_path="${image#registry.redhat.io/}"
    local api_url="https://catalog.redhat.com/api/containers/v1/repositories/registry/registry.redhat.io/repository/${repo_path}/tags"
    
    local response
    response=$(curl -sf -H "Authorization: Bearer $REDHAT_REGISTRY_TOKEN" "$api_url" 2>/dev/null) || return 1
    
    local latest_tag
    latest_tag=$(echo "$response" | jq -r '.data[0].name // empty')
    
    if [[ -n "$latest_tag" && "$latest_tag" != "$current_tag" ]]; then
        echo "UPDATE_AVAILABLE|$image|$current_tag|$latest_tag"
    fi
}

# Get latest tag for registry.access.redhat.com images
check_redhat_access_image() {
    local image="$1"
    local current_tag="$2"
    
    [[ "$current_tag" == sha256:* ]] && return 0
    
    local repo_path="${image#registry.access.redhat.com/}"
    local api_url="https://catalog.redhat.com/api/containers/v1/repositories/registry/registry.access.redhat.com/repository/${repo_path}/tags?page_size=10"
    
    local response
    response=$(curl -sf "$api_url" 2>/dev/null) || return 1
    
    local latest_tag
    latest_tag=$(echo "$response" | jq -r '.data[0].name // empty')
    
    if [[ -n "$latest_tag" && "$latest_tag" != "$current_tag" ]]; then
        echo "UPDATE_AVAILABLE|$image|$current_tag|$latest_tag"
    fi
}

# Parse values.yaml and check each image
check_all_images() {
    local updates_found=0
    
    # Define images and their current tags from values.yaml
    declare -A images=(
        ["quay.io/insights-onprem/ros-ocp-backend"]="latest"
        ["quay.io/redhat-services-prod/kruize-autotune-tenant/autotune"]="d0b4337"
        ["quay.io/insights-onprem/sources-api-go"]="latest"
        ["quay.io/insights-onprem/insights-ros-ingress"]="latest"
        ["quay.io/insights-onprem/postgresql"]="16"
        ["quay.io/insights-onprem/redis-ephemeral"]="6"
        ["quay.io/minio/minio"]="RELEASE.2025-07-23T15-54-02Z"
        ["quay.io/minio/mc"]="RELEASE.2025-07-21T05-28-08Z"
        ["quay.io/insights-onprem/koku-ui-mfe-on-prem"]="0.0.14"
    )
    
    log "Checking ${#images[@]} components for updates..."
    
    for image in "${!images[@]}"; do
        local tag="${images[$image]}"
        debug "Checking $image:$tag"
        
        local result=""
        if [[ "$image" == quay.io/* ]]; then
            result=$(check_quay_image "$image" "$tag" 2>/dev/null || true)
        elif [[ "$image" == registry.redhat.io/* ]]; then
            result=$(check_redhat_image "$image" "$tag" 2>/dev/null || true)
        elif [[ "$image" == registry.access.redhat.com/* ]]; then
            result=$(check_redhat_access_image "$image" "$tag" 2>/dev/null || true)
        fi
        
        if [[ -n "$result" ]]; then
            echo "$result"
            ((updates_found++)) || true
        fi
    done
    
    return $updates_found
}

# Main
main() {
    if [[ ! -f "$VALUES_FILE" ]]; then
        error "values.yaml not found at $VALUES_FILE"
        exit 1
    fi
    
    log "Checking for component updates..."
    
    local updates
    updates=$(check_all_images) || true
    
    if [[ -n "$updates" ]]; then
        log "Updates available:"
        echo "$updates" | while IFS='|' read -r status image current latest; do
            echo "  $image: $current -> $latest"
        done
        exit 0
    else
        log "All components are up to date"
        exit 0
    fi
}

main "$@"

