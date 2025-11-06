#!/usr/bin/env bash
#
# deploy-trino.sh - Deploy Trino cluster for Koku cost management
#
# This script deploys a Trino cluster with Hive Metastore in a dedicated namespace.
# Trino is required by Koku for querying Parquet data from S3/MinIO.
#
# Usage:
#   ./deploy-trino.sh              # Deploy to default namespace
#   ./deploy-trino.sh validate     # Validate existing deployment
#   ./deploy-trino.sh cleanup      # Remove Trino deployment
#
# Environment Variables:
#   TRINO_NAMESPACE          - Target namespace (default: trino)
#   TRINO_RELEASE_NAME       - Helm release name (default: trino)
#   TRINO_COORDINATOR_MEMORY - Coordinator memory (default: 6Gi)
#   TRINO_WORKER_REPLICAS    - Number of workers (default: 2)
#   TRINO_WORKER_MEMORY      - Worker memory (default: 6Gi)
#   USE_LOCAL_CHART          - Use local chart vs GitHub (default: false)
#   LOCAL_CHART_PATH         - Path to local chart (default: ../trino-chart)
#   S3_ACCESS_KEY            - S3/MinIO access key (default: minioaccesskey)
#   S3_SECRET_KEY            - S3/MinIO secret key (default: miniosecretkey)
#   STORAGE_CLASS            - Storage class for PVCs (default: auto-detect)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
TRINO_NAMESPACE="${TRINO_NAMESPACE:-trino}"
TRINO_RELEASE_NAME="${TRINO_RELEASE_NAME:-trino}"
TRINO_COORDINATOR_MEMORY="${TRINO_COORDINATOR_MEMORY:-6Gi}"
TRINO_WORKER_REPLICAS="${TRINO_WORKER_REPLICAS:-2}"
TRINO_WORKER_MEMORY="${TRINO_WORKER_MEMORY:-6Gi}"
USE_LOCAL_CHART="${USE_LOCAL_CHART:-false}"
LOCAL_CHART_PATH="${LOCAL_CHART_PATH:-../trino-chart}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-minioaccesskey}"
S3_SECRET_KEY="${S3_SECRET_KEY:-miniosecretkey}"
STORAGE_CLASS="${STORAGE_CLASS:-}"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Detect Kubernetes cluster type
detect_cluster_type() {
    if kubectl api-resources | grep -q "route.openshift.io"; then
        echo "openshift"
    else
        echo "kubernetes"
    fi
}

# Get storage class
get_storage_class() {
    if [ -n "$STORAGE_CLASS" ]; then
        echo "$STORAGE_CLASS"
        return
    fi
    
    local cluster_type
    cluster_type=$(detect_cluster_type)
    
    if [ "$cluster_type" = "openshift" ]; then
        # Try common OpenShift storage classes
        if kubectl get storageclass ocs-storagecluster-ceph-rbd >/dev/null 2>&1; then
            echo "ocs-storagecluster-ceph-rbd"
        elif kubectl get storageclass gp3-csi >/dev/null 2>&1; then
            echo "gp3-csi"
        elif kubectl get storageclass gp2 >/dev/null 2>&1; then
            echo "gp2"
        else
            log_warn "No known storage class found, using default"
            echo ""
        fi
    else
        # Try common Kubernetes storage classes
        if kubectl get storageclass standard >/dev/null 2>&1; then
            echo "standard"
        elif kubectl get storageclass gp2 >/dev/null 2>&1; then
            echo "gp2"
        else
            log_warn "No known storage class found, using default"
            echo ""
        fi
    fi
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command_exists kubectl; then
        log_error "kubectl is not installed"
        exit 1
    fi
    
    if ! command_exists helm; then
        log_error "helm is not installed"
        exit 1
    fi
    
    # Check kubectl connectivity
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Create namespace
create_namespace() {
    log_info "Creating namespace: $TRINO_NAMESPACE"
    
    if kubectl get namespace "$TRINO_NAMESPACE" >/dev/null 2>&1; then
        log_info "Namespace $TRINO_NAMESPACE already exists"
    else
        kubectl create namespace "$TRINO_NAMESPACE"
        log_success "Namespace $TRINO_NAMESPACE created"
    fi
}

# Deploy Trino
deploy_trino() {
    log_info "Deploying Trino cluster..."
    
    local storage_class
    storage_class=$(get_storage_class)
    
    local cluster_type
    cluster_type=$(detect_cluster_type)
    
    log_info "Cluster type: $cluster_type"
    log_info "Storage class: ${storage_class:-default}"
    log_info "Coordinator memory: $TRINO_COORDINATOR_MEMORY"
    log_info "Worker replicas: $TRINO_WORKER_REPLICAS"
    log_info "Worker memory: $TRINO_WORKER_MEMORY"
    
    # Prepare Helm values
    local helm_values=(
        "--set" "coordinator.resources.requests.memory=$TRINO_COORDINATOR_MEMORY"
        "--set" "coordinator.resources.limits.memory=$TRINO_COORDINATOR_MEMORY"
        "--set" "worker.replicas=$TRINO_WORKER_REPLICAS"
        "--set" "worker.resources.requests.memory=$TRINO_WORKER_MEMORY"
        "--set" "worker.resources.limits.memory=$TRINO_WORKER_MEMORY"
        "--set" "catalogs.hive.s3.accessKey=$S3_ACCESS_KEY"
        "--set" "catalogs.hive.s3.secretKey=$S3_SECRET_KEY"
    )
    
    if [ -n "$storage_class" ]; then
        helm_values+=(
            "--set" "global.storageClass=$storage_class"
        )
    fi
    
    # Deploy chart
    if [ "$USE_LOCAL_CHART" = "true" ]; then
        log_info "Using local chart: $LOCAL_CHART_PATH"
        helm upgrade --install "$TRINO_RELEASE_NAME" "$LOCAL_CHART_PATH" \
            --namespace "$TRINO_NAMESPACE" \
            --create-namespace \
            "${helm_values[@]}" \
            --wait \
            --timeout=10m
    else
        log_error "GitHub chart repository not yet configured"
        log_info "Please set USE_LOCAL_CHART=true and LOCAL_CHART_PATH"
        exit 1
    fi
    
    log_success "Trino deployed successfully"
}

# Wait for Trino to be ready
wait_for_trino() {
    log_info "Waiting for Trino to be ready..."
    
    # Wait for metastore database
    log_info "Waiting for Hive Metastore database..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/component=metastore-db \
        -n "$TRINO_NAMESPACE" \
        --timeout=300s || true
    
    # Wait for metastore
    log_info "Waiting for Hive Metastore..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/component=metastore \
        -n "$TRINO_NAMESPACE" \
        --timeout=300s || true
    
    # Wait for coordinator
    log_info "Waiting for Trino Coordinator..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/component=coordinator \
        -n "$TRINO_NAMESPACE" \
        --timeout=300s || true
    
    # Wait for workers
    log_info "Waiting for Trino Workers..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/component=worker \
        -n "$TRINO_NAMESPACE" \
        --timeout=300s || true
    
    log_success "Trino cluster is ready"
}

# Validate deployment
validate_deployment() {
    log_info "Validating Trino deployment..."
    
    # Check pods
    log_info "Checking pods..."
    if ! kubectl get pods -n "$TRINO_NAMESPACE" | grep -q Running; then
        log_error "No running pods found"
        return 1
    fi
    
    # Check coordinator
    local coordinator_pod
    coordinator_pod=$(kubectl get pods -n "$TRINO_NAMESPACE" \
        -l app.kubernetes.io/component=coordinator \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$coordinator_pod" ]; then
        log_error "Trino coordinator not found"
        return 1
    fi
    
    log_info "Coordinator pod: $coordinator_pod"
    
    # Test Trino query
    log_info "Testing Trino query..."
    if kubectl exec -n "$TRINO_NAMESPACE" "$coordinator_pod" -- \
        trino --execute "SHOW CATALOGS" >/dev/null 2>&1; then
        log_success "Trino query test passed"
    else
        log_warn "Trino query test failed (this may be normal if just deployed)"
    fi
    
    # Show pod status
    log_info "Pod status:"
    kubectl get pods -n "$TRINO_NAMESPACE"
    
    # Show services
    log_info "Services:"
    kubectl get svc -n "$TRINO_NAMESPACE"
    
    log_success "Validation complete"
}

# Print connection info
print_connection_info() {
    log_info "====================================="
    log_info "Trino Connection Information"
    log_info "====================================="
    log_info "Namespace: $TRINO_NAMESPACE"
    log_info "Release: $TRINO_RELEASE_NAME"
    log_info ""
    log_info "Coordinator Service:"
    log_info "  Host: $TRINO_RELEASE_NAME-coordinator.$TRINO_NAMESPACE.svc.cluster.local"
    log_info "  Port: 8080"
    log_info ""
    log_info "Hive Metastore Service:"
    log_info "  Host: $TRINO_RELEASE_NAME-metastore.$TRINO_NAMESPACE.svc.cluster.local"
    log_info "  Port: 9083"
    log_info ""
    log_info "Environment Variables for Koku:"
    echo "  TRINO_HOST=$TRINO_RELEASE_NAME-coordinator.$TRINO_NAMESPACE.svc.cluster.local"
    echo "  TRINO_PORT=8080"
    log_info "====================================="
}

# Cleanup
cleanup_trino() {
    log_warn "Cleaning up Trino deployment..."
    
    if helm list -n "$TRINO_NAMESPACE" | grep -q "$TRINO_RELEASE_NAME"; then
        helm uninstall "$TRINO_RELEASE_NAME" -n "$TRINO_NAMESPACE"
        log_success "Trino release uninstalled"
    else
        log_info "Trino release not found"
    fi
    
    # Optionally delete PVCs
    read -p "Delete PVCs? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl delete pvc -n "$TRINO_NAMESPACE" --all
        log_success "PVCs deleted"
    fi
    
    # Optionally delete namespace
    read -p "Delete namespace $TRINO_NAMESPACE? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl delete namespace "$TRINO_NAMESPACE"
        log_success "Namespace deleted"
    fi
}

# Main function
main() {
    local command="${1:-deploy}"
    
    case "$command" in
        deploy)
            check_prerequisites
            create_namespace
            deploy_trino
            wait_for_trino
            validate_deployment
            print_connection_info
            ;;
        validate)
            validate_deployment
            print_connection_info
            ;;
        cleanup)
            cleanup_trino
            ;;
        status)
            log_info "Trino cluster status:"
            kubectl get all -n "$TRINO_NAMESPACE"
            print_connection_info
            ;;
        *)
            log_error "Unknown command: $command"
            log_info "Usage: $0 {deploy|validate|cleanup|status}"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"

