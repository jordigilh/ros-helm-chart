#!/bin/bash
#
# Cost Management Verification Script
# ====================================
# Performs comprehensive health checks on a deployed Cost Management instance.
#
# This script implements all verification checks from Phase 3 of the
# Cost Management Installation Guide.
#
# Usage:
#   ./verify-cost-management.sh --namespace <namespace> [options]
#
# Options:
#   --namespace <name>      Kubernetes namespace (required)
#   --skip-e2e             Skip E2E tests
#   --verbose              Show detailed output
#   --help                 Show this help message
#

set -e
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
NAMESPACE=""
SKIP_E2E=false
VERBOSE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test results tracking
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    ((PASSED_CHECKS++))
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
    ((WARNING_CHECKS++))
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
    ((FAILED_CHECKS++))
}

log_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ $(printf '%-60s' "$1")║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

increment_check() {
    ((TOTAL_CHECKS++))
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --skip-e2e)
            SKIP_E2E=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            head -n 20 "$0" | tail -n +3 | sed 's/^# //;s/^#//'
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$NAMESPACE" ]; then
    log_error "Namespace is required. Use --namespace <name>"
    exit 1
fi

log_header "Cost Management Verification"
log_info "Namespace: $NAMESPACE"
log_info "Skip E2E: $SKIP_E2E"
echo ""

# =============================================================================
# Phase 3.1: Pod Health Check
# =============================================================================
log_header "Phase 3.1: Pod Health Check"

increment_check
log_info "Checking all pods..."
if oc get pods -n "$NAMESPACE" &>/dev/null; then
    TOTAL_PODS=$(oc get pods -n "$NAMESPACE" --no-headers | wc -l | tr -d ' ')
    RUNNING_PODS=$(oc get pods -n "$NAMESPACE" --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')

    if [ "$VERBOSE" = true ]; then
        oc get pods -n "$NAMESPACE"
    fi

log_info "Total pods: $TOTAL_PODS"
log_info "Running pods: $RUNNING_PODS"

if [ "$RUNNING_PODS" -ge 23 ]; then
        log_success "Pod count check passed ($RUNNING_PODS/23+ running)"
    else
        log_warning "Expected at least 23 running pods, found $RUNNING_PODS"
    fi
else
    log_error "Cannot access pods in namespace $NAMESPACE"
fi

increment_check
log_info "Checking for failed pods..."
FAILED_PODS=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -E "Error|CrashLoopBackOff|ImagePullBackOff" | wc -l | tr -d ' ')
if [ "$FAILED_PODS" -eq 0 ]; then
    log_success "No failed pods found"
else
    log_error "Found $FAILED_PODS failed pod(s)"
    if [ "$VERBOSE" = true ]; then
        oc get pods -n "$NAMESPACE" | grep -E "Error|CrashLoopBackOff|ImagePullBackOff"
    fi
fi

# =============================================================================
# Phase 3.2: Database Verification
# =============================================================================
log_header "Phase 3.2: Database Verification"

increment_check
log_info "Checking PostgreSQL accessibility..."
if oc exec postgres-0 -n "$NAMESPACE" -- psql -U koku -d koku -c "SELECT 1;" &>/dev/null; then
    log_success "PostgreSQL is accessible"
else
    log_error "Cannot access PostgreSQL"
fi

increment_check
log_info "Checking database tenants..."
TENANT_COUNT=$(oc exec postgres-0 -n "$NAMESPACE" -- psql -U koku -d koku -t -c "SELECT COUNT(*) FROM api_tenant;" 2>/dev/null | tr -d ' ' || echo "0")
if [ "$TENANT_COUNT" -gt 0 ]; then
    log_success "Database has $TENANT_COUNT tenant(s)"
else
    log_warning "No tenants found in database"
fi

increment_check
log_info "Checking database migrations..."
MIGRATION_COUNT=$(oc exec postgres-0 -n "$NAMESPACE" -- psql -U koku -d koku -t -c "SELECT COUNT(*) FROM django_migrations;" 2>/dev/null | tr -d ' ' || echo "0")
if [ "$MIGRATION_COUNT" -gt 0 ]; then
    log_success "Found $MIGRATION_COUNT applied migration(s)"
else
    log_error "No migrations found - database may not be initialized"
fi

increment_check
log_info "Checking database extensions..."
if oc exec postgres-0 -n "$NAMESPACE" -- psql -U koku -d koku -c "SELECT * FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null | grep -q pg_stat_statements; then
    log_success "Required extensions are installed"
else
    log_warning "pg_stat_statements extension not found"
fi

# =============================================================================
# Phase 3.3: API Health Check
# =============================================================================
log_header "Phase 3.3: API Health Check"

increment_check
log_info "Checking API service..."
if oc get svc -n "$NAMESPACE" | grep -q "cost-management-onprem-koku-api"; then
    log_success "API service exists"

    increment_check
    log_info "Testing API endpoint..."

    # Port forward in background
    oc port-forward -n "$NAMESPACE" svc/cost-mgmt-cost-management-onprem-koku-api 8080:8000 &>/dev/null &
    PF_PID=$!
    sleep 3

    if curl -s --max-time 10 http://localhost:8080/api/cost-management/v1/status/ | grep -q "api_version"; then
        log_success "API is responding correctly"
    else
        log_error "API is not responding or returned unexpected response"
    fi

    # Cleanup port-forward
    kill $PF_PID 2>/dev/null || true
else
    log_error "API service not found"
fi

# =============================================================================
# Phase 3.4: Kafka Connectivity Check
# =============================================================================
log_header "Phase 3.4: Kafka Connectivity Check"

increment_check
log_info "Checking Kafka cluster..."
if oc get kafka -n kafka ros-ocp-kafka &>/dev/null; then
    log_success "Kafka cluster exists"

    increment_check
    log_info "Checking Kafka pods..."
    KAFKA_PODS=$(oc get pods -n kafka | grep -E "ros-ocp-kafka-kafka|ros-ocp-kafka-zookeeper" | grep Running | wc -l | tr -d ' ')
    if [ "$KAFKA_PODS" -ge 6 ]; then
        log_success "Kafka pods are running ($KAFKA_PODS/6+)"
    else
        log_warning "Expected at least 6 Kafka pods, found $KAFKA_PODS"
    fi

    increment_check
    log_info "Testing Kafka connectivity from application..."
    if oc exec -n "$NAMESPACE" deployment/cost-mgmt-cost-management-onprem-masu -- \
        bash -c 'echo | timeout 5 telnet ros-ocp-kafka-kafka-bootstrap.kafka.svc.cluster.local 9092' 2>&1 | grep -q "Connected"; then
        log_success "Application can connect to Kafka"
    else
        log_warning "Cannot verify Kafka connectivity from application"
    fi
else
    log_error "Kafka cluster not found in 'kafka' namespace"
fi

# =============================================================================
# Phase 3.5: Storage Verification
# =============================================================================
log_header "Phase 3.5: Storage Verification"

increment_check
log_info "Checking PersistentVolumeClaims..."
TOTAL_PVC=$(oc get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
BOUND_PVC=$(oc get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep Bound | wc -l | tr -d ' ')

if [ "$TOTAL_PVC" -gt 0 ]; then
log_info "Total PVCs: $TOTAL_PVC"
log_info "Bound PVCs: $BOUND_PVC"

if [ "$TOTAL_PVC" -eq "$BOUND_PVC" ]; then
        log_success "All PVCs are bound"
else
        log_error "Some PVCs are not bound ($BOUND_PVC/$TOTAL_PVC)"
        if [ "$VERBOSE" = true ]; then
        oc get pvc -n "$NAMESPACE" | grep -v Bound
    fi
fi
else
    log_warning "No PVCs found"
fi

increment_check
log_info "Checking S3 credentials secret..."
if oc get secret odf-s3-credentials -n "$NAMESPACE" &>/dev/null; then
    log_success "S3 credentials secret exists"
else
    log_error "S3 credentials secret 'odf-s3-credentials' not found"
fi

# =============================================================================
# Phase 3.6: Celery Workers Check
# =============================================================================
log_header "Phase 3.6: Celery Workers Check"

increment_check
log_info "Checking Celery Beat scheduler..."
if oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=celery-beat --no-headers 2>/dev/null | grep -q Running; then
    log_success "Celery Beat is running"
else
    log_error "Celery Beat is not running"
fi

increment_check
log_info "Checking Celery workers..."
CELERY_WORKERS=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=celery-worker --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
if [ "$CELERY_WORKERS" -ge 12 ]; then
    log_success "Found $CELERY_WORKERS Celery worker(s)"
else
    log_warning "Expected at least 12 Celery workers, found $CELERY_WORKERS"
fi

if [ "$VERBOSE" = true ]; then
    log_info "Celery worker types:"
    oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=celery-worker \
        -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.worker-type --no-headers 2>/dev/null || true
fi

# =============================================================================
# Phase 3.7: Sources API Check
# =============================================================================
log_header "Phase 3.7: Sources API Check"

increment_check
log_info "Checking Sources API..."
if oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=sources-api --no-headers 2>/dev/null | grep -q Running; then
    log_success "Sources API is running"
else
    log_error "Sources API is not running"
fi

increment_check
log_info "Checking Sources database..."
if oc get pods -n "$NAMESPACE" | grep -q "sources-db.*Running"; then
    log_success "Sources database is running"

    # Test connection
    if oc exec -n "$NAMESPACE" sources-db-0 -- psql -U sources -d sources -c "SELECT version();" &>/dev/null; then
        log_success "Sources database is accessible"
    else
        log_warning "Sources database is running but not accessible"
    fi
else
    log_error "Sources database is not running"
fi

# =============================================================================
# Phase 3.8: Complete Health Summary
# =============================================================================
log_header "Phase 3.8: Complete Health Summary"

log_info "Infrastructure Components:"
oc get pods -n "$NAMESPACE" 2>/dev/null | grep -E "postgres|trino|hive|redis" || log_warning "  No infrastructure pods found"

echo ""
log_info "Kafka Components:"
oc get pods -n kafka 2>/dev/null | grep ros-ocp-kafka || log_warning "  No Kafka pods found"

echo ""
log_info "Koku API Components:"
oc get pods -n "$NAMESPACE" 2>/dev/null | grep -E "koku-api|masu" || log_warning "  No API pods found"

echo ""
log_info "Celery Workers:"
oc get pods -n "$NAMESPACE" 2>/dev/null | grep celery | head -5 || log_warning "  No Celery pods found"
CELERY_COUNT=$(oc get pods -n "$NAMESPACE" 2>/dev/null | grep celery | wc -l | tr -d ' ')
if [ "$CELERY_COUNT" -gt 5 ]; then
    log_info "  ... and $((CELERY_COUNT - 5)) more"
fi

echo ""
log_info "Sources Components:"
oc get pods -n "$NAMESPACE" 2>/dev/null | grep sources || log_warning "  No Sources pods found"

echo ""
log_info "PVC Status:"
oc get pvc -n "$NAMESPACE" 2>/dev/null || log_warning "  No PVCs found"

echo ""
log_info "Services:"
oc get svc -n "$NAMESPACE" 2>/dev/null | head -10 || log_warning "  No services found"

# =============================================================================
# Phase 4: E2E Testing (Optional)
# =============================================================================
if [ "$SKIP_E2E" = false ]; then
    log_header "Phase 4: E2E Testing (Optional)"

    increment_check
    log_info "Running OCP smoke tests..."

    if [ -f "$SCRIPT_DIR/cost-mgmt-ocp-dataflow.sh" ]; then
        log_info "Starting E2E validation (this may take 1-2 minutes)..."
        if "$SCRIPT_DIR/cost-mgmt-ocp-dataflow.sh" --namespace "$NAMESPACE" --smoke-test --force; then
            log_success "E2E smoke tests passed"
        else
            log_error "E2E smoke tests failed"
        fi
    else
        log_warning "E2E test script not found, skipping"
    fi
else
    log_info "Skipping E2E tests (use without --skip-e2e to run)"
fi

# =============================================================================
# Final Report
# =============================================================================
echo ""
echo ""
log_header "Verification Complete"

echo -e "${BLUE}Test Results:${NC}"
echo -e "  Total Checks: ${CYAN}$TOTAL_CHECKS${NC}"
echo -e "  Passed:       ${GREEN}$PASSED_CHECKS${NC}"
echo -e "  Warnings:     ${YELLOW}$WARNING_CHECKS${NC}"
echo -e "  Failed:       ${RED}$FAILED_CHECKS${NC}"
echo ""

# Calculate success rate
if [ "$TOTAL_CHECKS" -gt 0 ]; then
    SUCCESS_RATE=$(( (PASSED_CHECKS * 100) / TOTAL_CHECKS ))
    echo -e "  Success Rate: ${CYAN}${SUCCESS_RATE}%${NC}"
    echo ""
fi

# Overall status
if [ "$FAILED_CHECKS" -eq 0 ]; then
    if [ "$WARNING_CHECKS" -eq 0 ]; then
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                                                            ║${NC}"
        echo -e "${GREEN}║  ✓ ALL CHECKS PASSED - Deployment is healthy!             ║${NC}"
        echo -e "${GREEN}║                                                            ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        exit 0
    else
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║                                                            ║${NC}"
        echo -e "${YELLOW}║  ⚠ PASSED WITH WARNINGS - Review warnings above           ║${NC}"
        echo -e "${YELLOW}║                                                            ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
        exit 0
    fi
else
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  ✗ VERIFICATION FAILED - Fix errors above                  ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Troubleshooting:${NC}"
    echo "  - Review failed checks above"
    echo "  - Check pod logs: oc logs -n $NAMESPACE <pod-name>"
    echo "  - Check events: oc get events -n $NAMESPACE --sort-by='.lastTimestamp'"
    echo "  - See installation guide: docs/cost-management-installation.md"
    exit 1
fi
