#!/bin/bash

# RHBK Resource Triage Script
# Verifies that NO RHBK/Keycloak resources remain in the cluster
# Run this after cleanup to ensure pristine state before reproducing the issue

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
    echo -e "${GREEN}[✓]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

echo_error() {
    echo -e "${RED}[✗]${NC} $1"
}

echo_header() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
}

# Track if we found any resources
FOUND_RESOURCES=0

echo_header "RHBK RESOURCE TRIAGE"
echo_info "Checking for ANY remaining RHBK/Keycloak resources..."
echo ""

# Check prerequisites
if ! command -v oc >/dev/null 2>&1; then
    echo_error "oc command not found"
    exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
    echo_error "Not logged into OpenShift cluster"
    exit 1
fi

echo_success "Connected to cluster: $(oc whoami --show-server)"
echo_info "User: $(oc whoami)"
echo ""

# 1. Check for namespaces
echo_header "1. CHECKING NAMESPACES"
namespaces=$(oc get namespace -o name 2>/dev/null | grep -iE "(keycloak|rhbk)" || true)

if [ -z "$namespaces" ]; then
    echo_success "No RHBK/Keycloak namespaces found"
else
    echo_error "Found RHBK/Keycloak namespaces:"
    echo "$namespaces" | while read -r ns; do
        echo "  - $ns"
        # Check if terminating
        status=$(oc get "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo "    Status: $status"
    done
    FOUND_RESOURCES=1
fi

# 2. Check for CRDs
echo_header "2. CHECKING CUSTOM RESOURCE DEFINITIONS (CRDs)"
crds=$(oc get crd -o name 2>/dev/null | grep -iE "keycloak" || true)

if [ -z "$crds" ]; then
    echo_success "No Keycloak CRDs found"
else
    echo_error "Found Keycloak CRDs:"
    echo "$crds" | while read -r crd; do
        echo "  - $crd"
    done
    FOUND_RESOURCES=1
fi

# 3. Check for operator subscriptions
echo_header "3. CHECKING OPERATOR SUBSCRIPTIONS"
subscriptions=$(oc get subscription -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | grep -iE "(rhbk|keycloak)" || true)

if [ -z "$subscriptions" ]; then
    echo_success "No RHBK operator subscriptions found"
else
    echo_error "Found RHBK operator subscriptions:"
    echo "$subscriptions" | while read -r line; do
        echo "  - $line"
    done
    FOUND_RESOURCES=1
fi

# 4. Check for ClusterServiceVersions (CSVs)
echo_header "4. CHECKING CLUSTERSERVICEVERSIONS (CSVs)"
csvs=$(oc get csv -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | grep -iE "(rhbk|keycloak)" || true)

if [ -z "$csvs" ]; then
    echo_success "No RHBK operator CSVs found"
else
    echo_error "Found RHBK operator CSVs:"
    echo "$csvs" | while read -r line; do
        echo "  - $line"
    done
    FOUND_RESOURCES=1
fi

# 5. Check for InstallPlans
echo_header "5. CHECKING INSTALLPLANS"
installplans=$(oc get installplan -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | grep -iE "(rhbk|keycloak)" || true)

if [ -z "$installplans" ]; then
    echo_success "No RHBK InstallPlans found"
else
    echo_error "Found RHBK InstallPlans:"
    echo "$installplans" | while read -r line; do
        echo "  - $line"
    done
    FOUND_RESOURCES=1
fi

# 6. Check for OperatorGroups
echo_header "6. CHECKING OPERATORGROUPS"
operatorgroups=$(oc get operatorgroup -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | grep -iE "(rhbk|keycloak)" || true)

if [ -z "$operatorgroups" ]; then
    echo_success "No RHBK OperatorGroups found"
else
    echo_error "Found RHBK OperatorGroups:"
    echo "$operatorgroups" | while read -r line; do
        echo "  - $line"
    done
    FOUND_RESOURCES=1
fi

# 7. Check for ClusterRoles
echo_header "7. CHECKING CLUSTERROLES"
clusterroles=$(oc get clusterrole -o name 2>/dev/null | grep -iE "(rhbk|keycloak)" || true)

if [ -z "$clusterroles" ]; then
    echo_success "No RHBK ClusterRoles found"
else
    echo_error "Found RHBK ClusterRoles:"
    echo "$clusterroles" | while read -r cr; do
        echo "  - $cr"
    done
    FOUND_RESOURCES=1
fi

# 8. Check for ClusterRoleBindings
echo_header "8. CHECKING CLUSTERROLEBINDINGS"
clusterrolebindings=$(oc get clusterrolebinding -o name 2>/dev/null | grep -iE "(rhbk|keycloak)" || true)

if [ -z "$clusterrolebindings" ]; then
    echo_success "No RHBK ClusterRoleBindings found"
else
    echo_error "Found RHBK ClusterRoleBindings:"
    echo "$clusterrolebindings" | while read -r crb; do
        echo "  - $crb"
    done
    FOUND_RESOURCES=1
fi

# 9. Check for MutatingWebhookConfigurations
echo_header "9. CHECKING MUTATING WEBHOOKS"
mutating_webhooks=$(oc get mutatingwebhookconfiguration -o name 2>/dev/null | grep -iE "keycloak" || true)

if [ -z "$mutating_webhooks" ]; then
    echo_success "No Keycloak MutatingWebhooks found"
else
    echo_error "Found Keycloak MutatingWebhooks:"
    echo "$mutating_webhooks" | while read -r wh; do
        echo "  - $wh"
    done
    FOUND_RESOURCES=1
fi

# 10. Check for ValidatingWebhookConfigurations
echo_header "10. CHECKING VALIDATING WEBHOOKS"
validating_webhooks=$(oc get validatingwebhookconfiguration -o name 2>/dev/null | grep -iE "keycloak" || true)

if [ -z "$validating_webhooks" ]; then
    echo_success "No Keycloak ValidatingWebhooks found"
else
    echo_error "Found Keycloak ValidatingWebhooks:"
    echo "$validating_webhooks" | while read -r wh; do
        echo "  - $wh"
    done
    FOUND_RESOURCES=1
fi

# 11. Check for PVCs in any namespace
echo_header "11. CHECKING PERSISTENT VOLUME CLAIMS"
pvcs=$(oc get pvc -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | grep -iE "(keycloak|postgres)" || true)

if [ -z "$pvcs" ]; then
    echo_success "No Keycloak/PostgreSQL PVCs found"
else
    echo_error "Found Keycloak/PostgreSQL PVCs:"
    echo "$pvcs" | while read -r line; do
        echo "  - $line"
    done
    FOUND_RESOURCES=1
fi

# 12. Check for Secrets in any namespace
echo_header "12. CHECKING SECRETS"
secrets=$(oc get secret -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | grep -iE "(keycloak)" || true)

if [ -z "$secrets" ]; then
    echo_success "No Keycloak secrets found"
else
    echo_warning "Found Keycloak-related secrets:"
    echo "$secrets" | while read -r line; do
        echo "  - $line"
    done
    echo_info "Note: Some secrets may be from previous installations"
    # Don't count secrets as blocking, just informational
fi

# 13. Check for container images on ALL nodes
echo_header "13. CHECKING CONTAINER IMAGES ON ALL NODES"
echo_info "Checking for Keycloak/RHBK images on all nodes..."

# Get all nodes
all_nodes=$(oc get nodes -o name 2>/dev/null | cut -d'/' -f2)

if [ -z "$all_nodes" ]; then
    echo_warning "Could not list nodes for image check"
else
    node_count=$(echo "$all_nodes" | wc -l | tr -d ' ')
    echo_info "Found $node_count node(s) to check"
    echo ""

    images_found=0

    while IFS= read -r node; do
        if [ -n "$node" ]; then
            echo_info "Checking node: $node"

            # Try to check for images using oc debug
            images=$(oc debug node/"$node" --quiet -- chroot /host bash -c "crictl images 2>/dev/null | grep -iE 'keycloak|rhbk'" 2>/dev/null || true)

            if [ -z "$images" ]; then
                echo_success "  ✓ No RHBK/Keycloak images found"
            else
                echo_warning "  ⚠ Found RHBK/Keycloak images:"
                echo "$images" | while read -r line; do
                    echo "    - $line"
                done
                images_found=1
            fi
        fi
    done <<< "$all_nodes"

    echo ""
    if [ $images_found -eq 0 ]; then
        echo_success "✓ No RHBK/Keycloak images found on any node"
    else
        echo_warning "⚠ RHBK/Keycloak images found on some nodes"
        echo_info "Recommendation: Run cleanup script with image removal option"
        # Don't count images as blocking for deployment test
    fi
fi

# Final summary
echo_header "TRIAGE SUMMARY"

if [ $FOUND_RESOURCES -eq 0 ]; then
    echo_success "✓ CLUSTER IS CLEAN"
    echo_success "No RHBK/Keycloak resources found"
    echo ""
    echo_info "The cluster is ready for a fresh RHBK deployment"
    echo_info "Next step: Run ./deploy-rhbk.sh to reproduce the issue"
    echo ""
    exit 0
else
    echo_error "✗ CLUSTER IS NOT CLEAN"
    echo_error "Found RHBK/Keycloak resources (see above)"
    echo ""
    echo_warning "Recommended actions:"
    echo_warning "  1. Run: ./cleanup-all-components.sh"
    echo_warning "  2. Wait for all resources to be fully deleted"
    echo_warning "  3. Run this triage script again"
    echo ""
    exit 1
fi

