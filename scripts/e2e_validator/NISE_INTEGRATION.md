# Nise Integration in E2E Validation

## Overview

**Nise** (synthetic data generator) runs in **Phase 4** to create predictable test data for financial validation. This enables comprehensive E2E testing of cost calculations, aggregations, and reporting.

## When Nise Runs

```
E2E Validation Flow:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Phase 1: Preflight Checks
  ✓ Verify cluster health
  ✓ Check pod status

Phase 2: Database Migrations
  ✓ Apply schema updates
  ✓ Create Hive prerequisites

Phase 3: Provider Setup
  ✓ Create or verify provider
  ✓ Configure data source

Phase 4: Generate & Upload Test Data   ← **NISE RUNS HERE** 🎯
  ├─ 4a. Generate scenarios with Nise
  │    ├─ basic_compute (EC2 instances)
  │    ├─ storage_costs (EBS, S3)
  │    ├─ tagged_resources (cost allocation)
  │    ├─ multi_account (org structure)
  │    └─ daily_variation (trending)
  │
  ├─ 4b. Upload data to S3
  │    ├─ CSV files (gzipped CUR format)
  │    └─ Manifest JSON
  │
  └─ 4c. Verify upload
       └─ Confirm S3 object count

Phase 5: Trigger MASU Processing
  ✓ Send Celery task to download data
  ✓ Get task ID

Phase 6: Monitor Processing
  ✓ Wait for manifest in database
  ✓ Verify data processing started

Phase 7: Verify Trino Tables
  ✓ Check Hive schema creation
  ✓ Verify table count

Phase 8: Run IQE Test Suite   ← **VALIDATES NISE SCENARIOS** 🎯
  ├─ Cost calculation tests
  │    └─ Verify expected costs match Nise scenarios
  │
  ├─ Aggregation tests
  │    └─ Sum by service, region, account
  │
  ├─ Tag filtering tests
  │    └─ Filter by tags from Nise scenarios
  │
  ├─ Trending tests
  │    └─ Daily/monthly cost trends
  │
  └─ Multi-account tests
       └─ Organization hierarchy costs

Phase 9: Summary
  ✓ Report pass/fail status
  ✓ Show scenario validation results
```

## Test Scenarios

### Predefined Scenarios

Each scenario generates **predictable, deterministic data** for specific test cases:

#### 1. `basic_compute`
**Purpose**: Test basic EC2 cost calculations

**Generated Data**:
- 5 EC2 instances (t3.medium, t3.large)
- 24 hours/day usage
- Known hourly rates
- **Expected Total Cost**: $1,000.00

**IQE Tests**:
```python
def test_basic_compute_costs(api_client):
    """Verify basic EC2 costs match Nise scenario"""
    response = api_client.get_costs(
        filter='service:AmazonEC2',
        group_by='instance_type'
    )
    
    assert response['total'] == 1000.00
    assert 't3.medium' in response['data']
    assert 't3.large' in response['data']
```

#### 2. `storage_costs`
**Purpose**: Test storage cost calculations

**Generated Data**:
- EBS volumes (gp3, 100GB each)
- S3 storage (standard tier)
- **Expected Total Cost**: $500.00

**IQE Tests**:
```python
def test_storage_costs(api_client):
    """Verify EBS + S3 costs"""
    response = api_client.get_costs(
        filter='service:AmazonEC2,AmazonS3',
        group_by='service'
    )
    
    assert response['total'] == 500.00
```

#### 3. `tagged_resources`
**Purpose**: Test cost allocation tags

**Generated Data**:
- Resources with tags:
  - `environment:production`
  - `environment:development`
  - `app:web-server`
  - `app:database`
- **Expected Total Cost**: $750.00

**IQE Tests**:
```python
def test_tag_filtering(api_client):
    """Verify tag-based cost filtering"""
    prod_costs = api_client.get_costs(
        filter='tag:environment=production'
    )
    dev_costs = api_client.get_costs(
        filter='tag:environment=development'
    )
    
    assert prod_costs['total'] + dev_costs['total'] == 750.00
```

#### 4. `multi_account`
**Purpose**: Test organization hierarchy

**Generated Data**:
- 2 AWS accounts
- Different cost patterns per account
- **Expected Total Cost**: $2,000.00

**IQE Tests**:
```python
def test_multi_account_costs(api_client):
    """Verify org-level aggregation"""
    response = api_client.get_costs(
        group_by='account'
    )
    
    assert len(response['accounts']) == 2
    assert response['total'] == 2000.00
```

#### 5. `daily_variation`
**Purpose**: Test trending and forecasting

**Generated Data**:
- Daily costs with known pattern
- Increasing trend: $40/day → $60/day
- **Expected Total Cost**: $1,500.00 (30 days)

**IQE Tests**:
```python
def test_cost_trending(api_client):
    """Verify daily cost trends"""
    response = api_client.get_costs(
        group_by='date',
        time_scope='monthly'
    )
    
    # Verify increasing trend
    daily_costs = [d['cost'] for d in response['data']]
    assert daily_costs[-1] > daily_costs[0]
```

## Data Flow

```
┌─────────────┐
│   Nise CLI  │  Generate synthetic CUR data
└──────┬──────┘
       │
       │ Writes to local temp directory
       ↓
┌────────────────────────────────────────┐
│ Local Files:                           │
│  ├─ 20251101-20251130/                 │
│  │  ├─ test-report-1.csv.gz            │ ← CSV data
│  │  ├─ test-report-2.csv.gz            │
│  │  └─ test-report-Manifest.json       │ ← Manifest
│  └─ ...                                │
└─────────────┬──────────────────────────┘
              │
              │ Upload via boto3
              ↓
┌────────────────────────────────────────┐
│ S3 Bucket (MinIO/ODF):                 │
│  cost-data/                            │
│  └─ test-report/                       │
│     └─ 20251101-20251130/              │
│        ├─ test-report-1.csv.gz         │
│        ├─ test-report-2.csv.gz         │
│        └─ test-report-Manifest.json    │
└─────────────┬──────────────────────────┘
              │
              │ MASU downloads
              ↓
┌────────────────────────────────────────┐
│ MASU Processing:                       │
│  1. Download from S3                   │
│  2. Parse CSV                          │
│  3. Write to Postgres                  │
│  4. Create Hive tables                 │
└─────────────┬──────────────────────────┘
              │
              ↓
┌────────────────────────────────────────┐
│ PostgreSQL:                            │
│  ├─ reporting_awscostentrylineitem     │
│  ├─ reporting_awscostentry_daily_sum   │
│  └─ ...                                │
└─────────────┬──────────────────────────┘
              │
              │ Trino queries
              ↓
┌────────────────────────────────────────┐
│ Trino Tables:                          │
│  hive.org1234567.aws_line_items        │
│  hive.org1234567.reporting_awscost...  │
└─────────────┬──────────────────────────┘
              │
              │ API queries
              ↓
┌────────────────────────────────────────┐
│ Koku API:                              │
│  /api/cost-management/v1/reports/...   │
└─────────────┬──────────────────────────┘
              │
              │ IQE tests validate
              ↓
┌────────────────────────────────────────┐
│ IQE Test Suite:                        │
│  ✓ test_basic_compute_costs()          │
│  ✓ test_storage_costs()                │
│  ✓ test_tag_filtering()                │
│  ✓ test_multi_account_costs()          │
│  ✓ test_cost_trending()                │
│  ...90+ tests total                    │
└────────────────────────────────────────┘
```

## Usage Examples

### Full Scenario Suite (CI/CD)
```bash
# Run complete E2E with all scenarios
python3 -m e2e_validator.cli \
    --namespace cost-mgmt \
    --scenarios basic_compute,storage_costs,tagged_resources,multi_account,daily_variation

# This will:
# 1. Generate 5 scenarios with Nise (~2 minutes)
# 2. Upload to S3 (~30 seconds)
# 3. Trigger MASU processing (~3 minutes)
# 4. Run 90+ IQE tests (~5 minutes)
# Total time: ~11 minutes
```

### Quick Single Scenario (Development)
```bash
# Fast iteration with basic scenario only
python3 -m e2e_validator.cli \
    --namespace cost-mgmt \
    --quick

# This will:
# 1. Generate basic_compute only (~30 seconds)
# 2. Upload to S3 (~10 seconds)
# 3. Trigger MASU processing (~2 minutes)
# 4. Run subset of tests (~2 minutes)
# Total time: ~5 minutes
```

### Custom Scenario
```python
from e2e_validator.clients.nise import NiseClient
from datetime import datetime, timedelta

nise = NiseClient()

# Generate custom data
end_date = datetime.now()
start_date = end_date - timedelta(days=7)

data_path = nise.generate_aws_cur(
    start_date=start_date,
    end_date=end_date,
    account_id='999888777666',
    tags=['team:platform', 'env:staging']
)

# Upload and validate...
```

## Scenario Validation

After tests run, scenarios are validated:

```python
from e2e_validator.clients.nise import NiseScenarioValidator

validator = NiseScenarioValidator(db_client)

# Validate each scenario
for scenario in ['basic_compute', 'storage_costs', 'tagged_resources']:
    result = validator.validate_scenario_costs(
        scenario_name=scenario,
        tolerance=0.01  # 1% tolerance
    )
    
    print(f"{scenario}:")
    print(f"  Expected: ${result['expected_cost']:.2f}")
    print(f"  Actual:   ${result['actual_cost']:.2f}")
    print(f"  Variance: {result['variance']*100:.2f}%")
    print(f"  Status:   {'PASS' if result['passed'] else 'FAIL'}")
```

**Example Output**:
```
basic_compute:
  Expected: $1000.00
  Actual:   $1002.15
  Variance: 0.21%
  Status:   PASS ✓

storage_costs:
  Expected: $500.00
  Actual:   $499.87
  Variance: 0.03%
  Status:   PASS ✓

tagged_resources:
  Expected: $750.00
  Actual:   $750.00
  Variance: 0.00%
  Status:   PASS ✓
```

## Benefits of Nise Integration

1. **Deterministic Testing**: Known inputs → predictable outputs
2. **Comprehensive Coverage**: Multiple scenarios test different features
3. **Fast Iteration**: Generate fresh data in seconds
4. **Reproducible**: Same scenarios always produce same data
5. **Version Control**: Scenarios defined in code, not data files
6. **Isolated**: Each test run uses fresh data, no state pollution

## Next Steps

See the main CLI documentation for running the complete E2E suite with Nise scenarios.

