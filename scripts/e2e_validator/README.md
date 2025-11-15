# E2E Validator - Database-Agnostic Testing

Python-based E2E validation suite for Cost Management using native API connections.

## Quick Start

```bash
# Install dependencies
pip3 install -r requirements-e2e.txt

# Run full validation
cd scripts
./e2e-validate.sh

# Or run Python module directly
python3 -m e2e_validator.cli
```

## Key Features

✅ **Database-Agnostic**: Tests work with both Trino+Hive+Postgres AND Pure Postgres
✅ **Native API Clients**: Direct Kubernetes/Postgres/S3 connections (no subprocess calls)
✅ **Nise Integration**: Deterministic test data generation
✅ **IQE Tests**: ~90 application-level tests
✅ **Migration Ready**: Same tests validate both architectures

## Architecture

```
E2E Validator (Python)
├── clients/
│   ├── kubernetes.py      # Native K8s API (no kubectl)
│   ├── database.py         # Direct psycopg2 (no psql)
│   ├── nise.py             # Deterministic data generation
│   └── (s3 via boto3)      # Native S3 client
├── phases/
│   ├── preflight.py        # Phase 1: Environment checks
│   ├── provider.py         # Phase 3: Provider setup
│   ├── data_upload.py      # Phase 4: Nise + S3 upload
│   ├── processing.py       # Phase 5-6: MASU trigger + monitor
│   ├── iqe_tests.py        # Phase 8: IQE test suite
│   └── deployment_validation.py  # Infrastructure checks
└── cli.py                  # Main CLI orchestrator
```

## Command-Line Options

```bash
./e2e-validate.sh [OPTIONS]

Options:
  --namespace TEXT          Kubernetes namespace (default: cost-mgmt)
  --org-id TEXT            Organization ID (default: org1234567)
  --skip-migrations        Skip database migrations
  --skip-provider          Skip provider setup
  --skip-data              Skip data upload
  --skip-tests             Skip IQE tests
  --skip-deployment-validation  Skip deployment validation
  --quick                  Quick mode (skip all setup)
  --timeout INTEGER        Processing timeout seconds (default: 180)
  --scenarios TEXT         Comma-separated scenarios or "all"
  --iqe-dir TEXT          IQE plugin directory (auto-detect)
  --help                   Show help message
```

## Usage Examples

### Full Validation (CI/CD)
```bash
# Complete E2E with all scenarios
./e2e-validate.sh --scenarios all --timeout 300
```

### Quick Development Check
```bash
# Fast validation with minimal scenarios
./e2e-validate.sh --quick
```

### Specific Scenarios
```bash
# Run only critical data persistence tests
./e2e-validate.sh \
  --scenarios basic_queries,advanced_queries,mathematical_precision,data_accuracy
```

### Skip Phases
```bash
# Skip setup, just run tests
./e2e-validate.sh --skip-migrations --skip-provider --skip-data
```

## Test Scenarios

### Critical (6 scenarios - 73 tests)
1. **basic_queries** - Basic aggregations and filtering (15 tests)
2. **advanced_queries** - Complex queries and joins (20 tests)
3. **mathematical_precision** - Financial accuracy (8 tests)
4. **data_accuracy** - E2E data integrity (18 tests)
5. **tagged_resources** - Tag-based allocation (12 tests)
6. **data_pipeline_integrity** - Full S3→API pipeline (15 tests)

### Functional (2 scenarios - 8 tests)
7. **functional_basic** - Basic smoke test (5 tests)
8. **functional_tags** - Tag filtering smoke test (3 tests)

**Total: 8 scenarios, ~88 IQE tests**

## Database-Agnostic Design

The validator tests through the API layer, making it architecture-independent:

```
Current Architecture:
  Nise → S3 → MASU → Postgres → Hive → Trino → API → IQE ✓

Future Architecture:
  Nise → S3 → MASU → Postgres → API → IQE ✓

Same tests, same results, different database layer!
```

### Why This Works
- **Nise** generates deterministic input ($1,000)
- **IQE** validates API output ($1,000)
- **Database layer** is transparent to tests

If `Input = Output`, the system is correct regardless of internal architecture.

## Migration Validation

### Before Migration (Trino+Hive+Postgres)
```bash
$ ./e2e-validate.sh > baseline-results.log
✅ E2E VALIDATION PASSED
```

### After Migration (Pure Postgres)
```bash
$ ./e2e-validate.sh > migration-results.log
✅ E2E VALIDATION PASSED

$ diff baseline-results.log migration-results.log
# No differences = Successful migration!
```

## Output Example

```
======================================================================
  Cost Management E2E Validation Suite
  Database-Agnostic Testing (Nise + IQE)
======================================================================

Configuration:
  Namespace:  cost-mgmt
  Org ID:     org1234567
  Scenarios:  8
  Timeout:    180s

======================================================================
Phase 1: Pre-flight Checks
======================================================================

🔍 Checking namespace...
  ✅ Namespace 'cost-mgmt' accessible

🔍 Finding MASU pod...
  ✅ MASU pod found: koku-koku-api-masu-xxx

🔍 Checking pod health...
  ✅ Pod health: 25/25 ready

✅ Pre-flight checks passed

======================================================================
Phase 3: Provider Setup
======================================================================

🔍 Checking for existing provider...
  ✅ Provider exists: AWS Test Provider E2E
  ℹ️  UUID: d216ab69-1676-44a1-87b5-7e1995911bca
  ℹ️  Active: True

======================================================================
Phase 4: Generate & Upload Test Data (Nise)
======================================================================

📊 Generating test scenarios with Nise...
  - Generating 'basic_queries'...
    ✓ Generated at /tmp/nise-e2e-xxx
  - Generating 'advanced_queries'...
    ✓ Generated at /tmp/nise-e2e-yyy

⬆️  Uploading to S3...
  ✓ Uploaded 12 files

✅ Phase 4 Complete
  - Scenarios: 8
  - Files uploaded: 12
  - Total S3 objects: 15

======================================================================
Phase 5-6: Data Processing
======================================================================

🚀 Triggering MASU data processing...
  ✅ Task triggered: abc123-def456

⏳ Monitoring processing (timeout: 180s)...
..........

  ✅ Manifest processed (elapsed: 45s)
  ℹ️  Manifests: 1
  ℹ️  Time: 45s

======================================================================
Phase 8: IQE Test Suite
======================================================================

🔌 Setting up port-forward to Koku API...
  ✅ Port-forward established

🧪 Running IQE test suite...
  (This may take 5-10 minutes)

  📊 Results:
    Passed:  88
    Failed:  0
    Skipped: 2
    Total:   88

  ✅ All tests passed!

======================================================================
FINAL SUMMARY
======================================================================

Total Time: 385.2s (6.4 minutes)

Phases: 6/6 passed
  ✅ preflight
  ✅ provider
  ✅ data_upload
  ✅ processing
  ✅ trino
  ✅ iqe_tests

✅ E2E VALIDATION PASSED

Deployment is functioning correctly!
Database layer validated (architecture-agnostic)
```

## Requirements

- Python 3.9+
- kubectl (configured for cluster access)
- Cost Management deployed in Kubernetes

## Installation

```bash
# Install Python dependencies
pip3 install -r requirements-e2e.txt

# Verify installation
python3 -m e2e_validator.cli --help
```

## Troubleshooting

### Import Errors
```bash
# Ensure you're in the scripts/ directory
cd /path/to/ros-helm-chart/scripts
python3 -m e2e_validator.cli
```

### Kubernetes Connection Issues
```bash
# Verify kubectl works
kubectl get pods -n cost-mgmt

# Check kubeconfig
export KUBECONFIG=~/.kube/config
```

### Port Forward Failures
```bash
# Kill existing port forwards
pkill -f "port-forward.*8000:8000"

# Retry
./e2e-validate.sh
```

## See Also

- `DATABASE_AGNOSTIC_VALIDATION.md` - Design philosophy
- `NISE_INTEGRATION.md` - Nise data generation details
- `TEST_DATA_COVERAGE_ANALYSIS.md` - Test coverage breakdown

## Exit Codes

- `0` - All tests passed
- `1` - Tests failed or error occurred
- `130` - Interrupted by user (Ctrl+C)

