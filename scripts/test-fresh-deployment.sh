#!/bin/bash

# Test Script: Clean Installation of RHBK to Reproduce Admin Secret Issue
# This script orchestrates a complete cleanup and fresh deployment

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo_header() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
}

# Check prerequisites
echo_header "PREREQUISITES CHECK"

if ! command -v oc >/dev/null 2>&1; then
    echo_error "oc command not found. Please install OpenShift CLI."
    exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
    echo_error "Not logged into OpenShift cluster."
    echo_info "Please run: oc login <your-cluster>"
    exit 1
fi

echo_success "✓ Logged into OpenShift as: $(oc whoami)"
echo_info "Cluster: $(oc whoami --show-server)"

# Step 1: Complete Cleanup
echo_header "STEP 1: COMPLETE CLEANUP"
echo_warning "This will remove ALL related components and container images"
echo_warning "This may take 5-10 minutes"
echo ""
echo -n "Proceed with cleanup? (yes/no): "
read -r cleanup_confirm

if [ "$cleanup_confirm" != "yes" ]; then
    echo_info "Cleanup cancelled. Exiting."
    exit 0
fi

echo_info "Starting cleanup..."
./cleanup-all-components.sh

# Step 2: Verify Clean State
echo_header "STEP 2: VERIFY CLEAN STATE"

echo_info "Checking for remaining namespaces..."
remaining_ns=$(oc get namespace -o name 2>/dev/null | grep -E "(keycloak|rhbk|cost-mgmt|kruize|sources|authorino|kafka)" || true)

if [ -n "$remaining_ns" ]; then
    echo_warning "Found remaining namespaces:"
    echo "$remaining_ns"
    echo_warning "These may be in Terminating state. Waiting 30 seconds..."
    sleep 30
else
    echo_success "✓ No related namespaces found"
fi

echo_info "Checking for remaining CRDs..."
remaining_crds=$(oc get crd -o name 2>/dev/null | grep -E "(keycloak|kafka|strimzi|authorino|kruize)" || true)

if [ -n "$remaining_crds" ]; then
    echo_warning "Found remaining CRDs:"
    echo "$remaining_crds"
else
    echo_success "✓ No related CRDs found"
fi

echo_info "Checking for remaining operator CSVs..."
remaining_csvs=$(oc get csv -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | grep -E "(keycloak|rhbk|kafka|strimzi|authorino|kruize)" || true)

if [ -n "$remaining_csvs" ]; then
    echo_warning "Found remaining CSVs:"
    echo "$remaining_csvs"
else
    echo_success "✓ No related operator CSVs found"
fi

echo_success "Clean state verification complete"

# Step 3: Fresh Deployment
echo_header "STEP 3: FRESH RHBK DEPLOYMENT"
echo_info "This will deploy RHBK from scratch"
echo_info "We'll monitor for the admin secret issue"
echo ""

# Create log directory
LOG_DIR="./test-logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/rhbk-deployment-${TIMESTAMP}.log"

echo_info "Log file: $LOG_FILE"
echo ""
echo -n "Proceed with deployment? (yes/no): "
read -r deploy_confirm

if [ "$deploy_confirm" != "yes" ]; then
    echo_info "Deployment cancelled. Exiting."
    exit 0
fi

echo_info "Starting RHBK deployment..."
echo_info "Monitoring for admin secret timing issues..."
echo ""

# Run deployment with logging and monitoring
{
    echo "=== RHBK Deployment Test - $TIMESTAMP ==="
    echo "Cluster: $(oc whoami --show-server)"
    echo "User: $(oc whoami)"
    echo ""

    # Run the deployment script
    ./deploy-rhbk.sh

} 2>&1 | tee "$LOG_FILE"

DEPLOY_EXIT_CODE=${PIPESTATUS[0]}

# Step 4: Analyze Results
echo_header "STEP 4: RESULTS ANALYSIS"

if [ $DEPLOY_EXIT_CODE -eq 0 ]; then
    echo_success "✓ Deployment completed successfully!"
    echo_info "No admin secret issue encountered"
    echo_info "This means either:"
    echo_info "  1. The wait_for_admin_secret() function worked correctly"
    echo_info "  2. The timing was lucky and secret was ready"
    echo_info "  3. The issue only occurs in specific conditions"
else
    echo_error "✗ Deployment failed with exit code: $DEPLOY_EXIT_CODE"
    echo_info "Analyzing failure..."

    # Check if it's the admin secret issue
    if grep -q "keycloak-initial-admin.*not found" "$LOG_FILE"; then
        echo_error "CONFIRMED: Admin secret timing issue detected!"
        echo_info "The secret was accessed before it was created by the operator"

        # Show relevant log lines
        echo ""
        echo_info "Relevant log excerpt:"
        grep -A 5 -B 5 "keycloak-initial-admin" "$LOG_FILE" | tail -20

    elif grep -q "Could not retrieve auto-generated admin password" "$LOG_FILE"; then
        echo_error "CONFIRMED: Admin password retrieval failed!"
        echo_info "The secret may exist but is empty or malformed"

    elif grep -q "Timeout waiting for keycloak-initial-admin secret" "$LOG_FILE"; then
        echo_error "CONFIRMED: Admin secret not created within timeout!"
        echo_info "The RHBK operator took longer than 180 seconds to create the secret"

    else
        echo_warning "Failure was due to different reason"
        echo_info "Check the log file for details: $LOG_FILE"
    fi
fi

# Step 5: Environment State
echo_header "STEP 5: ENVIRONMENT STATE"

echo_info "Checking namespace..."
if oc get namespace keycloak >/dev/null 2>&1; then
    echo_success "✓ keycloak namespace exists"

    echo_info "Checking for admin secret..."
    if oc get secret keycloak-initial-admin -n keycloak >/dev/null 2>&1; then
        echo_success "✓ keycloak-initial-admin secret exists"

        # Check secret contents
        has_username=$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.username}' 2>/dev/null)
        has_password=$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' 2>/dev/null)

        if [ -n "$has_username" ] && [ -n "$has_password" ]; then
            echo_success "✓ Secret has username and password fields"
            username=$(echo "$has_username" | base64 -d)
            echo_info "  Username: $username"
            echo_info "  Password: [present, length: ${#has_password}]"
        else
            echo_warning "⚠ Secret exists but is missing username or password"
        fi
    else
        echo_error "✗ keycloak-initial-admin secret NOT found"
    fi

    echo_info "Checking Keycloak CR..."
    if oc get keycloak keycloak -n keycloak >/dev/null 2>&1; then
        status=$(oc get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        echo_info "  Keycloak CR Ready status: $status"
    fi
else
    echo_warning "keycloak namespace not found"
fi

# Summary
echo_header "SUMMARY"
echo_info "Test completed at: $(date)"
echo_info "Log file: $LOG_FILE"
echo ""

if [ $DEPLOY_EXIT_CODE -eq 0 ]; then
    echo_success "Deployment successful - Issue not reproduced"
    echo_info "Next steps:"
    echo_info "  1. Try running the test multiple times to see if it's intermittent"
    echo_info "  2. Check if wait_for_admin_secret() is sufficient"
    echo_info "  3. Consider adding more logging to trace secret creation timing"
else
    echo_error "Deployment failed - Issue reproduced!"
    echo_info "Next steps:"
    echo_info "  1. Review the log file: $LOG_FILE"
    echo_info "  2. Identify the exact timing of secret creation vs. usage"
    echo_info "  3. Implement fix based on findings"
    echo_info "  4. Re-run this test to verify fix"
fi

echo ""
echo_info "To clean up and test again, run: $0"







