#!/bin/bash
#
# Cost Management OCP Dataflow Validation
# ========================================
# Validates the complete OpenShift Container Platform (OCP) data pipeline:
# Data Generation → Upload → Kafka → Processing → Aggregation → Validation
#
# This script uses NISE-GENERATED DATA for predictable validation.
# Benefits:
#   - Validates complete dataflow end-to-end
#   - Financial correctness verification
#   - Detects processing and aggregation issues
#   - No external dependencies (standalone)
#
# SCENARIO:
#   - Minimal OCP pod-only: 1 pod, 1 node, 24 hours (~60 seconds)
#   - Validates complete pipeline
#   - Suitable for CI/CD and quick validation
#
# Environment Variables:
#   LOG_LEVEL - Control output verbosity (shell wrapper and Python validator)
#               DEBUG - Most verbose (default for CI/CD troubleshooting)
#               INFO  - Detailed output
#               WARN  - Clean output (successes, warnings, errors only)
#               ERROR - Errors only
#
# See OCP_SMOKE_TEST_GUIDE.md for detailed documentation.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging configuration
# Default: DEBUG for CI/CD (helps triage issues quickly)
# Override with: LOG_LEVEL=WARN ./cost-mgmt-ocp-dataflow.sh
LOG_LEVEL=${LOG_LEVEL:-DEBUG}

# Logging functions with LOG_LEVEL support
log_debug() {
    [[ "$LOG_LEVEL" == "DEBUG" ]] && echo -e "$1"
    return 0
}

log_info() {
    [[ "$LOG_LEVEL" =~ ^(INFO|DEBUG)$ ]] && echo -e "$1"
    return 0
}

log_success() {
    [[ "$LOG_LEVEL" =~ ^(WARN|INFO|DEBUG)$ ]] && echo -e "$1"
    return 0
}

log_warning() {
    [[ "$LOG_LEVEL" =~ ^(WARN|INFO|DEBUG)$ ]] && echo -e "$1"
    return 0
}

log_error() {
    # Errors are always shown
    echo -e "$1" >&2
    return 0
}

# Default values
NAMESPACE="cost-onprem"
FORCE=true  # Always force for E2E validation (ensures Kafka trigger)
SKIP_TESTS=false
TIMEOUT=300

# Print usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

OCP Dataflow Validation for Cost Management on-prem deployment.

OPTIONS:
    --namespace NAMESPACE       Kubernetes namespace (default: cost-onprem)
    --force                    Force data regeneration
    --skip-tests               Skip validation tests (only validate data pipeline)
    --timeout SECONDS          Processing timeout (default: 300)
    --help                     Show this help message

SCENARIO:
    Minimal OCP pod-only scenario with nise-generated data (~60 seconds)
    - 1 pod, 1 node, 24 hours of usage data
    - Complete pipeline validation
    - Financial correctness verification

EXAMPLES:
    # Run validation (reuse existing data if available)
    $0

    # Force fresh data generation
    $0 --force

    # Pipeline check only (skip validation tests)
    $0 --skip-tests --force

    # See OCP_SMOKE_TEST_GUIDE.md for detailed documentation

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

# Capture start time
START_TIME=$(date +%s)

# Print banner
log_info "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
log_info "${BLUE}║                                                               ║${NC}"
log_info "${BLUE}║  OCP-Only E2E Validation Suite                                ║${NC}"
log_info "${BLUE}║  Cost Management on-prem - OpenShift Provider Focus          ║${NC}"
log_info "${BLUE}║                                                               ║${NC}"
log_info "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
log_info ""
log_info "${GREEN}Configuration:${NC}"
log_info "  Namespace:  $NAMESPACE"
log_info "  Provider:   OCP (OpenShift Container Platform)"
log_info "  Data:       NISE-GENERATED (minimal pod-only scenario)"
log_info "  Timeout:    ${TIMEOUT}s"
log_info ""

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check kubectl/oc context is set
log_info "${BLUE}🔍 Checking Kubernetes context...${NC}"
if ! kubectl config current-context &>/dev/null; then
    log_error "${RED}❌ No Kubernetes context is set${NC}"
    log_error ""
    log_error "Please set your kubectl/oc context first:"
    log_error "  kubectl config use-context <context-name>"
    log_error "  # or for OpenShift:"
    log_error "  oc login <cluster-url>"
    log_error ""
    log_error "Available contexts:"
    kubectl config get-contexts
    exit 1
fi
CURRENT_CONTEXT=$(kubectl config current-context)
log_success "${GREEN}  ✓ Context: ${CURRENT_CONTEXT}${NC}"
log_info ""

# Use dedicated cost-mgmt venv (clean, no IQE dependencies)
VENV_DIR="$SCRIPT_DIR/cost-mgmt-venv"

if [ ! -d "$VENV_DIR" ]; then
    log_info "${BLUE}🔧 Creating clean venv...${NC}"
    python3 -m venv "$VENV_DIR"
fi

log_info "${BLUE}🔧 Activating cost-mgmt venv...${NC}"
source "$VENV_DIR/bin/activate"

# Check Python dependencies
log_info "${BLUE}🔧 Checking Python dependencies...${NC}"
if ! python3 -c "import kubernetes, boto3, yaml" 2>/dev/null; then
    log_warning "${YELLOW}⚠️  Installing Python dependencies...${NC}"
    pip3 install -q -r "$SCRIPT_DIR/requirements-e2e.txt"
fi
log_success "${GREEN}  ✓ Python dependencies available${NC}"
log_success "${GREEN}  ✓ Using venv: $VENV_DIR${NC}"
log_info ""

# Build Python command
cd "$SCRIPT_DIR"

# Suppress urllib3 SSL warnings (not helpful for our use case)
export PYTHONWARNINGS="ignore:Unverified HTTPS request"

CMD="python3 -u -m e2e_validator.cli"
CMD="$CMD --namespace $NAMESPACE"
CMD="$CMD --provider-type OCP"
CMD="$CMD --timeout $TIMEOUT"
CMD="$CMD --smoke-test"  # Always use minimal scenario

if [ "$FORCE" = true ]; then
    CMD="$CMD --force"
fi

if [ "$SKIP_TESTS" = true ]; then
    CMD="$CMD --skip-tests"
fi

# Run the E2E validation
# Note: Database queries use kubectl exec - no port-forward needed!
log_info "${BLUE}Starting OCP E2E validation...${NC}"
log_info ""

# Export LOG_LEVEL so Python validator can use it
export LOG_LEVEL

if eval "$CMD"; then
    # Deactivate venv
    deactivate 2>/dev/null || true

    # Calculate total time
    END_TIME=$(date +%s)
    TOTAL_SECONDS=$((END_TIME - START_TIME))
    MINUTES=$((TOTAL_SECONDS / 60))
    SECONDS=$((TOTAL_SECONDS % 60))

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                               ║${NC}"
    echo -e "${GREEN}║  ✓ OCP E2E Validation PASSED                                  ║${NC}"
    echo -e "${GREEN}║                                                               ║${NC}"
    echo -e "${GREEN}║  Total time: ${MINUTES}m ${SECONDS}s                                          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    # Deactivate venv
    deactivate 2>/dev/null || true

    # Calculate total time
    END_TIME=$(date +%s)
    TOTAL_SECONDS=$((END_TIME - START_TIME))
    MINUTES=$((TOTAL_SECONDS / 60))
    SECONDS=$((TOTAL_SECONDS % 60))

    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                               ║${NC}"
    echo -e "${RED}║  ✗ OCP E2E Validation FAILED                                  ║${NC}"
    echo -e "${RED}║                                                               ║${NC}"
    echo -e "${RED}║  Total time: ${MINUTES}m ${SECONDS}s                                          ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

