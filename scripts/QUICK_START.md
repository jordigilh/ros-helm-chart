# E2E Validator - Quick Start Guide

## Installation (One-Time Setup)

```bash
cd /Users/jgil/go/src/github.com/insights-onprem/ros-helm-chart/scripts
pip3 install -r requirements-e2e.txt
```

This installs:
- `koku-nise` (auto-installs if missing during first run)
- `kubernetes` API client
- `psycopg2-binary` for PostgreSQL
- `boto3` for S3
- `celery` for task management
- Supporting libraries

## Running E2E Validation

### Quick Mode (5-10 minutes, 3 scenarios)
```bash
./e2e-validate.sh --namespace cost-mgmt --quick
```

### Full Mode (20-30 minutes, 8 scenarios)
```bash
./e2e-validate.sh --namespace cost-mgmt
```

### With Skip Flags
```bash
# Skip migrations if already applied
./e2e-validate.sh --namespace cost-mgmt --skip-migrations

# Skip provider creation if already exists
./e2e-validate.sh --namespace cost-mgmt --skip-provider

# Skip data upload (use existing data)
./e2e-validate.sh --namespace cost-mgmt --skip-data

# Skip IQE tests (just validate infrastructure)
./e2e-validate.sh --namespace cost-mgmt --skip-tests

# Combine flags
./e2e-validate.sh --namespace cost-mgmt --skip-migrations --skip-provider --quick
```

## What Gets Validated

### Phase 1: Preflight Checks ✓
- Namespace accessible
- MASU pod exists
- All pods healthy

### Phase 2: Database Migrations ✓
- Hive role/database created
- pg_stat_statements extension installed
- Django migrations applied

### Phase 3: Provider Setup ✓
- Customer and Tenant created
- AWS provider configured
- Authentication set up

### Phase 4: Data Upload ✓
- Nise generates test scenarios
- Data uploaded to S3
- Manifests created

### Phase 5-6: Processing ✓
- Celery tasks triggered
- Data ingested into database
- Manifests processed

### Phase 7: Trino Validation ✓
- Trino coordinator running
- Hive schema exists
- Tables created
- Sample queries work

### Phase 8: IQE Tests ✓
- ~90 REST API tests
- Cost calculations validated
- Data accuracy verified

## Test Scenarios (Database-Agnostic)

### Critical Scenarios (6):
1. **basic_queries** - Basic aggregations and filtering
2. **advanced_queries** - Complex aggregations and joins
3. **mathematical_precision** - Decimal precision and financial accuracy
4. **data_accuracy** - End-to-end data integrity
5. **tagged_resources** - Tag-based cost allocation
6. **data_pipeline_integrity** - Full pipeline validation

### Functional Scenarios (2):
7. **functional_basic** - Basic cost reporting
8. **functional_tags** - Tag filtering

## Expected Output

```
======================================================================
E2E VALIDATION SUMMARY
======================================================================

Phase 1: Preflight Checks         ✅ PASSED
Phase 2: Database Migrations      ✅ PASSED (or SKIPPED)
Phase 3: Provider Setup           ✅ PASSED
Phase 4: Data Upload              ✅ PASSED
  - Generated 8 scenarios
  - Uploaded 245 CSV files
Phase 5-6: Processing             ✅ PASSED
  - Manifests processed: 8
Phase 7: Trino Validation         ✅ PASSED
  - Tables found: 12
Phase 8: IQE Tests                ✅ PASSED
  - Tests passed: 92/93

Overall: ✅ SUCCESS

Total Time: 1847.3s (30.8 minutes)
```

## Troubleshooting

### Issue: Nise not found
**Solution:** Auto-installs on first run, or manually:
```bash
pip3 install koku-nise
```

### Issue: S3 connection failed
**Solution:** Check storage credentials:
```bash
kubectl get secret -n cost-mgmt koku-storage-credentials -o yaml
```

### Issue: Migrations failed
**Solution:** Check database connectivity:
```bash
kubectl get pods -n cost-mgmt | grep koku-db
```

### Issue: Trino tables not found
**Solution:** Data may not be processed yet. Check MASU logs:
```bash
kubectl logs -n cost-mgmt -l app=masu --tail=100
```

### Issue: IQE tests failing
**Solution:** Check API is accessible:
```bash
kubectl port-forward -n cost-mgmt svc/koku-koku-api 8000:8000 &
curl http://localhost:8000/api/cost-management/v1/status/
```

## Advanced Usage

### Component Testing

#### Test Nise Only:
```bash
python3 -c "
from e2e_validator.clients.nise import NiseClient
from datetime import datetime, timedelta
n = NiseClient()
start = datetime.now() - timedelta(days=7)
path = n.generate_scenario('basic_queries', start, datetime.now())
print(f'Data at: {path}')
"
```

#### Test Database Connection:
```bash
python3 -c "
from e2e_validator.clients.kubernetes import KubernetesClient
from e2e_validator.clients.database import DatabaseClient
k8s = KubernetesClient(namespace='cost-mgmt')
db = DatabaseClient(k8s, namespace='cost-mgmt')
result = db.execute_query('SELECT COUNT(*) FROM api_provider;', fetch_one=True)
print(f'Providers: {result[0]}')
db.close()
"
```

#### Test S3 Access:
```bash
python3 -c "
from e2e_validator.clients.kubernetes import KubernetesClient
from e2e_validator.clients.s3 import S3Client
k8s = KubernetesClient(namespace='cost-mgmt')
key = k8s.get_secret('koku-storage-credentials', 'access-key')
secret = k8s.get_secret('koku-storage-credentials', 'secret-key')
s3 = S3Client('https://s3.openshift-storage.svc:443', key, secret, verify=False)
print(f'Bucket exists: {s3.bucket_exists(\"cost-data\")}')
"
```

## CI/CD Integration

### Minimal Example:
```bash
#!/bin/bash
set -e

cd /path/to/scripts
pip3 install -r requirements-e2e.txt
./e2e-validate.sh --namespace cost-mgmt --timeout 600

if [ $? -eq 0 ]; then
    echo "✅ E2E validation passed"
    exit 0
else
    echo "❌ E2E validation failed"
    exit 1
fi
```

### With Slack Notification:
```bash
#!/bin/bash
RESULT=$(./e2e-validate.sh --namespace cost-mgmt 2>&1)
STATUS=$?

if [ $STATUS -eq 0 ]; then
    MESSAGE="✅ E2E Validation Passed"
    COLOR="good"
else
    MESSAGE="❌ E2E Validation Failed"
    COLOR="danger"
fi

curl -X POST $SLACK_WEBHOOK_URL \
  -H 'Content-Type: application/json' \
  -d "{\"text\":\"$MESSAGE\",\"color\":\"$COLOR\"}"

exit $STATUS
```

## Key Files

- `e2e-validate.sh` - Main wrapper script
- `e2e_validator/cli.py` - Python orchestrator
- `e2e_validator/clients/nise.py` - Test data generator
- `e2e_validator/phases/migrations.py` - Database migrations
- `e2e_validator/phases/trino_validation.py` - Trino checks
- `requirements-e2e.txt` - Python dependencies

## Getting Help

1. Check `IMPLEMENTATION_COMPLETE.md` for detailed testing instructions
2. Check `COMPLETE_E2E_IMPLEMENTATION.md` for architecture details
3. Review logs in `/tmp/e2e-validator.log` (if exists)
4. Check pod logs: `kubectl logs -n cost-mgmt -l app=<component>`

## Success Indicators

✅ All phases show "PASSED" or "SKIPPED" (if using skip flags)
✅ IQE tests: 90+ passed, <5 failed
✅ Trino validation finds tables
✅ No error messages in output
✅ Total time reasonable (5-30 minutes depending on mode)

---

**Quick Start Complete!** Run `./e2e-validate.sh --namespace cost-mgmt --quick` to begin.

