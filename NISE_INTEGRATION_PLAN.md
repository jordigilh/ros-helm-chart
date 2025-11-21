# Nise Integration Plan - Proper Financial Validation

## Problem Statement

The current E2E tests use **hardcoded CSV data** which validates:
- ✅ Infrastructure (pods, connections)
- ✅ Pipeline mechanics (CSV → Parquet → Trino → Postgres)
- ✅ API structure (correct JSON format)

But **does NOT validate**:
- ❌ **Financial correctness** (input costs ≠ output costs)
- ❌ **Business logic** (aggregations, filtering, tags)
- ❌ **Migration readiness** (can't compare architectures)

##Strategy: Use Nise Properly

### What is Nise?

Nise is the **official cost data generator** for Cost Management testing. It:
1. **Generates controlled scenarios** with known expected outputs
2. **Creates realistic data** (multi-day, multiple resources, tags, etc.)
3. **Supports all providers** (AWS, Azure, GCP, OCP, OCI)
4. **Enables financial validation** (known input → validate output)

### Runtime: 1-5 Minutes Per Provider

**Accept this runtime** because it enables:
- ✅ Controlled test scenarios
- ✅ Financial correctness validation
- ✅ Migration validation (Trino+Hive → Pure Postgres)
- ✅ Regression testing

---

## Current Approach (Wrong ❌)

```python
# In data_upload.py - upload_aws_cur_format()
csv_data = f"""..."""  # Hardcoded 5 rows

# Result:
# - Input: $15.40 (hardcoded)
# - Output: $??? (unknown, not validated)
# - IQE tests only check structure, not values
```

---

## Correct Approach (Using Nise ✅)

### AWS Implementation

```python
def upload_aws_cur_format(self, start_date, end_date, force=False):
    """Generate AWS CUR data using nise for controlled scenarios"""

    # 1. Generate data using nise (1-5 minutes)
    print("📊 Generating AWS CUR data with nise (1-5 min)...")
    output_dir = self.nise.generate_aws_cur(
        start_date=start_date,
        end_date=end_date,
        account_id='123456789012'
    )

    # 2. Upload nise-generated files to S3
    print("⬆️  Uploading nise-generated files...")
    for root, dirs, files in os.walk(output_dir):
        for file in files:
            s3_key = f'{self.report_prefix}/{self.report_name}/{relative_path}'
            with open(file_path, 'rb') as f:
                self.s3.put_object(Bucket=self.bucket, Key=s3_key, Body=f.read())

    # Result:
    # - Input: Known scenario from nise
    # - Output: Can be validated against expected totals
    # - IQE tests can assert financial correctness
```

### Azure Implementation

```python
def upload_azure_export_format(self, start_date, end_date, force=False):
    """Generate Azure export data using nise"""

    print("📊 Generating Azure export data with nise (1-5 min)...")
    output_dir = self.nise.generate_azure_export(
        start_date=start_date,
        end_date=end_date,
        subscription_id='11111111-1111-1111-1111-111111111111'
    )

    # Upload files...
```

### GCP Implementation

```python
def upload_gcp_export_format(self, start_date, end_date, force=False):
    """Generate GCP billing export data using nise"""

    print("📊 Generating GCP billing export data with nise (1-5 min)...")
    output_dir = self.nise.generate_gcp_export(
        start_date=start_date,
        end_date=end_date,
        project_id='test-project-12345'
    )

    # Upload files...
```

---

## Changes Required

### 1. Revert AWS Upload Method

**File**: `scripts/e2e_validator/phases/data_upload.py`

**Current** (lines 436-591): Hardcoded CSV data
**New**: Use nise.generate_aws_cur()

### 2. Fix Azure Upload Method

**File**: `scripts/e2e_validator/phases/data_upload.py`

**Current** (lines 669-718): Hardcoded CSV data
**New**: Use nise.generate_azure_export() with proper cwd

### 3. Fix GCP Upload Method

**File**: `scripts/e2e_validator/phases/data_upload.py`

**Current** (lines 774-823): Hardcoded CSV data
**New**: Use nise.generate_gcp_export() with proper cwd

### 4. Add Financial Validation to IQE Tests

**File**: `iqe-cost-management-plugin/iqe_cost_management/tests/rest_api/v1/test_trino_api_validation.py`

**Add assertions**:
```python
def test_trino_aws_cost_totals(self, application):
    """Validate financial correctness of AWS cost data"""
    response = api.get("/reports/aws/costs/")
    data = response.json()

    # Get total cost from API
    total_cost = data["meta"]["total"]["cost"]["value"]

    # Assert against known nise scenario
    # (Document expected costs for each nise scenario)
    assert total_cost > 0, "Cost should be non-zero"

    # TODO: Add specific assertions once we document nise scenarios
    # assert total_cost == EXPECTED_TOTAL, f"Expected ${EXPECTED_TOTAL}, got ${total_cost}"
```

---

## Nise Scenarios & Expected Costs

### Need to Document:

1. **AWS Default Scenario**
   - Resources: ?
   - Expected total: $???
   - Expected by service: ?
   - Expected by tag: ?

2. **Azure Default Scenario**
   - Resources: ?
   - Expected total: $???
   - Expected by resource group: ?

3. **GCP Default Scenario**
   - Resources: ?
   - Expected total: $???
   - Expected by project: ?

**Action**: Run nise manually, inspect output, document expected totals

---

## Implementation Steps

### Step 1: Revert Hardcoded Approach ✅
1. ✅ Update `upload_aws_cur_format()` to use nise
2. ✅ Update `upload_azure_export_format()` to use nise properly
3. ✅ Update `upload_gcp_export_format()` to use nise properly

### Step 2: Run Tests & Document Scenarios ⏳
1. ⏳ Run AWS E2E test with nise
2. ⏳ Document AWS nise output (costs, resources)
3. ⏳ Run Azure E2E test with nise
4. ⏳ Document Azure nise output
5. ⏳ Run GCP E2E test with nise
6. ⏳ Document GCP nise output

### Step 3: Add Financial Validation ⏳
1. ⏳ Add cost total assertions to IQE tests
2. ⏳ Add aggregation assertions (by service, tag, etc.)
3. ⏳ Document expected costs for each scenario

---

## Timeline Estimate

| Task | Time | Status |
|------|------|--------|
| Revert hardcoded AWS | 10 min | ⏳ In progress |
| Revert hardcoded Azure/GCP | 10 min | ⏳ Pending |
| Run AWS E2E + document | 20 min | ⏳ Pending |
| Run Azure E2E + document | 20 min | ⏳ Pending |
| Run GCP E2E + document | 20 min | ⏳ Pending |
| Add financial validation | 30 min | ⏳ Pending |
| **Total** | **~2 hours** | |

---

## Success Criteria

### For Each Provider (AWS, Azure, GCP):

1. ✅ **Nise generates data** (1-5 min accepted)
2. ✅ **Data uploads to S3**
3. ✅ **MASU processes successfully**
4. ✅ **Trino tables created**
5. ✅ **API returns data**
6. ✅ **IQE tests validate structure** (current tests)
7. ✅ **IQE tests validate costs** (new assertions)

### Migration Validation Ready:

```bash
# Current architecture (Trino+Hive+Postgres)
./e2e-validate.sh --provider-type AWS
→ Total cost: $X.XX ✅

# After migration (Pure Postgres)
./e2e-validate.sh --provider-type AWS
→ Total cost: $X.XX ✅

# If X == X → Migration successful ✅
```

---

## Key Insight

**"Fast but wrong" is worse than "slow but correct".**

The hardcoded approach:
- ✅ Fast (instant)
- ❌ Wrong (no financial validation)
- ❌ Blocks migration validation

The nise approach:
- ✅ Correct (controlled scenarios)
- ✅ Enables financial validation
- ✅ Enables migration validation
- ⏳ Slower (1-5 min per provider = 15 min total for 3 providers)

**Trade-off accepted** ✅

---

**Created**: November 19, 2025
**Status**: Implementation in progress
**Blocking**: Migration validation, financial correctness testing

