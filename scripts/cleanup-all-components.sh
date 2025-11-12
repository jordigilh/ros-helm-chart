#!/bin/bash

# Comprehensive Cleanup Script for Cost Management On-Prem Components
# This script removes ALL components including container images from nodes
# Use this to ensure a clean slate for testing new installations

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Function to check prerequisites
check_prerequisites() {
    echo_header "CHECKING PREREQUISITES"

    # Check if oc command is available
    if ! command -v oc >/dev/null 2>&1; then
        echo_error "oc command not found. Please install OpenShift CLI."
        exit 1
    fi
    echo_success "✓ OpenShift CLI (oc) is available"

    # Check if logged into OpenShift
    if ! oc whoami >/dev/null 2>&1; then
        echo_error "Not logged into OpenShift cluster. Please run 'oc login' first."
        exit 1
    fi
    echo_success "✓ Logged into OpenShift cluster as: $(oc whoami)"

    # Check if cluster has admin permissions
    if ! oc auth can-i delete namespaces >/dev/null 2>&1; then
        echo_error "Insufficient permissions to delete resources. Cluster admin access required."
        exit 1
    fi
    echo_success "✓ Cluster admin permissions verified"
}

# Function to delete Helm releases
cleanup_helm_releases() {
    echo_header "CLEANING UP HELM RELEASES"

    local releases=$(helm list -A -o json 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -E "(cost-mgmt|kruize|ros)" || true)

    if [ -z "$releases" ]; then
        echo_info "No Helm releases found matching cost-mgmt, kruize, or ros"
    else
        while IFS= read -r release; do
            if [ -n "$release" ]; then
                local namespace=$(helm list -A -o json 2>/dev/null | grep -A 10 "\"name\":\"$release\"" | grep -o '"namespace":"[^"]*"' | cut -d'"' -f4 | head -1)
                echo_info "Uninstalling Helm release: $release (namespace: $namespace)"
                helm uninstall "$release" -n "$namespace" 2>/dev/null || echo_warning "Failed to uninstall $release"
            fi
        done <<< "$releases"
        echo_success "✓ Helm releases cleaned up"
    fi
}

# Function to delete RHBK/Keycloak components
cleanup_rhbk() {
    echo_header "CLEANING UP RHBK/KEYCLOAK COMPONENTS"

    local namespaces="keycloak rhbk"

    for ns in $namespaces; do
        if oc get namespace "$ns" >/dev/null 2>&1; then
            echo_info "Cleaning up namespace: $ns"

            # Delete KeycloakRealmImport resources
            echo_info "  Deleting KeycloakRealmImport resources..."
            oc delete keycloakrealmimport --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete Keycloak instances
            echo_info "  Deleting Keycloak instances..."
            oc delete keycloak --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete StatefulSets (PostgreSQL)
            echo_info "  Deleting StatefulSets..."
            oc delete statefulset --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete PVCs
            echo_info "  Deleting PVCs..."
            oc delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete operator subscription
            echo_info "  Deleting RHBK operator subscription..."
            oc delete subscription rhbk-operator -n "$ns" 2>/dev/null || true

            # Delete operator group
            echo_info "  Deleting operator group..."
            oc delete operatorgroup --all -n "$ns" 2>/dev/null || true

            # Delete CSV (ClusterServiceVersion)
            echo_info "  Deleting ClusterServiceVersions..."
            oc delete csv -l operators.coreos.com/rhbk-operator."$ns" -n "$ns" 2>/dev/null || true

            # Wait a bit for operator cleanup
            sleep 5

            # Delete namespace
            echo_info "  Deleting namespace: $ns"
            oc delete namespace "$ns" --timeout=120s 2>/dev/null || true

            echo_success "✓ Cleaned up $ns namespace"
        else
            echo_info "Namespace $ns does not exist, skipping"
        fi
    done
}

# Function to delete Cost Management components
cleanup_cost_management() {
    echo_header "CLEANING UP COST MANAGEMENT COMPONENTS"

    local namespaces="cost-mgmt cost-management"

    for ns in $namespaces; do
        if oc get namespace "$ns" >/dev/null 2>&1; then
            echo_info "Cleaning up namespace: $ns"

            # Delete all deployments
            echo_info "  Deleting deployments..."
            oc delete deployment --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete all statefulsets
            echo_info "  Deleting statefulsets..."
            oc delete statefulset --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete all services
            echo_info "  Deleting services..."
            oc delete service --all -n "$ns" --timeout=30s 2>/dev/null || true

            # Delete all routes
            echo_info "  Deleting routes..."
            oc delete route --all -n "$ns" --timeout=30s 2>/dev/null || true

            # Delete all configmaps
            echo_info "  Deleting configmaps..."
            oc delete configmap --all -n "$ns" --timeout=30s 2>/dev/null || true

            # Delete all secrets (excluding service account secrets)
            echo_info "  Deleting secrets..."
            oc delete secret --field-selector type!=kubernetes.io/service-account-token -n "$ns" 2>/dev/null || true

            # Delete all PVCs
            echo_info "  Deleting PVCs..."
            oc delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete all jobs
            echo_info "  Deleting jobs..."
            oc delete job --all -n "$ns" --timeout=30s 2>/dev/null || true

            # Delete all cronjobs
            echo_info "  Deleting cronjobs..."
            oc delete cronjob --all -n "$ns" --timeout=30s 2>/dev/null || true

            # Wait a bit for cleanup
            sleep 5

            # Delete namespace
            echo_info "  Deleting namespace: $ns"
            oc delete namespace "$ns" --timeout=120s 2>/dev/null || true

            echo_success "✓ Cleaned up $ns namespace"
        else
            echo_info "Namespace $ns does not exist, skipping"
        fi
    done
}

# Function to delete Kruize/Autotune components
cleanup_kruize() {
    echo_header "CLEANING UP KRUIZE/AUTOTUNE COMPONENTS"

    local namespaces="kruize kruize-system autotune"

    for ns in $namespaces; do
        if oc get namespace "$ns" >/dev/null 2>&1; then
            echo_info "Cleaning up namespace: $ns"

            # Delete all resources in the namespace
            echo_info "  Deleting all resources..."
            oc delete all --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete PVCs
            echo_info "  Deleting PVCs..."
            oc delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete namespace
            echo_info "  Deleting namespace: $ns"
            oc delete namespace "$ns" --timeout=120s 2>/dev/null || true

            echo_success "✓ Cleaned up $ns namespace"
        else
            echo_info "Namespace $ns does not exist, skipping"
        fi
    done
}

# Function to delete Sources API components
cleanup_sources() {
    echo_header "CLEANING UP SOURCES API COMPONENTS"

    local namespaces="sources sources-api"

    for ns in $namespaces; do
        if oc get namespace "$ns" >/dev/null 2>&1; then
            echo_info "Cleaning up namespace: $ns"

            # Delete all resources
            echo_info "  Deleting all resources..."
            oc delete all --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete PVCs
            echo_info "  Deleting PVCs..."
            oc delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete namespace
            echo_info "  Deleting namespace: $ns"
            oc delete namespace "$ns" --timeout=120s 2>/dev/null || true

            echo_success "✓ Cleaned up $ns namespace"
        else
            echo_info "Namespace $ns does not exist, skipping"
        fi
    done
}

# Function to delete Authorino components
cleanup_authorino() {
    echo_header "CLEANING UP AUTHORINO COMPONENTS"

    local namespaces="authorino authorino-operator"

    for ns in $namespaces; do
        if oc get namespace "$ns" >/dev/null 2>&1; then
            echo_info "Cleaning up namespace: $ns"

            # Delete operator subscription
            echo_info "  Deleting Authorino operator subscription..."
            oc delete subscription authorino-operator -n "$ns" 2>/dev/null || true

            # Delete operator group
            echo_info "  Deleting operator group..."
            oc delete operatorgroup --all -n "$ns" 2>/dev/null || true

            # Delete CSV
            echo_info "  Deleting ClusterServiceVersions..."
            oc delete csv -l operators.coreos.com/authorino-operator."$ns" -n "$ns" 2>/dev/null || true

            # Delete all resources
            echo_info "  Deleting all resources..."
            oc delete all --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete namespace
            echo_info "  Deleting namespace: $ns"
            oc delete namespace "$ns" --timeout=120s 2>/dev/null || true

            echo_success "✓ Cleaned up $ns namespace"
        else
            echo_info "Namespace $ns does not exist, skipping"
        fi
    done
}

# Function to delete Strimzi/Kafka components
cleanup_kafka() {
    echo_header "CLEANING UP KAFKA/STRIMZI COMPONENTS"

    local namespaces="kafka strimzi"

    for ns in $namespaces; do
        if oc get namespace "$ns" >/dev/null 2>&1; then
            echo_info "Cleaning up namespace: $ns"

            # Delete Kafka resources
            echo_info "  Deleting Kafka resources..."
            oc delete kafka --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete Kafka topics
            echo_info "  Deleting Kafka topics..."
            oc delete kafkatopic --all -n "$ns" --timeout=30s 2>/dev/null || true

            # Delete Kafka users
            echo_info "  Deleting Kafka users..."
            oc delete kafkauser --all -n "$ns" --timeout=30s 2>/dev/null || true

            # Delete operator subscription
            echo_info "  Deleting Strimzi operator subscription..."
            oc delete subscription strimzi-kafka-operator -n "$ns" 2>/dev/null || true

            # Delete operator group
            echo_info "  Deleting operator group..."
            oc delete operatorgroup --all -n "$ns" 2>/dev/null || true

            # Delete CSV
            echo_info "  Deleting ClusterServiceVersions..."
            oc delete csv -l operators.coreos.com/strimzi-kafka-operator."$ns" -n "$ns" 2>/dev/null || true

            # Delete PVCs
            echo_info "  Deleting PVCs..."
            oc delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true

            # Delete namespace
            echo_info "  Deleting namespace: $ns"
            oc delete namespace "$ns" --timeout=120s 2>/dev/null || true

            echo_success "✓ Cleaned up $ns namespace"
        else
            echo_info "Namespace $ns does not exist, skipping"
        fi
    done
}

# Function to cleanup CRDs related to our deployments
cleanup_crds() {
    echo_header "CLEANING UP CUSTOM RESOURCE DEFINITIONS (CRDs)"

    # List of CRD patterns to remove
    local crd_patterns=(
        "keycloak"
        "kafka"
        "strimzi"
        "authorino"
        "kruize"
        "costmanagement"
        "koku"
    )

    echo_info "Searching for CRDs related to deployed operators..."

    for pattern in "${crd_patterns[@]}"; do
        local crds=$(oc get crd -o name 2>/dev/null | grep -i "$pattern" || true)

        if [ -n "$crds" ]; then
            echo_info "Found CRDs matching '$pattern':"
            while IFS= read -r crd; do
                if [ -n "$crd" ]; then
                    local crd_name=$(echo "$crd" | cut -d'/' -f2)
                    echo_info "  Deleting CRD: $crd_name"
                    oc delete "$crd" --timeout=60s 2>/dev/null || echo_warning "    Failed to delete $crd_name"
                fi
            done <<< "$crds"
        fi
    done

    echo_success "✓ CRD cleanup completed"
}

# Function to cleanup ClusterRoles and ClusterRoleBindings
cleanup_cluster_roles() {
    echo_header "CLEANING UP CLUSTER ROLES AND BINDINGS"

    # List of ClusterRole patterns to remove
    local role_patterns=(
        "keycloak"
        "rhbk"
        "kafka"
        "strimzi"
        "authorino"
        "kruize"
        "cost-management"
        "koku"
    )

    echo_info "Searching for ClusterRoles related to deployed operators..."

    for pattern in "${role_patterns[@]}"; do
        # Clean up ClusterRoles
        local cluster_roles=$(oc get clusterrole -o name 2>/dev/null | grep -i "$pattern" || true)

        if [ -n "$cluster_roles" ]; then
            echo_info "Found ClusterRoles matching '$pattern':"
            while IFS= read -r role; do
                if [ -n "$role" ]; then
                    local role_name=$(echo "$role" | cut -d'/' -f2)
                    echo_info "  Deleting ClusterRole: $role_name"
                    oc delete "$role" --timeout=30s 2>/dev/null || echo_warning "    Failed to delete $role_name"
                fi
            done <<< "$cluster_roles"
        fi

        # Clean up ClusterRoleBindings
        local cluster_role_bindings=$(oc get clusterrolebinding -o name 2>/dev/null | grep -i "$pattern" || true)

        if [ -n "$cluster_role_bindings" ]; then
            echo_info "Found ClusterRoleBindings matching '$pattern':"
            while IFS= read -r binding; do
                if [ -n "$binding" ]; then
                    local binding_name=$(echo "$binding" | cut -d'/' -f2)
                    echo_info "  Deleting ClusterRoleBinding: $binding_name"
                    oc delete "$binding" --timeout=30s 2>/dev/null || echo_warning "    Failed to delete $binding_name"
                fi
            done <<< "$cluster_role_bindings"
        fi
    done

    echo_success "✓ ClusterRole and ClusterRoleBinding cleanup completed"
}

# Function to cleanup webhooks
cleanup_webhooks() {
    echo_header "CLEANING UP WEBHOOKS"

    # List of webhook patterns to remove
    local webhook_patterns=(
        "keycloak"
        "kafka"
        "strimzi"
        "authorino"
        "kruize"
    )

    echo_info "Searching for webhooks related to deployed operators..."

    for pattern in "${webhook_patterns[@]}"; do
        # Clean up MutatingWebhookConfigurations
        local mutating_webhooks=$(oc get mutatingwebhookconfiguration -o name 2>/dev/null | grep -i "$pattern" || true)

        if [ -n "$mutating_webhooks" ]; then
            echo_info "Found MutatingWebhookConfigurations matching '$pattern':"
            while IFS= read -r webhook; do
                if [ -n "$webhook" ]; then
                    local webhook_name=$(echo "$webhook" | cut -d'/' -f2)
                    echo_info "  Deleting MutatingWebhook: $webhook_name"
                    oc delete "$webhook" --timeout=30s 2>/dev/null || true
                fi
            done <<< "$mutating_webhooks"
        fi

        # Clean up ValidatingWebhookConfigurations
        local validating_webhooks=$(oc get validatingwebhookconfiguration -o name 2>/dev/null | grep -i "$pattern" || true)

        if [ -n "$validating_webhooks" ]; then
            echo_info "Found ValidatingWebhookConfigurations matching '$pattern':"
            while IFS= read -r webhook; do
                if [ -n "$webhook" ]; then
                    local webhook_name=$(echo "$webhook" | cut -d'/' -f2)
                    echo_info "  Deleting ValidatingWebhook: $webhook_name"
                    oc delete "$webhook" --timeout=30s 2>/dev/null || true
                fi
            done <<< "$validating_webhooks"
        fi
    done

    echo_success "✓ Webhook cleanup completed"
}

# Function to cleanup remaining operator resources
cleanup_operator_resources() {
    echo_header "CLEANING UP OPERATOR RESOURCES"

    # Clean up any remaining CSVs
    echo_info "Cleaning up ClusterServiceVersions..."
    local csvs=$(oc get csv -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | grep -E "(keycloak|rhbk|kafka|strimzi|authorino|kruize)" || true)

    if [ -n "$csvs" ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local ns=$(echo "$line" | awk '{print $1}')
                local csv=$(echo "$line" | awk '{print $2}')
                echo_info "  Deleting CSV: $csv in namespace $ns"
                oc delete csv "$csv" -n "$ns" --timeout=30s 2>/dev/null || true
            fi
        done <<< "$csvs"
    fi

    # Clean up InstallPlans
    echo_info "Cleaning up InstallPlans..."
    local install_plans=$(oc get installplan -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | grep -E "(keycloak|rhbk|kafka|strimzi|authorino|kruize)" || true)

    if [ -n "$install_plans" ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local ns=$(echo "$line" | awk '{print $1}')
                local plan=$(echo "$line" | awk '{print $2}')
                echo_info "  Deleting InstallPlan: $plan in namespace $ns"
                oc delete installplan "$plan" -n "$ns" --timeout=30s 2>/dev/null || true
            fi
        done <<< "$install_plans"
    fi

    echo_success "✓ Operator resource cleanup completed"
}

# Function to clean up container images from nodes
cleanup_images_from_nodes() {
    echo_header "CLEANING UP CONTAINER IMAGES FROM NODES"

    echo_info "This will remove unused container images from all nodes"
    echo_warning "This operation requires debug pods with privileged access"

    # Get all nodes
    local nodes=$(oc get nodes -o name 2>/dev/null | cut -d'/' -f2)

    if [ -z "$nodes" ]; then
        echo_warning "No nodes found or unable to list nodes"
        return 1
    fi

    echo_info "Found nodes: $(echo "$nodes" | wc -l | tr -d ' ')"

    # Create a cleanup script that will run on each node
    local cleanup_script='#!/bin/bash
echo "Cleaning up container images on node: $(hostname)"

# For CRI-O (OpenShift default)
if command -v crictl >/dev/null 2>&1; then
    echo "Using crictl to clean up images..."

    # Remove unused images
    crictl rmi --prune 2>/dev/null || true

    # List and remove specific images related to our deployment
    images_to_remove=$(crictl images | grep -E "(koku|kruize|keycloak|postgres|kafka|zookeeper|sources|authorino)" | awk "{print \$3}" || true)

    if [ -n "$images_to_remove" ]; then
        echo "Removing specific images:"
        echo "$images_to_remove" | while read -r img; do
            if [ -n "$img" ]; then
                echo "  Removing: $img"
                crictl rmi "$img" 2>/dev/null || true
            fi
        done
    fi

    echo "Image cleanup completed on $(hostname)"
else
    echo "crictl not found, skipping image cleanup on $(hostname)"
fi
'

    # Run cleanup on each node using debug pod
    while IFS= read -r node; do
        if [ -n "$node" ]; then
            echo_info "Cleaning images on node: $node"

            # Create a temporary file for the cleanup script
            local temp_script="/tmp/cleanup-images-${node}.sh"
            echo "$cleanup_script" > "$temp_script"

            # Run debug pod on the node to clean up images
            # Using --quiet to reduce output noise
            oc debug node/"$node" --quiet -- bash -c "$cleanup_script" 2>/dev/null || {
                echo_warning "  Failed to clean images on $node (this is often normal if debug pods are restricted)"
            }

            rm -f "$temp_script" 2>/dev/null || true
        fi
    done <<< "$nodes"

    echo_success "✓ Container image cleanup completed (or attempted) on all nodes"
    echo_info "Note: Some images may still be in use and couldn't be removed"
}

# Function to force remove stuck namespaces
force_remove_stuck_namespaces() {
    echo_header "CHECKING FOR STUCK NAMESPACES"

    local stuck_namespaces=$(oc get namespace | grep Terminating | awk '{print $1}' || true)

    if [ -z "$stuck_namespaces" ]; then
        echo_info "No stuck namespaces found"
        return 0
    fi

    echo_warning "Found stuck namespaces in Terminating state:"
    echo "$stuck_namespaces"

    echo_info "Attempting to force remove stuck namespaces..."

    while IFS= read -r ns; do
        if [ -n "$ns" ]; then
            echo_info "  Force removing namespace: $ns"

            # Remove finalizers
            oc patch namespace "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true

            # Try to delete again
            oc delete namespace "$ns" --timeout=30s 2>/dev/null || true
        fi
    done <<< "$stuck_namespaces"

    echo_success "✓ Attempted to force remove stuck namespaces"
}

# Function to display cleanup summary
display_summary() {
    echo_header "CLEANUP SUMMARY"

    # Check remaining namespaces
    local remaining_ns=$(oc get namespaces -o name 2>/dev/null | grep -E "(cost-mgmt|keycloak|kruize|sources|authorino|kafka)" || true)

    if [ -z "$remaining_ns" ]; then
        echo_success "✓ All target namespaces have been removed"
    else
        echo_warning "⚠ Some namespaces still exist:"
        echo "$remaining_ns"
        echo_info "These may be in Terminating state or have finalizers preventing deletion"
    fi

    # Check for any remaining PVCs
    local remaining_pvcs=$(oc get pvc -A 2>/dev/null | grep -E "(cost-mgmt|keycloak|kruize|sources|kafka)" || true)

    if [ -z "$remaining_pvcs" ]; then
        echo_success "✓ All target PVCs have been removed"
    else
        echo_warning "⚠ Some PVCs still exist:"
        echo "$remaining_pvcs"
    fi

    echo ""
    echo_info "Next Steps:"
    echo_info "  1. Verify cluster is clean: kubectl get ns"
    echo_info "  2. Check for stuck resources: kubectl get pvc -A"
    echo_info "  3. Run new installation scripts to test clean deployment"
    echo ""
    echo_success "Cleanup process completed!"
}

# Main execution function
main() {
    echo_header "COMPREHENSIVE CLEANUP SCRIPT"
    echo_warning "This script will remove ALL Cost Management and related components"
    echo_warning "Including: RHBK, Keycloak, Cost Management, Kruize, Sources, Authorino, Kafka"
    echo_warning "And will attempt to clean container images from nodes"
    echo ""
    echo_warning "This operation is DESTRUCTIVE and IRREVERSIBLE!"
    echo ""
    echo -n "Are you sure you want to proceed? (yes/no): "
    read -r confirmation

    if [ "$confirmation" != "yes" ]; then
        echo_info "Cleanup cancelled"
        exit 0
    fi

    echo ""
    echo_info "Starting cleanup process..."

    # Execute cleanup steps
    check_prerequisites
    cleanup_helm_releases
    cleanup_cost_management
    cleanup_rhbk
    cleanup_kruize
    cleanup_sources
    cleanup_authorino
    cleanup_kafka
    force_remove_stuck_namespaces
    cleanup_operator_resources
    cleanup_webhooks
    cleanup_cluster_roles
    cleanup_crds

    # Optional: Cleanup images (can take a long time)
    echo ""
    echo_warning "Container image cleanup can take several minutes and requires privileged access"
    echo -n "Do you want to clean container images from nodes? (yes/no): "
    read -r cleanup_images

    if [ "$cleanup_images" = "yes" ]; then
        cleanup_images_from_nodes
    else
        echo_info "Skipping container image cleanup"
    fi

    # Display summary
    display_summary
}

# Handle script arguments
case "${1:-}" in
    "help"|"-h"|"--help")
        echo "Usage: $0 [command]"
        echo ""
        echo "This script performs a comprehensive cleanup of all Cost Management"
        echo "and related components from an OpenShift cluster."
        echo ""
        echo "Components removed:"
        echo "  - Cost Management (koku, masu, workers)"
        echo "  - RHBK/Keycloak (SSO)"
        echo "  - Kruize/Autotune (optimization)"
        echo "  - Sources API"
        echo "  - Authorino (auth)"
        echo "  - Kafka/Strimzi (messaging)"
        echo "  - Container images (optional)"
        echo ""
        echo "Commands:"
        echo "  (no command)    Run full cleanup (interactive)"
        echo "  help            Show this help message"
        echo ""
        echo "Examples:"
        echo "  # Interactive cleanup"
        echo "  $0"
        echo ""
        echo "  # Show help"
        echo "  $0 help"
        echo ""
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

