#!/usr/bin/env bash
# Final deployment script for Koku integration
# Applies all configuration fixes and verifies infrastructure startup
#
# Prerequisites:
#   - oc login completed
#   - In ros-helm-chart directory
#   - All code changes committed

set -e

NAMESPACE="cost-mgmt"
CHART_PATH="./cost-management-onprem"
VALUES_FILE="cost-management-onprem/values-koku.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

echo ""
log_info "=== Koku Deployment Finalization ==="
echo ""

# Check cluster connectivity
log_info "Checking cluster connection..."
if ! oc whoami &>/dev/null; then
    log_error "Not connected to OpenShift cluster"
    echo "Please run: oc login <cluster-url>"
    exit 1
fi
log_success "Connected as: $(oc whoami)"

# Check namespace
if ! oc get namespace "${NAMESPACE}" &>/dev/null; then
    log_error "Namespace '${NAMESPACE}' does not exist"
    exit 1
fi
log_success "Namespace '${NAMESPACE}' exists"

# Verify ODF credentials
log_info "Verifying ODF credentials..."
if ! oc get secret noobaa-admin -n "${NAMESPACE}" &>/dev/null; then
    log_warning "noobaa-admin secret not found, creating..."
    if oc get secret noobaa-admin -n openshift-storage &>/dev/null; then
        oc get secret noobaa-admin -n openshift-storage -o json | \
            jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.ownerReferences, .metadata.creationTimestamp, .metadata.managedFields)' | \
            jq '.metadata.namespace = "cost-mgmt"' | \
            oc apply -f - >/dev/null
        log_success "ODF credentials copied to ${NAMESPACE}"
    else
        log_error "ODF not available (no noobaa-admin in openshift-storage)"
        exit 1
    fi
else
    log_success "ODF credentials available"
fi

echo ""
log_info "=== Applying Helm Chart Upgrade ==="
echo ""

# Upgrade chart with all fixes
log_info "Upgrading Helm release with latest configuration..."
helm upgrade cost-mgmt "${CHART_PATH}" \
    --namespace "${NAMESPACE}" \
    -f "${VALUES_FILE}" \
    --timeout 5m \
    --wait=false

log_success "Helm upgrade completed"

echo ""
log_info "=== Restarting Infrastructure Pods ==="
echo ""

# Function to safely delete pods
delete_pod_safe() {
    local pod_name=$1
    if oc get pod "${pod_name}" -n "${NAMESPACE}" &>/dev/null; then
        log_info "Deleting ${pod_name}..."
        oc delete pod "${pod_name}" -n "${NAMESPACE}" --wait=false
        return 0
    fi
    return 1
}

# Restart Trino Coordinator (has config fix)
log_info "Restarting Trino Coordinator..."
if oc delete pod -n "${NAMESPACE}" -l app.kubernetes.io/component=trino-coordinator --wait=false; then
    log_success "Trino Coordinator restart initiated"
else
    log_warning "Trino Coordinator pods not found"
fi

# Restart databases if needed
log_info "Checking database pods..."
for pod in cost-mgmt-cost-management-onprem-koku-db-0 cost-mgmt-cost-management-onprem-hive-metastore-db-0; do
    if oc get pod "${pod}" -n "${NAMESPACE}" &>/dev/null; then
        pod_status=$(oc get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
        if [[ "${pod_status}" != "Running" ]]; then
            log_info "Restarting ${pod} (currently ${pod_status})..."
            delete_pod_safe "${pod}"
        else
            log_success "${pod} is Running"
        fi
    fi
done

echo ""
log_info "=== Waiting for Infrastructure Pods ==="
echo ""
sleep 10

# Function to check pod status
check_pod_status() {
    local label=$1
    local component=$2
    local expected=$3

    log_info "Checking ${component}..."
    local count=$(oc get pods -n "${NAMESPACE}" -l "${label}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [[ "${count}" -ge "${expected}" ]]; then
        log_success "${component}: ${count}/${expected} Running"
        return 0
    else
        log_warning "${component}: ${count}/${expected} Running"
        return 1
    fi
}

# Check infrastructure components
echo ""
log_info "Infrastructure Status:"
echo ""

check_pod_status "app.kubernetes.io/name=cost-management-onprem-koku-db" "Koku Database" 1
check_pod_status "app.kubernetes.io/name=cost-management-onprem-hive-metastore-db" "Metastore Database" 1
check_pod_status "app.kubernetes.io/component=trino-coordinator" "Trino Coordinator" 1
check_pod_status "app.kubernetes.io/component=trino-worker" "Trino Worker" 1

echo ""
log_info "=== Detailed Pod Status ==="
echo ""

# Show infrastructure pods
oc get pods -n "${NAMESPACE}" | grep -E "NAME|koku-db|metastore|trino" || true

echo ""
log_info "=== Overall Pod Summary ==="
echo ""

oc get pods -n "${NAMESPACE}" --no-headers | awk '{print $3}' | sort | uniq -c | sort -rn

echo ""
log_info "=== Next Steps ==="
echo ""

# Count Running pods
running_infra=$(oc get pods -n "${NAMESPACE}" -l 'app.kubernetes.io/component in (koku-db,trino-coordinator,trino-worker,hive-metastore-db)' --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${running_infra}" -ge 4 ]]; then
    log_success "Infrastructure is healthy! (${running_infra}/4 components running)"
    echo ""
    echo "✅ You can now:"
    echo "   1. Monitor Koku API pods coming online:"
    echo "      watch 'oc get pods -n cost-mgmt | grep koku-api'"
    echo ""
    echo "   2. Monitor Celery workers:"
    echo "      watch 'oc get pods -n cost-mgmt | grep celery'"
    echo ""
    echo "   3. Check Koku API logs:"
    echo "      oc logs -n cost-mgmt -l app.kubernetes.io/component=cost-management-api --tail=50"
    echo ""
    echo "   4. Test Koku API health:"
    echo "      oc port-forward -n cost-mgmt svc/cost-mgmt-cost-management-onprem-koku-api 8000:8000"
    echo "      curl http://localhost:8000/api/cost-management/v1/status/"
    echo ""
else
    log_warning "Infrastructure not fully ready (${running_infra}/4 components)"
    echo ""
    echo "⚠️  Troubleshooting:"
    echo "   1. Check pod events:"
    echo "      oc describe pod -n cost-mgmt <pod-name>"
    echo ""
    echo "   2. Check pod logs:"
    echo "      oc logs -n cost-mgmt <pod-name>"
    echo ""
    echo "   3. Wait a bit longer and check again:"
    echo "      watch 'oc get pods -n cost-mgmt'"
    echo ""
fi

log_info "Deployment finalization complete!"

