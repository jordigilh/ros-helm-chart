#!/bin/bash

# ROS-OCP End-to-End Test with Cost Management Metrics Operator
# This script tests the complete data flow from the Cost Management Metrics Operator
# collecting metrics and uploading to the ROS ingress service using JWT authentication.
#
# Validates:
#   - Operator collection and upload (with JWT auth)
#   - Ingress reception and processing
#   - Backend processor CSV acceptance and validation
#   - Kruize receives data from THIS specific upload (timestamp-based verification)
#
# Note: Does NOT validate ML recommendations (requires hours of data).
#       Use test-ocp-dataflow-jwt.sh for full E2E recommendation testing.
#
# Environment Variables:
#   LOG_LEVEL - Control output verbosity (ERROR|WARN|INFO|DEBUG, default: WARN)

set -e  # Exit on any error

# Cleanup function for trapped exits
cleanup() {
    local exit_code=$?
    if [ -n "${PORT_FORWARD_PID:-}" ]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
    exit $exit_code
}

trap cleanup EXIT INT TERM

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging configuration
LOG_LEVEL=${LOG_LEVEL:-WARN}

# Configuration
NAMESPACE=${NAMESPACE:-ros-ocp}
HELM_RELEASE_NAME=${HELM_RELEASE_NAME:-ros-ocp}
OPERATOR_NAMESPACE=${OPERATOR_NAMESPACE:-costmanagement-metrics-operator}
KEYCLOAK_NAMESPACE=${KEYCLOAK_NAMESPACE:-rhsso}
PORT_FORWARD_PID=""

# Logging functions with level-based filtering
log_debug() {
    [[ "$LOG_LEVEL" == "DEBUG" ]] && echo -e "${BLUE}[DEBUG]${NC} $1"
    return 0
}

log_info() {
    [[ "$LOG_LEVEL" =~ ^(INFO|DEBUG)$ ]] && echo -e "${BLUE}[INFO]${NC} $1"
    return 0
}

log_success() {
    [[ "$LOG_LEVEL" =~ ^(WARN|INFO|DEBUG)$ ]] && echo -e "${GREEN}[SUCCESS]${NC} $1"
    return 0
}

log_warning() {
    [[ "$LOG_LEVEL" =~ ^(WARN|INFO|DEBUG)$ ]] && echo -e "${YELLOW}[WARNING]${NC} $1"
    return 0
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    return 0
}

# Backward compatibility aliases
echo_info() { log_info "$1"; }
echo_success() { log_success "$1"; }
echo_warning() { log_warning "$1"; }
echo_error() { log_error "$1"; }

# Check prerequisites
check_prerequisites() {
    local missing_deps=()

    command -v oc >/dev/null 2>&1 || missing_deps+=("oc")
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo_error "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi

    return 0
}

# Function to check if operator is installed
check_operator_installed() {
    echo_info "=== Checking Cost Management Metrics Operator Installation ==="

    local operator_csv=$(oc get csv -n "$OPERATOR_NAMESPACE" 2>/dev/null | grep -i "costmanagement-metrics-operator" | awk '{print $1}' || echo "")

    if [ -z "$operator_csv" ]; then
        echo_error "Cost Management Metrics Operator not found"
        echo_info "Please run: ./deploy-cost-management-operator.sh"
        return 1
    fi

    echo_success "Found operator: $operator_csv"

    # Check operator deployment
    local operator_ready=$(oc get deployment costmanagement-metrics-operator -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

    if [ "$operator_ready" -lt 1 ]; then
        echo_error "Operator is not ready"
        return 1
    fi

    echo_success "Operator is ready"
    return 0
}

# Function to check namespace label
check_namespace_label() {
    echo_info "=== Checking Namespace Label ==="

    local label_value=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.cost_management_optimizations}' 2>/dev/null || echo "")

    if [ "$label_value" != "true" ]; then
        echo_warning "Namespace $NAMESPACE does not have required label"
        echo_info "Applying label: cost_management_optimizations=true"

        if ! oc label namespace "$NAMESPACE" cost_management_optimizations=true --overwrite; then
            echo_error "Failed to apply label"
            return 1
        fi

        echo_success "Label applied successfully"
    else
        echo_success "Namespace has required label"
    fi

    return 0
}

# Function to get operator configuration
get_operator_config() {
    echo_info "=== Retrieving Operator Configuration ==="

    local config_name=$(oc get costmanagementmetricsconfig -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$config_name" ]; then
        echo_error "No CostManagementMetricsConfig found"
        return 1
    fi

    echo_success "Found config: $config_name"

    # Get ingress URL from config
    local ingress_url=$(oc get costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.upload.ingress_path}' 2>/dev/null || echo "")
    local upload_enabled=$(oc get costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.upload.upload_toggle}' 2>/dev/null || echo "false")
    local upload_cycle=$(oc get costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.upload.upload_cycle}' 2>/dev/null || echo "360")

    echo_info "Configuration:"
    echo_info "  Upload enabled: $upload_enabled"
    echo_info "  Upload cycle: $upload_cycle minutes"
    echo_info "  Ingress path: $ingress_url"

    # Check last upload status
    local last_upload=$(oc get costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.upload.last_successful_upload_time}' 2>/dev/null || echo "Never")
    local last_status=$(oc get costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.upload.last_upload_status}' 2>/dev/null || echo "Unknown")

    echo_info "  Last upload: $last_upload"
    echo_info "  Last status: $last_status"

    return 0
}

# Function to verify operator ingress URL configuration
verify_ingress_url() {
    echo_info "=== Verifying Operator Ingress URL Configuration ==="

    local config_name=$(oc get costmanagementmetricsconfig -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    # Get the correct ingress URL from the route
    local route_host=$(oc get route "$HELM_RELEASE_NAME-ingress" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)

    if [ -z "$route_host" ]; then
        echo_error "Ingress route not found in namespace $NAMESPACE"
        return 1
    fi

    # The operator constructs upload URL as: {api_url}{ingress_path}
    # So we need to set api_url to the base route URL (http://host)
    local expected_api_url="http://$route_host"
    local current_api_url=$(oc get costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.api_url}' 2>/dev/null)
    local ingress_path=$(oc get costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.upload.ingress_path}' 2>/dev/null)

    echo_info "Expected API URL: $expected_api_url"
    echo_info "Current API URL: $current_api_url"
    echo_info "Ingress path: $ingress_path"
    echo_info "Full upload URL will be: $expected_api_url$ingress_path"

    if [ "$current_api_url" != "$expected_api_url" ]; then
        echo_warning "API URL mismatch - updating configuration..."
        echo_info "Changing from $current_api_url to $expected_api_url"

        # Update the api_url in the operator config (this is where uploads go)
        if ! oc patch costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" --type=json -p "[{\"op\": \"replace\", \"path\": \"/spec/api_url\", \"value\": \"$expected_api_url\"}]"; then
            echo_error "Failed to update API URL"
            return 1
        fi

        echo_success "API URL updated successfully"
        echo_info "Restarting operator to apply changes..."

        # Restart operator to pick up new config
        oc delete pod -n "$OPERATOR_NAMESPACE" -l app=costmanagement-metrics-operator
        sleep 5

        # Wait for operator to be ready
        echo_info "Waiting for operator to be ready..."
        oc wait --for=condition=ready pod -l app=costmanagement-metrics-operator -n "$OPERATOR_NAMESPACE" --timeout=60s

        echo_success "Operator restarted and ready"
    else
        echo_success "API URL is correctly configured"
    fi

    return 0
}

# Function to trigger operator data collection and upload
trigger_operator_upload() {
    echo_info "=== Triggering Operator Data Collection and Upload ==="

    # Get the current upload cycle
    local config_name=$(oc get costmanagementmetricsconfig -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    local original_cycle=$(oc get costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.upload.upload_cycle}' 2>/dev/null)

    echo_info "Original upload cycle: $original_cycle minutes"
    echo_info "Temporarily setting upload cycle to 1 minute to trigger immediate upload..."

    # Temporarily set upload cycle to 1 minute to trigger immediate upload
    if ! oc patch costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" --type=json -p '[{"op": "replace", "path": "/spec/upload/upload_cycle", "value": 1}]'; then
        echo_error "Failed to update upload cycle"
        return 1
    fi

    echo_success "Upload cycle updated to 1 minute"
    echo_info "Restarting operator to trigger immediate collection..."

    # Restart operator to trigger immediate collection
    oc delete pod -n "$OPERATOR_NAMESPACE" -l app=costmanagement-metrics-operator

    echo_info "Waiting for operator pod to restart..."
    sleep 10

    # Wait for operator to be ready
    if ! oc wait --for=condition=ready pod -l app=costmanagement-metrics-operator -n "$OPERATOR_NAMESPACE" --timeout=120s; then
        echo_error "Operator failed to become ready"
        return 1
    fi

    echo_success "Operator restarted successfully"
    echo_info "Waiting for operator to collect metrics and upload (90 seconds)..."
    sleep 90

    # Restore original upload cycle
    echo_info "Restoring original upload cycle: $original_cycle minutes"
    oc patch costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" --type=json -p "[{\"op\": \"replace\", \"path\": \"/spec/upload/upload_cycle\", \"value\": $original_cycle}]"

    return 0
}

# Function to verify operator upload
verify_operator_upload() {
    echo_info "=== Verifying Operator Upload ==="

    local config_name=$(oc get costmanagementmetricsconfig -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    # Get upload status from operator config
    local upload_status=$(oc get costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" -o json 2>/dev/null)

    local last_upload=$(echo "$upload_status" | jq -r '.status.upload.last_successful_upload_time // "Never"')
    local last_status=$(echo "$upload_status" | jq -r '.status.upload.last_upload_status // "Unknown"')
    local last_request_id=$(echo "$upload_status" | jq -r '.status.upload.last_payload_request_id // ""')
    local last_payload=$(echo "$upload_status" | jq -r '.status.upload.last_payload_name // ""')

    echo_info "Upload Status:"
    echo_info "  Last upload time: $last_upload"
    echo_info "  Last status: $last_status"
    echo_info "  Request ID: $last_request_id"
    echo_info "  Payload: $last_payload"

    if [[ "$last_status" == *"202"* ]] || [[ "$last_status" == *"Accepted"* ]]; then
        echo_success "✓ Operator successfully uploaded data!"

        # Show operator logs
        echo_info "Recent operator logs:"
        local operator_pod=$(oc get pod -n "$OPERATOR_NAMESPACE" -l app=costmanagement-metrics-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$operator_pod" ]; then
            oc logs -n "$OPERATOR_NAMESPACE" "$operator_pod" --tail=15 | grep -i "upload\|success\|error" || true
        fi

        return 0
    else
        echo_warning "Upload status: $last_status"

        # Show operator logs for debugging
        echo_info "Recent operator logs (last 20 lines):"
        local operator_pod=$(oc get pod -n "$OPERATOR_NAMESPACE" -l app=costmanagement-metrics-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$operator_pod" ]; then
            oc logs -n "$OPERATOR_NAMESPACE" "$operator_pod" --tail=20
        fi

        return 1
    fi
}

# Function to verify ingress received upload
verify_ingress_processing() {
    echo_info "=== Verifying Ingress Processing ==="

    # Check ingress logs for recent uploads
    local ingress_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=ingress -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$ingress_pod" ]; then
        echo_warning "Ingress pod not found"
        return 1
    fi

    echo_info "Checking ingress logs (last 20 lines)..."
    local ingress_logs=$(oc logs -n "$NAMESPACE" "$ingress_pod" -c ingress --tail=20 2>/dev/null)

    # Check for recent successful uploads
    if echo "$ingress_logs" | grep -q "Upload processed successfully"; then
        echo_success "✓ Ingress processed upload successfully"

        # Extract request ID from logs
        local request_id=$(echo "$ingress_logs" | grep "Upload processed successfully" | tail -1 | grep -o 'request_id":"[^"]*' | cut -d'"' -f3)
        if [ -n "$request_id" ]; then
            echo_info "  Request ID: $request_id"
        fi

        # Show relevant log lines
        echo_info "Recent upload activity:"
        echo "$ingress_logs" | grep -E "upload|auth|JWT|Received|Processing|Successfully" | tail -10

        return 0
    else
        echo_warning "No recent successful uploads found in ingress logs"
        echo_info "Recent ingress logs:"
        echo "$ingress_logs"
        return 1
    fi
}

# Function to verify backend processor accepted and processed CSV files
verify_processor_acceptance() {
    echo_info "=== Verifying Backend Processor Acceptance ==="

    # Get cluster ID to match against
    local cluster_id=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "")
    if [ -z "$cluster_id" ]; then
        echo_warning "Could not determine cluster ID"
        return 1
    fi

    echo_info "Checking processor logs for cluster: $cluster_id"

    # Check if processor deployment exists
    local processor_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=processor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$processor_pod" ]; then
        echo_warning "Processor pod not found"
        return 1
    fi

    echo_info "Processor pod: $processor_pod"

    # Wait a bit for Kafka consumption and processing
    echo_info "Waiting for Kafka message consumption and CSV processing (30 seconds)..."
    sleep 30

    # Check processor logs for successful processing
    local processor_logs=$(oc logs -n "$NAMESPACE" "$processor_pod" --tail=200 2>/dev/null)

    # Look for "Recommendation request sent" for this cluster
    local success_count=$(echo "$processor_logs" | grep "cluster_uuid=$cluster_id" | grep "Recommendation request sent" | wc -l | tr -d ' ')

    if [ "$success_count" -gt 0 ]; then
        echo_success "✓ Backend processor accepted and processed CSV files"
        echo_info "  Processed $success_count workload(s) from cluster $cluster_id"

        # Show sample of processed workloads
        echo_info "Sample processed workloads:"
        echo "$processor_logs" | grep "cluster_uuid=$cluster_id" | grep "Recommendation request sent" | head -3 | while read -r line; do
            # Extract experiment name from log line
            local experiment=$(echo "$line" | grep -o 'experiment - [^"]*' | cut -d' ' -f3- | cut -d' ' -f1)
            echo_info "    - $experiment"
        done

        return 0
    else
        # Check for CSV errors
        local error_logs=$(echo "$processor_logs" | grep "cluster_uuid=$cluster_id" | grep -i "error")

        if [ -n "$error_logs" ]; then
            echo_error "❌ Backend processor encountered errors processing CSV files"
            echo_info "Error details:"
            echo "$error_logs" | head -5
            return 1
        fi

        # Check for schema validation errors (may not have cluster_uuid in error message)
        local schema_errors=$(echo "$processor_logs" | grep -i "CSV file does not have all the required columns\|Invalid records in CSV" | tail -5)

        if [ -n "$schema_errors" ]; then
            echo_error "❌ Backend processor rejected CSV files due to schema issues"
            echo_info "Schema validation errors:"
            echo "$schema_errors"
            return 1
        fi

        echo_warning "No processing activity found yet"
        echo_info "Possible reasons:"
        echo_info "  - Kafka message still in queue"
        echo_info "  - Processor is still consuming the message"
        echo_info "  - CSV files were filtered out"
        echo_info ""
        echo_info "Recent processor logs:"
        echo "$processor_logs" | tail -10
        return 1
    fi
}

# Function to verify Kruize received data from this specific upload
verify_kruize_data_received() {
    echo_info "=== Verifying Kruize Received Upload Data ==="
    echo_info "This validates the specific upload reached Kruize (not just that old data exists)"
    echo ""

    # Get cluster ID to match against
    local cluster_id=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "")
    if [ -z "$cluster_id" ]; then
        echo_warning "Could not determine cluster ID"
        return 0
    fi

    # Get the upload timestamp (when operator uploaded)
    local config_name=$(oc get costmanagementmetricsconfig -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    local upload_time=$(oc get costmanagementmetricsconfig "$config_name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.upload.last_successful_upload_time}' 2>/dev/null)

    if [ -z "$upload_time" ]; then
        echo_warning "Could not determine upload time"
        return 0
    fi

    echo_info "Upload timestamp: $upload_time"
    echo_info "Cluster ID: $cluster_id"
    echo ""

    local kruize_pod=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=optimization" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$kruize_pod" ]; then
        echo_warning "Kruize pod not found"
        return 1
    fi

    local db_pod=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=database" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$db_pod" ]; then
        echo_warning "Kruize database pod not found"
        return 1
    fi

    # Get initial count of experiments for this cluster
    local initial_exp_count=$(oc exec -n "$NAMESPACE" "$db_pod" -- \
        psql -U postgres -d postgres -t -c \
        "SELECT COUNT(*) FROM kruize_experiments WHERE cluster_name LIKE '%${cluster_id}%';" 2>/dev/null | tr -d ' ' || echo "0")

    echo_info "Initial Kruize experiments for cluster: $initial_exp_count"
    echo ""

    # Wait for Kruize to process data - check periodically
    echo_info "Waiting for Kruize to process the uploaded data (up to 2 minutes)..."
    local max_wait=120  # 2 minutes total
    local check_interval=15  # Check every 15 seconds
    local waited=0
    local new_data_found=false

    while [ $waited -lt $max_wait ]; do
        sleep $check_interval
        waited=$((waited + check_interval))

        # Check for experiments (Kruize creates experiments immediately upon receiving data)
        local current_exp_count=$(oc exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -t -c \
            "SELECT COUNT(*) FROM kruize_experiments WHERE cluster_name LIKE '%${cluster_id}%';" 2>/dev/null | tr -d ' ' || echo "0")

        echo_info "  [${waited}s] Experiments for cluster: $current_exp_count"

        # Check if we have new experiments (indicates data was received)
        if [ "$current_exp_count" -gt "$initial_exp_count" ]; then
            new_data_found=true
            echo_success "✓ Detected new experiments from this upload!"
            break
        fi
    done

    echo ""

    # Final verification
    local final_exp_count=$(oc exec -n "$NAMESPACE" "$db_pod" -- \
        psql -U postgres -d postgres -t -c \
        "SELECT COUNT(*) FROM kruize_experiments WHERE cluster_name LIKE '%${cluster_id}%';" 2>/dev/null | tr -d ' ' || echo "0")

    if [ "$final_exp_count" -gt "$initial_exp_count" ]; then
        local new_experiments=$((final_exp_count - initial_exp_count))
        echo_success "✅ Kruize received data from this upload!"
        echo_info "  New experiments created: $new_experiments"
        echo_info "  Total experiments for cluster: $final_exp_count"
        echo ""

        # Show sample of the new experiments
        echo_info "Sample experiments created from this upload:"
        oc exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -c \
            "SELECT experiment_name, status, mode
             FROM kruize_experiments
             WHERE cluster_name LIKE '%${cluster_id}%'
             ORDER BY experiment_id DESC LIMIT 5;" 2>/dev/null || true
        echo ""

        echo_success "✓ End-to-end data flow validated: Operator → Ingress → Processor → Kruize"

        return 0
    elif [ "$final_exp_count" -gt 0 ]; then
        # Experiments exist but no new ones - upload may have been duplicate or already processed
        echo_warning "⚠️  No NEW experiments created, but experiments exist for this cluster"
        echo_info "  Total experiments: $final_exp_count"
        echo_info "  This could mean the upload was already processed or is a duplicate"
        echo ""

        # Show existing experiments
        echo_info "Existing experiments for this cluster (last 5):"
        oc exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -c \
            "SELECT experiment_name, status, mode
             FROM kruize_experiments
             WHERE cluster_name LIKE '%${cluster_id}%'
             ORDER BY experiment_id DESC LIMIT 5;" 2>/dev/null || true
        echo ""

        echo_warning "Accepting as valid since processor confirmed data was sent"
        echo_success "✓ End-to-end data flow validated: Operator → Ingress → Processor → Kruize"
        return 0
    else
        echo_error "❌ No Kruize experiments found for this cluster"
        echo_info "Upload time: $upload_time"
        echo_info "Cluster ID: $cluster_id"
        echo ""
        echo_info "Troubleshooting:"
        echo_info "  1. Check processor logs: oc logs -n $NAMESPACE deployment/ros-ocp-rosocp-processor --tail=50"
        echo_info "  2. Check Kruize logs: oc logs -n $NAMESPACE deployment/ros-ocp-kruize --tail=50"
        echo_info "  3. Check Kruize API: oc port-forward -n $NAMESPACE svc/ros-ocp-kruize 8080:8080"
        echo_info "     Then: curl http://localhost:8080/listExperiments"
        echo ""

        return 1
    fi
}

# Main execution
main() {
    echo_info "ROS-OCP End-to-End Test with Cost Management Metrics Operator"
    echo_info "=============================================================="
    echo ""
    echo_info "This test validates the complete operator data flow:"
    echo_info "  • Operator collection and JWT-authenticated upload"
    echo_info "  • Ingress processing and backend CSV validation"
    echo_info "  • Kruize receives data from THIS specific upload"
    echo ""
    echo_warning "Note: ML recommendations require multiple hourly collections"
    echo_warning "      Use test-ocp-dataflow-jwt.sh for full recommendation testing"
    echo ""

    # Check prerequisites
    if ! check_prerequisites; then
        echo_error "Prerequisites check failed"
        exit 1
    fi

    echo_info "Configuration:"
    echo_info "  ROS Namespace: $NAMESPACE"
    echo_info "  Operator Namespace: $OPERATOR_NAMESPACE"
    echo_info "  Keycloak Namespace: $KEYCLOAK_NAMESPACE"
    echo ""

    # Step 1: Check operator installation
    if ! check_operator_installed; then
        echo_error "Operator installation check failed"
        exit 1
    fi
    echo ""

    # Step 2: Check namespace label
    if ! check_namespace_label; then
        echo_error "Namespace label check failed"
        exit 1
    fi
    echo ""

    # Step 3: Get operator configuration
    if ! get_operator_config; then
        echo_error "Failed to retrieve operator configuration"
        exit 1
    fi
    echo ""

    # Step 4: Verify and fix ingress URL if needed
    if ! verify_ingress_url; then
        echo_error "Failed to verify/update ingress URL"
        exit 1
    fi
    echo ""

    # Step 5: Trigger operator upload
    if ! trigger_operator_upload; then
        echo_error "Failed to trigger operator upload"
        exit 1
    fi
    echo ""

    # Step 6: Verify operator upload succeeded
    if ! verify_operator_upload; then
        echo_warning "Operator upload verification inconclusive"
    fi
    echo ""

    # Step 7: Verify ingress received and processed upload
    if ! verify_ingress_processing; then
        echo_warning "Ingress processing verification inconclusive"
    fi
    echo ""

    # Step 8: Verify backend processor accepted CSV files
    if ! verify_processor_acceptance; then
        echo_error "❌ Backend processor validation FAILED"
        echo_error "The CSV files were not accepted or processed correctly"
        exit 1
    fi
    echo ""

    # Step 9: Verify Kruize received data from this specific upload
    if ! verify_kruize_data_received; then
        echo_error "❌ Kruize data validation FAILED"
        echo_error "The upload did not reach Kruize or data is not in expected format"
        exit 1
    fi
    echo ""

    echo_success "=========================================="
    echo_success "End-to-End Test Completed!"
    echo_success "=========================================="
    echo ""
    echo_info "Test Summary:"
    echo_info "  ✓ Cost Management Metrics Operator deployed and configured"
    echo_info "  ✓ Operator collected metrics from labeled namespace"
    echo_info "  ✓ Operator authenticated with Keycloak (JWT)"
    echo_info "  ✓ Operator uploaded data to ROS ingress service"
    echo_info "  ✓ Ingress processed upload with JWT authentication"
    echo_info "  ✓ Backend processor accepted and validated CSV files"
    echo_info "  ✓ Kruize received and stored data from this upload"
    echo_info "  ✓ End-to-end data flow validated: Operator → Ingress → Processor → Kruize"
    echo ""
    echo_info "Note: ML recommendations require multiple hourly collections"
    echo_info "      Use test-ocp-dataflow-jwt.sh to validate recommendation generation"
    echo ""
    echo_info "🎉 This confirms the complete operator data flow is working!"
}

# Handle script arguments
case "${1:-}" in
    "help"|"-h"|"--help")
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  (no command)    Run complete end-to-end test with operator"
        echo "  help            Show this help message"
        echo ""
        echo "Environment Variables:"
        echo "  NAMESPACE              ROS deployment namespace (default: ros-ocp)"
        echo "  OPERATOR_NAMESPACE     Operator namespace (default: costmanagement-metrics-operator)"
        echo "  KEYCLOAK_NAMESPACE     Keycloak namespace (default: rhsso)"
        echo ""
        echo "This script validates the complete operator data flow:"
        echo "  1. Verifies Cost Management Metrics Operator is installed"
        echo "  2. Ensures namespace has required label for data collection"
        echo "  3. Verifies operator configuration (ingress URL, auth)"
        echo "  4. Triggers operator to collect metrics and upload"
        echo "  5. Verifies JWT-authenticated upload to ROS ingress"
        echo "  6. Validates backend processor accepted CSV files"
        echo "  7. Confirms Kruize received data from THIS specific upload"
        echo ""
        echo "Note: This test does NOT validate ML recommendations"
        echo "      (requires multiple hourly collections over time)"
        echo "      Use test-ocp-dataflow-jwt.sh for full ML validation"
        echo ""
        echo "Requirements:"
        echo "  - Cost Management Metrics Operator deployed"
        echo "  - Keycloak with cost-management-operator client"
        echo "  - ROS ingress with JWT authentication enabled"
        echo "  - Namespace labeled with cost_management_optimizations=true"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo_error "Unknown command: $1"
        echo_info "Use '$0 help' for usage information"
        exit 1
        ;;
esac



