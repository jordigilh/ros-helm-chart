#!/usr/bin/env bash
# Check for component updates in values.yaml
# Used by .github/workflows/check-components.yml
#
# Usage: MODE=check-updates ./check-components.sh
#        MODE=list-versions ./check-components.sh
#        MODE=deployment-info ./check-components.sh
#
# Outputs (via GITHUB_OUTPUT if set):
#   mode, has_updates, updates, versions, digests_json
#   For deployment-info mode: helm_chart_version, app_version, git_sha, git_branch, deployment_timestamp

set -euo pipefail

VALUES_FILE="${VALUES_FILE:-cost-onprem/values.yaml}"
CHART_FILE="${CHART_FILE:-cost-onprem/Chart.yaml}"
CACHE_DIR="${CACHE_DIR:-.digest-cache}"
MODE="${MODE:-check-updates}"

mkdir -p "$CACHE_DIR"

# Output helpers
output_var() {
    local name="$1"
    local value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "$name=$value" >> "$GITHUB_OUTPUT"
    else
        echo "$name=$value"
    fi
}

output_multiline() {
    local name="$1"
    local value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "${name}<<EOF"
            echo -e "$value"
            echo "EOF"
        } >> "$GITHUB_OUTPUT"
    else
        echo "$name:"
        echo -e "$value"
    fi
}

# Get deployment metadata for CI traceability
get_deployment_info() {
    local helm_chart_version=""
    local deployed_chart_version=""
    local helm_release_name="${HELM_RELEASE_NAME:-cost-onprem}"
    local namespace="${NAMESPACE:-cost-onprem}"
    local git_sha=""
    local git_branch=""
    local git_tag=""
    local deployment_timestamp=""
    
    # Extract chart version from Chart.yaml (source version)
    if [[ -f "$CHART_FILE" ]]; then
        helm_chart_version=$(grep -E "^version:" "$CHART_FILE" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
    fi
    
    # Try to get the actually deployed chart version from the cluster
    if command -v helm &> /dev/null; then
        deployed_chart_version=$(helm list -n "$namespace" -o json 2>/dev/null | \
            jq -r --arg name "$helm_release_name" '.[] | select(.name==$name) | .chart' 2>/dev/null | \
            sed 's/.*-//' || echo "")
    fi
    
    # Get git information
    if command -v git &> /dev/null && git rev-parse --git-dir &> /dev/null; then
        git_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        git_tag=$(git describe --tags --exact-match 2>/dev/null || echo "")
        
        # Use GitHub Actions environment variables if available
        if [[ -n "${GITHUB_SHA:-}" ]]; then
            git_sha="$GITHUB_SHA"
        fi
        if [[ -n "${GITHUB_REF_NAME:-}" ]]; then
            git_branch="$GITHUB_REF_NAME"
        fi
    fi
    
    # Timestamp
    deployment_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Output all metadata
    output_var "helm_chart_version" "${helm_chart_version:-unknown}"
    output_var "deployed_chart_version" "${deployed_chart_version:-}"
    output_var "git_sha" "${git_sha:-unknown}"
    output_var "git_sha_short" "${git_sha:0:7}"
    output_var "git_branch" "${git_branch:-unknown}"
    output_var "git_tag" "${git_tag:-}"
    output_var "deployment_timestamp" "$deployment_timestamp"
    
    # Also output a summary for logging
    echo "=== Deployment Metadata ==="
    echo "Chart Version (source):   ${helm_chart_version:-unknown}"
    [[ -n "$deployed_chart_version" ]] && echo "Chart Version (deployed): $deployed_chart_version"
    echo "Git SHA:                  ${git_sha:-unknown}"
    echo "Git Branch:               ${git_branch:-unknown}"
    [[ -n "$git_tag" ]] && echo "Git Tag:                  $git_tag"
    echo "Timestamp:                $deployment_timestamp"
    echo "==========================="
    
    # Get component details
    local components_json
    components_json=$(extract_all_components)
    
    # Output as JSON for easy parsing
    local metadata_json
    metadata_json=$(cat <<EOF
{
  "helm_chart_version": "${helm_chart_version:-unknown}",
  "deployed_chart_version": "${deployed_chart_version:-}",
  "git_sha": "${git_sha:-unknown}",
  "git_sha_short": "${git_sha:0:7}",
  "git_branch": "${git_branch:-unknown}",
  "git_tag": "${git_tag:-}",
  "deployment_timestamp": "$deployment_timestamp",
  "components": $components_json
}
EOF
)
    output_var "metadata_json" "$(echo "$metadata_json" | tr -d '\n' | tr -s ' ')"
    
    # Write to version_info.json file
    local version_info_file="${VERSION_INFO_FILE:-version_info.json}"
    echo "$metadata_json" > "$version_info_file"
    echo "Version info written to: $version_info_file"
    output_var "version_info_file" "$version_info_file"
}

# Extract latest-tagged images from values.yaml
# Returns lines of: repo|tag
extract_images() {
    local repo=""
    while IFS= read -r line; do
        if [[ "$line" =~ repository:\ *(.+) ]]; then
            repo="${BASH_REMATCH[1]//\"/}"
            repo="${repo//\'/}"
        elif [[ "$line" =~ tag:\ *(.+) ]]; then
            local tag="${BASH_REMATCH[1]//\"/}"
            tag="${tag//\'/}"
            if [[ -n "$repo" && "$tag" == "latest" ]]; then
                echo "$repo"
            fi
            repo=""
        fi
    done < "$VALUES_FILE"
}

# Extract all component images with their tags from values.yaml
# Returns JSON object of components
extract_all_components() {
    local components_json="{"
    local first=true
    local current_section=""
    local repo=""
    local tag=""
    
    while IFS= read -r line; do
        # Track section headers (e.g., koku:, ros:, ingress:)
        if [[ "$line" =~ ^[a-zA-Z][a-zA-Z0-9_-]*:$ ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
            current_section="${line%:}"
        fi
        
        # Match image repository
        if [[ "$line" =~ repository:\ *(.+) ]]; then
            repo="${BASH_REMATCH[1]//\"/}"
            repo="${repo//\'/}"
            repo="${repo#"${repo%%[![:space:]]*}"}"  # trim leading whitespace
        fi
        
        # Match image tag
        if [[ "$line" =~ tag:\ *(.+) ]]; then
            tag="${BASH_REMATCH[1]//\"/}"
            tag="${tag//\'/}"
            tag="${tag#"${tag%%[![:space:]]*}"}"  # trim leading whitespace
            
            if [[ -n "$repo" ]]; then
                # Extract component name from repo path
                local component_name
                component_name=$(basename "$repo")
                
                if [[ "$first" == "true" ]]; then
                    first=false
                else
                    components_json+=","
                fi
                components_json+="\"${component_name}\":{\"repository\":\"${repo}\",\"tag\":\"${tag}\"}"
            fi
            repo=""
            tag=""
        fi
    done < "$VALUES_FILE"
    
    components_json+="}"
    echo "$components_json"
}

output=""
has_updates="false"
digests_json="{"
first_digest=true

while IFS= read -r image; do
    [[ -z "$image" ]] && continue
    
    # Only check quay.io images
    if [[ "$image" == quay.io/* ]]; then
        repo_path="${image#quay.io/}"
        cache_file="$CACHE_DIR/${repo_path//\//_}.digest"
        api_url="https://quay.io/api/v1/repository/${repo_path}/tag/?limit=1&specificTag=latest"
        
        response=$(curl -sf --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null) || continue
        current_digest=$(echo "$response" | jq -r '.tags[0].manifest_digest // empty')
        last_modified=$(echo "$response" | jq -r '.tags[0].last_modified // empty')
        
        [[ -z "$current_digest" ]] && continue
        
        if [[ "$MODE" == "list-versions" ]]; then
            output="${output}${image}:latest\n  digest: ${current_digest}\n  updated: ${last_modified}\n\n"
        else
            if [[ -f "$cache_file" ]]; then
                previous_digest=$(cat "$cache_file")
                if [[ "$current_digest" != "$previous_digest" ]]; then
                    output="${output}${image}:latest (digest changed)\n"
                    has_updates="true"
                    
                    # Build digests JSON incrementally
                    if [[ "$first_digest" == "true" ]]; then
                        first_digest=false
                    else
                        digests_json+=","
                    fi
                    digests_json+="\"$image\":\"$current_digest\""
                fi
            fi
            echo "$current_digest" > "$cache_file"
        fi
    fi
done < <(extract_images)

digests_json+="}"

# Output results
output_var "mode" "$MODE"

if [[ "$MODE" == "deployment-info" ]]; then
    get_deployment_info
elif [[ "$MODE" == "list-versions" ]]; then
    # Also include deployment info when listing versions
    get_deployment_info
    echo ""
    output_multiline "versions" "$output"
elif [[ "$has_updates" == "true" ]]; then
    output_var "has_updates" "true"
    output_multiline "updates" "$output"
    output_var "digests_json" "$digests_json"
else
    output_var "has_updates" "false"
    echo "All components are up to date"
fi
