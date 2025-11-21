#!/bin/bash
#
# OCP-Only E2E Validation Script
# ================================
# Simplified E2E testing focused exclusively on OpenShift Container Platform (OCP) providers.
#
# This script is a streamlined version of the full multi-cloud e2e-validate.sh,
# optimized for OCP-only deployments (first release scope).
#
# For multi-cloud testing (AWS/Azure/GCP), use the full e2e-validate.sh script.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
NAMESPACE="cost-mgmt"
SMOKE_TEST=false
FORCE=false
SKIP_TESTS=false
TIMEOUT=300

# Print usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

OCP-Only E2E Validation for Cost Management on-prem deployment.

OPTIONS:
    --namespace NAMESPACE       Kubernetes namespace (default: cost-mgmt)
    --smoke-test               Use fast minimal OCP CSV (smoke test mode)
    --force                    Force data regeneration
    --skip-tests               Skip IQE tests
    --timeout SECONDS          Processing timeout (default: 300)
    --help                     Show this help message

EXAMPLES:
    # Smoke test (fast, ~30-60 seconds)
    $0 --smoke-test --force

    # Full validation with nise (slower, ~5-10 minutes)
    $0 --force

    # Skip IQE tests
    $0 --smoke-test --skip-tests --force

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --smoke-test)
            SMOKE_TEST=true
            shift
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

# Print banner
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                                                               ║${NC}"
echo -e "${BLUE}║  OCP-Only E2E Validation Suite                                ║${NC}"
echo -e "${BLUE}║  Cost Management on-prem - OpenShift Provider Focus          ║${NC}"
echo -e "${BLUE}║                                                               ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Configuration:${NC}"
echo "  Namespace:  $NAMESPACE"
echo "  Provider:   OCP (OpenShift Container Platform)"
if [ "$SMOKE_TEST" = true ]; then
    echo "  Mode:       SMOKE TEST (fast minimal CSV)"
else
    echo "  Mode:       FULL VALIDATION (nise-generated)"
fi
echo "  Timeout:    ${TIMEOUT}s"
echo ""

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
IQE_DIR="/Users/jgil/go/src/github.com/insights-onprem/iqe-cost-management-plugin"
VENV_DIR="$IQE_DIR/iqe-venv"

# Check if IQE venv exists
if [ ! -d "$VENV_DIR" ]; then
    echo -e "${RED}❌ IQE venv not found at $VENV_DIR${NC}"
    echo "Please set up IQE venv first"
    exit 1
fi

# Activate IQE venv
echo -e "${BLUE}🔧 Activating IQE venv...${NC}"
source "$VENV_DIR/bin/activate"

# Check if dependencies are installed
if ! python3 -c "import kubernetes" 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Python dependencies not installed in IQE venv${NC}"
    echo "Installing requirements..."
    pip3 install -q -r "$SCRIPT_DIR/requirements-e2e.txt"
fi

# Build Python command
cd "$SCRIPT_DIR"
CMD="python3 -m e2e_validator.cli"
CMD="$CMD --namespace $NAMESPACE"
CMD="$CMD --provider-type OCP"
CMD="$CMD --timeout $TIMEOUT"

if [ "$SMOKE_TEST" = true ]; then
    CMD="$CMD --smoke-test"
fi

if [ "$FORCE" = true ]; then
    CMD="$CMD --force"
fi

if [ "$SKIP_TESTS" = true ]; then
    CMD="$CMD --skip-tests"
fi

# Run the E2E validation
echo -e "${BLUE}Starting OCP E2E validation...${NC}"
echo ""

if eval "$CMD"; then
    # Deactivate venv
    deactivate 2>/dev/null || true
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                               ║${NC}"
    echo -e "${GREEN}║  ✓ OCP E2E Validation PASSED                                  ║${NC}"
    echo -e "${GREEN}║                                                               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    # Deactivate venv
    deactivate 2>/dev/null || true
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                               ║${NC}"
    echo -e "${RED}║  ✗ OCP E2E Validation FAILED                                  ║${NC}"
    echo -e "${RED}║                                                               ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

