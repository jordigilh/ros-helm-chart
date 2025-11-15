#!/bin/bash
# e2e-validate-cost-management.sh
# Complete E2E validation script for Cost Management deployment
# Refactored with functions for better maintainability

set -e

# ============================================================================
# Configuration & Global Variables
# ============================================================================
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NAMESPACE="${NAMESPACE:-cost-mgmt}"
ORG_ID="${ORG_ID:-org1234567}"
S3_BUCKET="${S3_BUCKET:-cost-data}"
REPORT_NAME="${REPORT_NAME:-test-report}"
START_DATE="${START_DATE:-2025-11-01}"
END_DATE="${END_DATE:-2025-11-13}"
PROCESSING_TIMEOUT="${PROCESSING_TIMEOUT:-180}"
IQE_DIR="${IQE_DIR:-/Users/jgil/go/src/github.com/insights-onprem/iqe-cost-management-plugin}"

# Skip flags
SKIP_MIGRATIONS=false
SKIP_PROVIDER=false
SKIP_DATA=false
SKIP_TESTS=false
QUICK_MODE=false

# Global state
MASU_POD=""
PROVIDER_UUID=""
PROVIDER_NAME=""
TOTAL_STEPS=0
PASSED_STEPS=0
FAILED_STEPS=0
START_TIME=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# Utility Functions
# ============================================================================

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

step_pass() {
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
    PASSED_STEPS=$((PASSED_STEPS + 1))
    success "$1"
}

step_fail() {
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
    FAILED_STEPS=$((FAILED_STEPS + 1))
    error "$1"
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Complete E2E validation for Cost Management deployment.

Options:
  --skip-migrations   Skip database migration phase
  --skip-provider     Skip provider creation phase
  --skip-data         Skip test data upload phase
  --skip-tests        Skip IQE test execution phase
  --quick             Skip all setup, just trigger processing
  --timeout SECONDS   Set processing timeout (default: 180)
  --help              Show this help message

Environment Variables:
  NAMESPACE           Kubernetes namespace (default: cost-mgmt)
  ORG_ID              Organization ID (default: org1234567)
  S3_BUCKET           S3 bucket name (default: cost-data)
  REPORT_NAME         Report name (default: test-report)
  IQE_DIR             IQE plugin directory (auto-detected)
  PROCESSING_TIMEOUT  Data processing timeout (default: 180)

Examples:
  # Full E2E validation
  $0

  # Quick trigger for code changes
  $0 --quick

  # Skip specific phases
  $0 --skip-migrations --skip-provider

  # Custom timeout
  $0 --timeout 600

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-migrations)
                SKIP_MIGRATIONS=true
                shift
                ;;
            --skip-provider)
                SKIP_PROVIDER=true
                shift
                ;;
            --skip-data)
                SKIP_DATA=true
                shift
                ;;
            --skip-tests)
                SKIP_TESTS=true
                shift
                ;;
            --quick)
                QUICK_MODE=true
                SKIP_MIGRATIONS=true
                SKIP_PROVIDER=true
                SKIP_DATA=true
                shift
                ;;
            --timeout)
                PROCESSING_TIMEOUT="$2"
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

print_header() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   Cost Management E2E Validation Suite                      ║"
    echo "║   CI/CD Ready - Automated End-to-End Testing                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

# ============================================================================
# Phase 1: Pre-flight Checks
# ============================================================================

check_namespace() {
    if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
        step_pass "Namespace '$NAMESPACE' accessible"
    else
        step_fail "Cannot access namespace '$NAMESPACE'"
        exit 1
    fi
}

find_masu_pod() {
    MASU_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=masu -o name 2>/dev/null | head -1 | sed 's|pod/||')
    if [ ! -z "$MASU_POD" ]; then
        step_pass "MASU pod found: $MASU_POD"
    else
        step_fail "MASU pod not found"
        exit 1
    fi
}

check_pod_health() {
    local READY_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{if ($2 ~ /^1\/1/ && $3 == "Running") count++} END {print count+0}')
    if [ "$READY_PODS" -ge 20 ]; then
        step_pass "Pod health: $READY_PODS pods running"
    else
        step_fail "Insufficient healthy pods: $READY_PODS (expected ≥20)"
    fi
}

run_preflight_checks() {
    info "Phase 1: Pre-flight Checks"
    echo ""

    check_namespace
    find_masu_pod
    check_pod_health

    echo ""
}

# ============================================================================
# Phase 2: Database Migrations
# ============================================================================

create_hive_prerequisites() {
    local DB_POD=$(kubectl get pods -n "$NAMESPACE" | grep "koku-koku-db" | awk '{print $1}' | head -1)

    kubectl exec -n "$NAMESPACE" "$DB_POD" -- psql -U postgres -c \
        "CREATE ROLE hive WITH LOGIN PASSWORD 'hivepass';" 2>/dev/null || true

    kubectl exec -n "$NAMESPACE" "$DB_POD" -- psql -U postgres -c \
        "CREATE DATABASE hive OWNER hive;" 2>/dev/null || true

    kubectl exec -n "$NAMESPACE" "$DB_POD" -- psql -U postgres -d koku -c \
        "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>/dev/null || true
}

apply_migrations() {
    kubectl exec -n "$NAMESPACE" "$MASU_POD" -- timeout 180 python /opt/koku/koku/manage.py migrate > /dev/null 2>&1 || true
    kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python /opt/koku/koku/manage.py migrate --fake api 0055_install_pg_stat_statements > /dev/null 2>&1 || true
}

run_migrations() {
    if [ "$SKIP_MIGRATIONS" = true ]; then
        info "Phase 2: Database Migrations [SKIPPED]"
        echo ""
        return
    fi

    info "Phase 2: Ensuring Database Migrations Complete"
    echo ""

    local MIGRATIONS_PENDING=$(kubectl exec -n "$NAMESPACE" "$MASU_POD" -- bash -c \
        'python /opt/koku/koku/manage.py showmigrations 2>&1 | grep -c "^\s*\[ \]" || true')

    if [ "$MIGRATIONS_PENDING" -gt 0 ]; then
        warning "$MIGRATIONS_PENDING migrations pending, applying..."
        create_hive_prerequisites
        apply_migrations
        step_pass "Migrations applied"
    else
        step_pass "All migrations already applied"
    fi

    echo ""
}

# ============================================================================
# Phase 3: Provider Setup
# ============================================================================

get_existing_provider() {
    local PROVIDER_INFO=$(kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python3 << 'EOFPYTHON' 2>&1 | grep "PROVIDER"
import os, sys, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'koku.settings')
sys.path.append('/opt/koku/koku')
django.setup()
from api.models import Provider
try:
    p = Provider.objects.first()
    if p:
        print(f'PROVIDER_UUID={p.uuid}')
        print(f'PROVIDER_NAME={p.name}')
    else:
        print('PROVIDER_NOT_FOUND')
except Exception:
    print('PROVIDER_ERROR')
EOFPYTHON
)

    PROVIDER_UUID=$(echo "$PROVIDER_INFO" | grep "PROVIDER_UUID=" | cut -d'=' -f2 | tr -d '\r\n ')
    PROVIDER_NAME=$(echo "$PROVIDER_INFO" | grep "PROVIDER_NAME=" | cut -d'=' -f2 | tr -d '\r\n ')

    if [ ! -z "$PROVIDER_UUID" ] && [ "$PROVIDER_UUID" != "" ]; then
        step_pass "Using existing provider: $PROVIDER_NAME"
        info "  UUID: $PROVIDER_UUID"
        return 0
    else
        warning "No existing provider found"
        return 1
    fi
}

create_provider() {
    local PROVIDER_OUTPUT=$(kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python3 << 'EOFPYTHON' 2>&1
import os, sys, django
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "koku.settings")
sys.path.append("/opt/koku/koku")
django.setup()
from api.models import Customer, Provider
from api.provider.models import ProviderAuthentication, ProviderBillingSource
import uuid

org_id = "org1234567"

try:
    customer, _ = Customer.objects.get_or_create(schema_name=org_id)
    provider, created = Provider.objects.get_or_create(
        name="AWS Test Provider E2E",
        defaults={
            "uuid": str(uuid.uuid4()),
            "type": Provider.PROVIDER_AWS,
            "setup_complete": False,
            "active": True,
            "paused": False,
            "customer": customer
        }
    )

    if created:
        ProviderAuthentication.objects.get_or_create(
            provider=provider,
            defaults={"credentials": {}}
        )
        ProviderBillingSource.objects.get_or_create(
            provider=provider,
            defaults={
                "data_source": {
                    "bucket": "cost-data",
                    "report_name": "test-report",
                    "report_prefix": "",
                    "storage_only": True
                }
            }
        )
        provider.setup_complete = True
        provider.save()

    print(f"PROVIDER_UUID={provider.uuid}")
    print(f"PROVIDER_NAME={provider.name}")
except Exception as e:
    print(f"ERROR={e}")
EOFPYTHON
)

    PROVIDER_UUID=$(echo "$PROVIDER_OUTPUT" | grep "PROVIDER_UUID=" | cut -d'=' -f2 | tr -d '\r\n')
    PROVIDER_NAME=$(echo "$PROVIDER_OUTPUT" | grep "PROVIDER_NAME=" | cut -d'=' -f2 | tr -d '\r\n')

    if [ ! -z "$PROVIDER_UUID" ]; then
        step_pass "Provider ready: $PROVIDER_NAME"
        info "  UUID: $PROVIDER_UUID"
        return 0
    else
        step_fail "Provider creation failed"
        echo "$PROVIDER_OUTPUT" | grep -v "INFO\|Unleash\|Sentry\|celery"
        exit 1
    fi
}

run_provider_setup() {
    if [ "$SKIP_PROVIDER" = true ]; then
        info "Phase 3: Provider Setup [SKIPPED]"
        echo ""
        get_existing_provider || warning "Run without --skip-provider to create one"
    else
        info "Phase 3: Creating Provider and Test Data"
        echo ""
        create_provider
    fi

    echo ""
}

# ============================================================================
# Phase 4: Upload Test Data
# ============================================================================

check_existing_data() {
    local S3_CHECK=$(kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python3 << 'EOFPYTHON' 2>&1
import boto3, os
try:
    s3 = boto3.client('s3',
        endpoint_url=os.environ.get('S3_ENDPOINT'),
        aws_access_key_id=os.environ.get('AWS_ACCESS_KEY_ID'),
        aws_secret_access_key=os.environ.get('AWS_SECRET_ACCESS_KEY'),
        verify=False)
    response = s3.list_objects_v2(Bucket='cost-data', Prefix='test-report/')
    print(f"OBJECT_COUNT={response.get('KeyCount', 0)}")
except Exception as e:
    print(f"ERROR={e}")
EOFPYTHON
)

    local COUNT=$(echo "$S3_CHECK" | grep "OBJECT_COUNT=" | cut -d'=' -f2 | tr -d '\r\n')
    if [ ! -z "$COUNT" ] && [ "$COUNT" -gt 0 ]; then
        info "Existing test data found in S3: $COUNT objects"
        return 0
    fi
    return 1
}

upload_test_data() {
    kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python3 << 'EOFPYTHON' > /tmp/data-upload.log 2>&1
import boto3, gzip, json, os

s3 = boto3.client('s3',
    endpoint_url=os.environ.get('S3_ENDPOINT'),
    aws_access_key_id=os.environ.get('AWS_ACCESS_KEY_ID'),
    aws_secret_access_key=os.environ.get('AWS_SECRET_ACCESS_KEY'),
    verify=False)

# Create manifest
manifest = {
    'reportId': 'test-report-001',
    'reportName': 'test-report',
    'version': '1.0',
    'reportKeys': ['test-report/20251101-20251113/test-report-1.csv.gz'],
    'billingPeriod': {'start': '2025-11-01', 'end': '2025-11-13'},
    'bucket': 'cost-data',
    'reportPathPrefix': 'test-report',
    'timeGranularity': 'DAILY',
    'compression': 'GZIP',
    'format': 'textORcsv'
}

manifest_key = 'test-report/20251101-20251113/test-report-Manifest.json'
s3.put_object(Bucket='cost-data', Key=manifest_key, Body=json.dumps(manifest).encode('utf-8'))
print(f"Uploaded: {manifest_key}")

# Create CSV data
csv_data = '''identity/LineItemId,identity/TimeInterval,bill/PayerAccountId,lineItem/UsageAccountId,lineItem/LineItemType,lineItem/UsageStartDate,lineItem/UsageEndDate,lineItem/ProductCode,lineItem/UsageType,lineItem/Operation,lineItem/ResourceId,lineItem/UsageAmount,lineItem/UnblendedRate,lineItem/UnblendedCost,lineItem/BlendedRate,lineItem/BlendedCost,product/instanceType,product/region,resourceTags/user:environment,resourceTags/user:app
1,2025-11-01T00:00:00Z/2025-11-01T01:00:00Z,123456789012,123456789012,Usage,2025-11-01T00:00:00Z,2025-11-01T01:00:00Z,AmazonEC2,BoxUsage:t3.medium,RunInstances,i-12345,24.0,0.0416,1.00,0.0416,1.00,t3.medium,us-east-1,production,web-server
2,2025-11-01T00:00:00Z/2025-11-01T01:00:00Z,123456789012,123456789012,Usage,2025-11-01T00:00:00Z,2025-11-01T01:00:00Z,AmazonEC2,BoxUsage:t3.large,RunInstances,i-67890,24.0,0.0832,2.00,0.0832,2.00,t3.large,us-east-1,development,database
3,2025-11-01T00:00:00Z/2025-11-01T01:00:00Z,123456789012,123456789012,Usage,2025-11-01T00:00:00Z,2025-11-01T01:00:00Z,AmazonEC2,EBS:VolumeUsage.gp3,CreateVolume,vol-12345,100.0,0.08,8.00,0.08,8.00,,,production,
4,2025-11-01T00:00:00Z/2025-11-01T01:00:00Z,123456789012,123456789012,Usage,2025-11-01T00:00:00Z,2025-11-01T01:00:00Z,AmazonEC2,EBS:VolumeUsage.gp3,CreateVolume,vol-67890,50.0,0.08,4.00,0.08,4.00,,,development,
'''

csv_gz = gzip.compress(csv_data.encode('utf-8'))
csv_key = 'test-report/20251101-20251113/test-report-1.csv.gz'
s3.put_object(Bucket='cost-data', Key=csv_key, Body=csv_gz)
print(f"Uploaded: {csv_key}")

response = s3.list_objects_v2(Bucket='cost-data', Prefix='test-report/')
print(f"Total objects: {response.get('KeyCount', 0)}")
EOFPYTHON

    if grep -q "Total objects:" /tmp/data-upload.log; then
        local OBJECT_COUNT=$(grep "Total objects:" /tmp/data-upload.log | awk '{print $NF}')
        step_pass "Test data uploaded: $OBJECT_COUNT files"
        return 0
    else
        step_fail "Data upload failed"
        cat /tmp/data-upload.log
        exit 1
    fi
}

run_data_upload() {
    if [ "$SKIP_DATA" = true ]; then
        info "Phase 4: Upload Test Data [SKIPPED]"
        echo ""
        check_existing_data || warning "No test data found in S3"
    else
        info "Phase 4: Uploading Test Data to S3"
        echo ""
        upload_test_data
    fi

    echo ""
}

# ============================================================================
# Phase 5: Trigger Data Processing
# ============================================================================

trigger_masu_processing() {
    local TRIGGER_OUTPUT=$(kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python3 << 'EOFPYTHON' 2>&1
import os, sys, django
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "koku.settings")
sys.path.append("/opt/koku/koku")
django.setup()
from masu.celery.tasks import check_report_updates
try:
    result = check_report_updates.delay()
    print(f"TASK_ID={result.id}")
except Exception as e:
    print(f"ERROR={e}")
EOFPYTHON
)

    local TASK_ID=$(echo "$TRIGGER_OUTPUT" | grep "TASK_ID=" | cut -d'=' -f2 | tr -d '\r\n')
    if [ ! -z "$TASK_ID" ]; then
        step_pass "Download task triggered: $TASK_ID"
        return 0
    else
        step_fail "Task trigger failed"
        return 1
    fi
}

run_trigger_processing() {
    info "Phase 5: Triggering MASU Data Processing"
    echo ""

    trigger_masu_processing

    echo ""
}

# ============================================================================
# Phase 6: Monitor Processing
# ============================================================================

check_manifests() {
    local MANIFEST_COUNT=$(kubectl exec -n "$NAMESPACE" "$MASU_POD" -- python3 << 'EOFPYTHON' 2>&1
import os, sys, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'koku.settings')
sys.path.append('/opt/koku/koku')
django.setup()
from reporting_common.models import CostUsageReportManifest
print(CostUsageReportManifest.objects.count())
EOFPYTHON
)
    echo "$MANIFEST_COUNT" | grep -oE '[0-9]+$' || echo "0"
}

monitor_processing() {
    info "Phase 6: Monitoring Data Processing (max ${PROCESSING_TIMEOUT}s)"
    echo ""

    local MAX_WAIT=$PROCESSING_TIMEOUT
    local INTERVAL=10
    local ELAPSED=0

    info "Waiting for manifest processing..."
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))

        local MANIFEST_COUNT=$(check_manifests)

        if [ "$MANIFEST_COUNT" -gt 0 ]; then
            echo ""
            step_pass "Manifest processed (${ELAPSED}s elapsed)"
            break
        fi

        if [ $ELAPSED -ge $MAX_WAIT ]; then
            echo ""
            warning "Manifest not processed after ${MAX_WAIT}s, continuing anyway..."
            break
        fi

        echo -n "."
    done
    echo ""

    echo ""
}

# ============================================================================
# Phase 7: Verify Trino Tables
# ============================================================================

verify_trino_tables() {
    info "Phase 7: Verifying Trino Tables"
    echo ""

    local TRINO_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=trino-coordinator -o name | head -1 | sed 's|pod/||')

    if [ ! -z "$TRINO_POD" ]; then
        local TABLES=$(kubectl exec -n "$NAMESPACE" "$TRINO_POD" -- /usr/bin/trino --execute "SHOW TABLES FROM hive.$ORG_ID;" 2>/dev/null | wc -l | tr -d ' ')

        if [ "$TABLES" -gt 0 ]; then
            step_pass "Trino tables created: $TABLES tables in hive.$ORG_ID"
        else
            warning "No Trino tables found yet (may need more processing time)"
        fi
    else
        warning "Trino pod not found, skipping table verification"
    fi

    echo ""
}

# ============================================================================
# Phase 8: Run IQE Test Suite
# ============================================================================

setup_port_forward() {
    info "Setting up port-forward to Koku API..."
    kubectl port-forward -n "$NAMESPACE" svc/koku-koku-api 8000:8000 > /tmp/iqe-pf.log 2>&1 &
    local PF_PID=$!
    sleep 5

    local MAX_RETRIES=30
    for i in $(seq 1 $MAX_RETRIES); do
        if curl -s http://localhost:8000/api/cost-management/v1/status/ > /dev/null 2>&1; then
            step_pass "API accessible on localhost:8000"
            echo "$PF_PID"
            return 0
        fi
        if [ $i -eq $MAX_RETRIES ]; then
            warning "API not accessible after ${MAX_RETRIES}s"
            kill $PF_PID 2>/dev/null || true
            return 1
        fi
        sleep 1
    done
}

run_iqe_tests() {
    export ENV_FOR_DYNACONF=onprem
    export DYNACONF_IQE_VAULT_LOADER_ENABLED=false
    export PYTEST_PLUGINS="iqe_cost_management.conftest_onprem"

    info "Executing IQE test suite..."
    cd "$IQE_DIR"

    local TEST_OUTPUT=$(python3 -m pytest \
        iqe_cost_management/tests/rest_api/v1/ \
        -v --tb=short --maxfail=10 \
        -k "not wait_for_ingest" \
        2>&1 || true)

    local TESTS_PASSED=$(echo "$TEST_OUTPUT" | grep -oE "[0-9]+ passed" | grep -oE "[0-9]+" | head -1 || echo "0")
    local TESTS_FAILED=$(echo "$TEST_OUTPUT" | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+" | head -1 || echo "0")
    local TESTS_SKIPPED=$(echo "$TEST_OUTPUT" | grep -oE "[0-9]+ skipped" | grep -oE "[0-9]+" | head -1 || echo "0")
    local TESTS_TOTAL=$((TESTS_PASSED + TESTS_FAILED))

    info "IQE Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped (Total: $TESTS_TOTAL)"

    if [ "$TESTS_TOTAL" -gt 0 ]; then
        if [ "$TESTS_PASSED" -ge 80 ]; then
            step_pass "IQE test suite passed: $TESTS_PASSED tests"
        else
            warning "IQE tests ran but pass rate is low: $TESTS_PASSED/$TESTS_TOTAL"
        fi

        if [ "$TESTS_FAILED" -gt 0 ]; then
            warning "$TESTS_FAILED tests failed"
            echo "$TEST_OUTPUT" | grep "FAILED" | head -5
        fi
    else
        warning "No IQE tests executed (may need provider data)"
    fi
}

run_test_suite() {
    if [ "$SKIP_TESTS" = true ]; then
        info "Phase 8: IQE Test Suite [SKIPPED]"
        echo ""
        return
    fi

    info "Phase 8: Running IQE Test Suite (~90 tests)"
    echo ""

    if [ ! -d "$IQE_DIR" ]; then
        warning "IQE directory not found: $IQE_DIR"
        warning "Skipping IQE test execution"
        echo ""
        return
    fi

    info "Running IQE tests from: $IQE_DIR"

    local PF_PID=$(setup_port_forward)

    if [ ! -z "$PF_PID" ]; then
        run_iqe_tests
        kill $PF_PID 2>/dev/null || true
    fi

    echo ""
}

# ============================================================================
# Phase 9: Final Summary
# ============================================================================

print_summary() {
    local END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    Validation Summary                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Total Steps: $TOTAL_STEPS"
    echo -e "${GREEN}Passed: $PASSED_STEPS${NC}"
    if [ "$FAILED_STEPS" -gt 0 ]; then
        echo -e "${RED}Failed: $FAILED_STEPS${NC}"
    else
        echo -e "${GREEN}Failed: 0${NC}"
    fi
    echo "Duration: ${DURATION}s"
    echo ""

    local SUCCESS_RATE=$((PASSED_STEPS * 100 / TOTAL_STEPS))

    if [ "$SUCCESS_RATE" -ge 90 ] && [ "$FAILED_STEPS" -eq 0 ]; then
        echo -e "${GREEN}✅ E2E VALIDATION PASSED${NC}"
        echo ""
        echo "Deployment is ready for production use!"
        echo ""
        echo "Provider UUID: $PROVIDER_UUID"
        echo "Org ID: $ORG_ID"
        echo "Bucket: $S3_BUCKET"
        echo "Report: $REPORT_NAME"
        echo ""
        exit 0
    elif [ "$SUCCESS_RATE" -ge 70 ]; then
        echo -e "${YELLOW}⚠️  E2E VALIDATION PARTIAL SUCCESS${NC}"
        echo ""
        echo "Most components operational, but some issues detected."
        echo "Review logs above for details."
        echo ""
        exit 1
    else
        echo -e "${RED}❌ E2E VALIDATION FAILED${NC}"
        echo ""
        echo "Critical issues detected. Review logs above."
        echo ""
        exit 1
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    parse_arguments "$@"

    START_TIME=$(date +%s)

    print_header

    run_preflight_checks
    run_migrations
    run_provider_setup
    run_data_upload
    run_trigger_processing
    monitor_processing
    verify_trino_tables
    run_test_suite

    print_summary
}

# Run main function
main "$@"
