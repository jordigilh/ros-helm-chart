#!/bin/bash
# trigger-data-processing.sh
# Quick manual trigger for MASU data processing
# Use this to validate Koku changes immediately

set -e

NAMESPACE="${NAMESPACE:-cost-mgmt}"
TIMEOUT="${TIMEOUT:-300}"  # 5 minutes default

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

echo ""
echo "🚀 MASU Data Processing - Manual Trigger"
echo "=========================================="
echo ""

# Check if provider exists
info "Checking for provider..."
MASU_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=masu -o name 2>/dev/null | head -1 | sed 's|pod/||')

if [ -z "$MASU_POD" ]; then
    error "MASU pod not found in namespace: $NAMESPACE"
    exit 1
fi

PROVIDER_COUNT=$(kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python3 -c "
import os, sys, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'koku.settings')
sys.path.append('/opt/koku/koku')
django.setup()
from api.models import Provider
print(Provider.objects.count())
" 2>/dev/null | tail -1)

if [ "$PROVIDER_COUNT" -eq 0 ]; then
    error "No providers found. Run e2e-validate-cost-management.sh first."
    exit 1
fi

success "Found $PROVIDER_COUNT provider(s)"

# Trigger download task
info "Triggering download task..."

TASK_ID=$(kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python3 -c "
import os, sys, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'koku.settings')
sys.path.append('/opt/koku/koku')
django.setup()
from masu.celery.tasks import check_report_updates
result = check_report_updates.delay()
print(result.id)
" 2>/dev/null | tail -1)

if [ ! -z "$TASK_ID" ]; then
    success "Task triggered: $TASK_ID"
else
    error "Failed to trigger task"
    exit 1
fi

# Monitor for results
info "Monitoring manifest processing (timeout: ${TIMEOUT}s)..."
echo ""

START_TIME=$(date +%s)
INTERVAL=10
LAST_COUNT=0

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo ""
        warning "Timeout reached (${TIMEOUT}s)"
        break
    fi

    # Check manifest count
    MANIFEST_COUNT=$(kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python3 -c "
import os, sys, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'koku.settings')
sys.path.append('/opt/koku/koku')
django.setup()
from reporting_common.models import CostUsageReportManifest
print(CostUsageReportManifest.objects.count())
" 2>/dev/null | tail -1)

    if [ "$MANIFEST_COUNT" != "$LAST_COUNT" ]; then
        echo ""
        success "Manifests in database: $MANIFEST_COUNT (${ELAPSED}s elapsed)"
        LAST_COUNT=$MANIFEST_COUNT

        if [ "$MANIFEST_COUNT" -gt 0 ]; then
            echo ""
            success "✅ Data processing started!"

            # Show manifest details
            info "Manifest details:"
            kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python3 -c "
import os, sys, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'koku.settings')
sys.path.append('/opt/koku/koku')
django.setup()
from reporting_common.models import CostUsageReportManifest
for m in CostUsageReportManifest.objects.all()[:5]:
    print(f'  - ID: {m.manifest_id[:20]}... | Period: {m.billing_period_start_datetime} | Files: {m.num_total_files}')
" 2>/dev/null | grep "^  -"

            break
        fi
    fi

    # Progress indicator
    echo -n "."
    sleep $INTERVAL
done

echo ""
echo ""

# Check Trino tables
info "Checking Trino tables..."

TRINO_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=trino-coordinator -o name 2>/dev/null | head -1 | sed 's|pod/||')

if [ ! -z "$TRINO_POD" ]; then
    # Get list of schemas
    SCHEMAS=$(kubectl exec -n "$NAMESPACE" "$TRINO_POD" -- /usr/bin/trino --execute "SHOW SCHEMAS FROM hive;" 2>/dev/null | grep "org" || true)

    if [ ! -z "$SCHEMAS" ]; then
        for schema in $SCHEMAS; do
            TABLE_COUNT=$(kubectl exec -n "$NAMESPACE" "$TRINO_POD" -- /usr/bin/trino --execute "SHOW TABLES FROM hive.$schema;" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$TABLE_COUNT" -gt 0 ]; then
                success "Schema: hive.$schema - $TABLE_COUNT tables"
            fi
        done
    else
        warning "No tenant schemas found yet"
    fi
else
    warning "Trino pod not available"
fi

echo ""
echo "=========================================="
echo ""

# Final status
if [ "$MANIFEST_COUNT" -gt 0 ]; then
    success "🎉 Data processing pipeline initiated!"
    echo ""
    echo "Next steps:"
    echo "  1. Wait 2-3 minutes for full processing"
    echo "  2. Check Celery logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=celery-worker-default -f"
    echo "  3. Query API: curl http://localhost:8000/api/cost-management/v1/reports/aws/costs/"
    echo "  4. Run IQE tests to validate results"
    echo ""
    exit 0
else
    warning "No manifests created yet. Check:"
    echo "  - MASU logs: kubectl logs -n $NAMESPACE $MASU_POD"
    echo "  - Celery worker logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=celery"
    echo "  - Provider configuration"
    echo ""
    exit 1
fi

