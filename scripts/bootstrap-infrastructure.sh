#!/bin/bash
# =============================================================================
# Cost Management Infrastructure Bootstrap Script
# =============================================================================
# This script deploys and initializes the infrastructure components for
# Cost Management (PostgreSQL) and runs database migrations.
#
# Usage:
#   ./bootstrap-infrastructure.sh --namespace <namespace> [options]
#
# Options:
#   --namespace <name>      Kubernetes namespace (required)
#   --release-name <name>   Helm release name (default: cost-mgmt-infra)
#   --skip-deploy          Skip infrastructure deployment
#   --skip-migrations      Skip database migrations
#   --migration-image <img> Custom Koku image for migrations
#   --help                 Show this help message
# =============================================================================

set -e
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Default values
NAMESPACE=""
RELEASE_NAME="cost-mgmt-infra"
SKIP_DEPLOY=false
SKIP_MIGRATIONS=false
MIGRATION_IMAGE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_CHART_DIR="$(dirname "$SCRIPT_DIR")/cost-management-infrastructure"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --release-name)
            RELEASE_NAME="$2"
            shift 2
            ;;
        --skip-deploy)
            SKIP_DEPLOY=true
            shift
            ;;
        --skip-migrations)
            SKIP_MIGRATIONS=true
            shift
            ;;
        --migration-image)
            MIGRATION_IMAGE="$2"
            shift 2
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

log_info "Cost Management Infrastructure Bootstrap"
log_info "========================================"
log_info "Namespace: $NAMESPACE"
log_info "Release: $RELEASE_NAME"
log_info ""

# =============================================================================
# Step 1: Deploy Infrastructure Chart
# =============================================================================
if [ "$SKIP_DEPLOY" = false ]; then
    log_info "Step 1: Deploying infrastructure chart..."

    if [ ! -d "$INFRA_CHART_DIR" ]; then
        log_error "Infrastructure chart not found at: $INFRA_CHART_DIR"
        exit 1
    fi

    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        log_info "Creating namespace: $NAMESPACE"
        kubectl create namespace "$NAMESPACE"
    fi

    # Deploy infrastructure chart
    log_info "Deploying PostgreSQL..."
    helm upgrade --install "$RELEASE_NAME" "$INFRA_CHART_DIR" \
        --namespace "$NAMESPACE" \
        --wait \
        --timeout=10m

    log_success "Infrastructure deployed"
else
    log_warning "Skipping infrastructure deployment"
fi

# =============================================================================
# Step 2: Wait for PostgreSQL to be ready
# =============================================================================
log_info "Step 2: Waiting for PostgreSQL to be ready..."

POD_NAME="postgres-0"
MAX_ATTEMPTS=60
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if kubectl get pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        POD_STATUS=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
        if [ "$POD_STATUS" = "Running" ]; then
            # Test database connectivity
            if kubectl exec "$POD_NAME" -n "$NAMESPACE" -- psql -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
                log_success "PostgreSQL is ready"
                break
            fi
        fi
    fi

    ATTEMPT=$((ATTEMPT + 1))
    log_info "Waiting for PostgreSQL... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
    sleep 5
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    log_error "PostgreSQL did not become ready in time"
    exit 1
fi

# =============================================================================
# Step 3: Initialize Database
# =============================================================================
log_info "Step 3: Initializing database..."

# Get database credentials from secret
SECRET_NAME="postgres-credentials"
KOKU_DB_NAME=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.database}' | base64 -d)
KOKU_DB_USER=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
KOKU_DB_PASSWORD=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

# Ensure koku user password is set correctly
log_info "Setting password for database user: $KOKU_DB_USER..."
kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
    psql -U postgres -d postgres -c "ALTER USER $KOKU_DB_USER WITH PASSWORD '$KOKU_DB_PASSWORD';" 2>&1 || {
    log_error "Failed to set password for user $KOKU_DB_USER"
    exit 1
}
log_success "Password set for user: $KOKU_DB_USER"

log_info "Creating pg_stat_statements extension on database: $KOKU_DB_NAME..."
kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
    psql -U postgres -d "$KOKU_DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>&1 || \
    log_warning "Extension may already exist"

log_info "Creating hive role..."
ROLE_EXISTS=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
    psql -U postgres -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='hive';" | tr -d '[:space:]')

if [ "$ROLE_EXISTS" = "1" ]; then
    log_info "Hive role already exists"
else
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        psql -U postgres -d postgres -c "CREATE ROLE hive WITH LOGIN PASSWORD 'hive';" 2>&1 | grep -q "CREATE ROLE\|already exists" || {
        log_error "Failed to create hive role"
        exit 1
    }
    log_success "Hive role created"
fi

# Create hive database
log_info "Creating hive database..."
DB_EXISTS=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
    psql -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='hive';" | tr -d '[:space:]')

if [ "$DB_EXISTS" = "1" ]; then
    log_info "Hive database already exists"
else
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        psql -U postgres -d postgres -c "CREATE DATABASE hive OWNER hive;" 2>&1 | grep -q "CREATE DATABASE\|already exists" || {
        log_error "Failed to create hive database"
        exit 1
    }
    log_success "Hive database created"
fi

log_success "Database initialization complete"

# =============================================================================
# Step 4: Run Database Migrations
# =============================================================================
if [ "$SKIP_MIGRATIONS" = false ]; then
    log_info "Step 4: Running database migrations..."

    # Get database credentials
    SECRET_NAME="postgres-credentials"
    DB_HOST="postgres"
    DB_PORT="5432"
    DB_NAME=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.database}' | base64 -d)
    DB_USER=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
    DB_PASSWORD=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

    # Determine migration image
    if [ -z "$MIGRATION_IMAGE" ]; then
        # Try to detect from existing deployment or use default
        MIGRATION_IMAGE="quay.io/project-koku/koku:latest"
        log_info "Using default migration image: $MIGRATION_IMAGE"
    else
        log_info "Using custom migration image: $MIGRATION_IMAGE"
    fi

    # Check if migrations are needed
    log_info "Checking if migrations are needed..."

    MIGRATION_CHECK=$(cat <<EOF
import os, sys, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'koku.settings')
os.environ['DATABASE_SERVICE_HOST'] = '$DB_HOST'
os.environ['DATABASE_SERVICE_PORT'] = '$DB_PORT'
os.environ['DATABASE_NAME'] = '$DB_NAME'
os.environ['DATABASE_USER'] = '$DB_USER'
os.environ['DATABASE_PASSWORD'] = '$DB_PASSWORD'
sys.path.append('/opt/koku/koku')
django.setup()
from django.core.management import execute_from_command_line
execute_from_command_line(['manage.py', 'showmigrations', '--plan'])
EOF
)

    # Create migration job
    MIGRATION_JOB="cost-mgmt-migration-$(date +%s)"

    log_info "Creating migration job: $MIGRATION_JOB"

    kubectl create job "$MIGRATION_JOB" \
        --image="$MIGRATION_IMAGE" \
        --namespace="$NAMESPACE" \
        -- bash -c "
        set -e
        export DATABASE_SERVICE_NAME='DATABASE'
        export DATABASE_SERVICE_HOST='$DB_HOST'
        export DATABASE_SERVICE_PORT='$DB_PORT'
        export DATABASE_ENGINE='postgresql'
        export DATABASE_NAME='$DB_NAME'
        export DATABASE_USER='$DB_USER'
        export DATABASE_PASSWORD='$DB_PASSWORD'
        export DJANGO_SECRET_KEY='migration-temp-key'
        export CLOWDER_ENABLED=False
        export DEVELOPMENT=False
        export PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus

        mkdir -p /tmp/prometheus
        cd /opt/koku/koku

        echo '=== Checking migrations status ==='
        python manage.py showmigrations --plan || true

        echo '=== Running migrations ==='
        python manage.py migrate --noinput

        echo '=== Migrations complete ==='
        "

    # Wait for migration job to complete
    log_info "Waiting for migrations to complete..."
    kubectl wait --for=condition=complete --timeout=10m job/"$MIGRATION_JOB" -n "$NAMESPACE" || {
        log_error "Migration job failed"
        log_info "Checking migration job logs..."
        kubectl logs job/"$MIGRATION_JOB" -n "$NAMESPACE" --tail=50
        exit 1
    }

    log_success "Migrations completed successfully"

    # Cleanup migration job
    kubectl delete job "$MIGRATION_JOB" -n "$NAMESPACE" --ignore-not-found=true

else
    log_warning "Skipping database migrations"
fi

# =============================================================================
# Step 5: Validate Setup
# =============================================================================
log_info "Step 5: Validating setup..."

# Check PostgreSQL is accessible
if kubectl exec "$POD_NAME" -n "$NAMESPACE" -- psql -U postgres -d "$DB_NAME" -c "SELECT COUNT(*) FROM django_migrations;" >/dev/null 2>&1; then
    log_success "Database is accessible and migrations table exists"
else
    log_warning "Could not verify migrations table"
fi

# Print summary
log_success "========================================"
log_success "Infrastructure Bootstrap Complete!"
log_success "========================================"
log_info ""
log_info "PostgreSQL Connection Details:"
log_info "  Host: $DB_HOST.$NAMESPACE.svc.cluster.local"
log_info "  Port: $DB_PORT"
log_info "  Database: $DB_NAME"
log_info "  User: $DB_USER"
log_info "  Secret: $SECRET_NAME"
log_info ""
log_info "Next Steps:"
log_info "  1. Deploy Cost Management application chart"
log_info "  2. Configure application to use external database:"
log_info "     --set costManagement.database.host=$DB_HOST"
log_info "     --set costManagement.database.port=$DB_PORT"
log_info "     --set costManagement.database.secretName=$SECRET_NAME"
log_info ""


log_info "  Secret: $SECRET_NAME"
log_info ""
log_info "Next Steps:"
log_info "  1. Deploy Cost Management application chart"
log_info "  2. Configure application to use external database:"
log_info "     --set costManagement.database.host=$DB_HOST"
log_info "     --set costManagement.database.port=$DB_PORT"
log_info "     --set costManagement.database.secretName=$SECRET_NAME"
log_info ""

