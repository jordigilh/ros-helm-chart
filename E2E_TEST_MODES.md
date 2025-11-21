# E2E Test Modes: Smoke Test vs Full Validation

**Updated:** 2025-11-19
**Purpose:** Document the two modes of E2E validation for Cost Management on-prem

---

## Overview

The E2E validation suite supports two modes:

| Mode | Data Generation | Purpose | Duration | Use Case |
|------|----------------|---------|----------|----------|
| **Smoke Test** | Hardcoded 4-row CSV | Verify pipeline works end-to-end | ~30-60 seconds | CI/CD, quick sanity checks |
| **Full Validation** | Nise-generated data | Financial correctness validation | ~5-10 minutes | Pre-release testing, regression tests |

---

## Smoke Test Mode 🚀

### When to Use
- **CI/CD pipelines:** Fast feedback on deployment issues
- **Development iterations:** Quick validation during development
- **Sanity checks:** Verify basic pipeline functionality after config changes
- **Infrastructure validation:** Confirm Trino + Hive + PostgreSQL are working

### What It Tests
✅ S3 upload works
✅ MASU downloads and processes files
✅ CSV → Parquet conversion succeeds
✅ Trino/Hive tables are created
✅ Summary tables are populated
✅ API endpoints return data

❌ Does NOT validate financial accuracy
❌ Does NOT test cost calculations
❌ Does NOT verify IQE financial correctness tests

### How to Run
```bash
./scripts/e2e-validate.sh \
  --namespace cost-mgmt \
  --provider-type AWS \
  --smoke-test \
  --force
```

### Data Generated

**4-row minimal AWS CUR CSV:**
- 1 EC2 instance (t3.micro): $0.0104
- 1 S3 storage: $0.0298
- 1 RDS instance (db.t3.micro): $0.017
- 1 Data transfer: $0.01

**Total cost:** ~$0.07

**Coverage:** EC2, S3, RDS, Data Transfer (essential AWS services)

### Performance
- Data generation: **~1 second**
- Full E2E flow: **~30-60 seconds** (depending on cluster performance)

---

## Full Validation Mode 🔬

### When to Use
- **Pre-release testing:** Validate before promoting to production
- **Regression testing:** Ensure changes don't break cost calculations
- **IQE test suite:** Run comprehensive financial validation tests
- **Provider validation:** Test AWS, Azure, GCP data flows

### What It Tests
✅ Everything smoke test validates
✅ Financial correctness (nise scenarios)
✅ Cost calculations and aggregations
✅ IQE financial validation tests
✅ Multi-day/multi-month data
✅ Tag/label processing

### How to Run
```bash
./scripts/e2e-validate.sh \
  --namespace cost-mgmt \
  --provider-type AWS \
  --force
```

**Note:** Omit `--smoke-test` to use full validation mode (default).

### Data Generated

**Nise-generated realistic AWS CUR data:**
- Multiple days of usage
- Realistic product codes and usage types
- Proper AWS CUR column format
- Tag/label data
- Multiple resource types

**Coverage:** Comprehensive AWS CUR format validation

### Performance
- Data generation (nise): **~1-5 minutes**
- Full E2E flow: **~5-10 minutes** (depending on cluster performance and data size)

---

## Comparison Table

| Aspect | Smoke Test | Full Validation |
|--------|------------|----------------|
| **Data Source** | Hardcoded CSV | Nise generator |
| **Data Size** | 4 rows | Hundreds to thousands of rows |
| **Generation Time** | ~1 second | ~1-5 minutes |
| **Total E2E Time** | ~30-60 seconds | ~5-10 minutes |
| **Financial Accuracy** | ❌ No | ✅ Yes |
| **IQE Tests** | ⚠️ Infrastructure only | ✅ Full suite |
| **Use in CI/CD** | ✅ Recommended | ⚠️ Only on critical branches |
| **Cost Validation** | ❌ No | ✅ Yes |
| **Tag/Label Testing** | ❌ No | ✅ Yes |

---

## E2E Script Behavior

### Smoke Test Mode (`--smoke-test`)

**Phase 1: Preflight** ✅
- Check Kubernetes connectivity
- Check database connectivity
- Check S3 connectivity

**Phase 2: Provider Setup** ✅
- Create provider via Django ORM
- Provision tenant schema

**Phase 3: Data Upload** ⚡ **FAST**
- Generate 4-row CSV in memory (~1 second)
- Upload directly to S3

**Phase 4: Processing** ✅
- MASU downloads CSV
- Converts to Parquet
- Creates Trino tables (with workaround)
- Populates summary tables

**Phase 5: IQE Tests** ⚠️ **LIMITED**
- Infrastructure validation only
- Table existence checks
- API accessibility

### Full Validation Mode (default)

**Phase 1: Preflight** ✅
- Same as smoke test

**Phase 2: Provider Setup** ✅
- Same as smoke test

**Phase 3: Data Upload** 🐢 **SLOW**
- Run nise to generate realistic data (~1-5 minutes)
- Upload all generated files to S3

**Phase 4: Processing** ✅
- Same as smoke test (just more data)

**Phase 5: IQE Tests** ✅ **COMPREHENSIVE**
- Infrastructure validation
- Financial correctness tests
- Cost calculation validation
- API response format verification

---

## CLI Options

```bash
# Smoke test mode (fast)
./scripts/e2e-validate.sh --smoke-test --force

# Full validation mode (default)
./scripts/e2e-validate.sh --force

# Smoke test with specific provider
./scripts/e2e-validate.sh --provider-type Azure --smoke-test --force

# Skip phases in smoke test
./scripts/e2e-validate.sh --smoke-test --skip-tests --force
```

---

## Implementation Details

### Smoke Test Data Generation

**File:** `scripts/e2e_validator/phases/data_upload.py`
**Method:** `_generate_minimal_aws_csv()`

```python
def _generate_minimal_aws_csv(self, start_date, end_date) -> str:
    """Generate minimal AWS CUR CSV for smoke tests (fast!)

    Returns CSV with 4 rows covering essential columns for pipeline testing.
    This is NOT for financial validation - use nise for that.
    """
    # Returns hardcoded CSV with:
    # - EC2 instance
    # - S3 storage
    # - RDS instance
    # - Data transfer
```

### Mode Selection

```python
# In upload_aws_cur_format()
if smoke_test:
    # SMOKE TEST MODE: Fast 4-row hardcoded CSV
    csv_content = self._generate_minimal_aws_csv(start_date, end_date)
    self.s3.put_object(Bucket=bucket, Key=csv_key, Body=csv_content.encode('utf-8'))
else:
    # FULL VALIDATION MODE: Nise-generated data
    output_dir = self.nise.generate_aws_cur(start_date, end_date)
    # Upload all nise-generated files
```

---

## Best Practices

### Use Smoke Test For:
- ✅ PR validation in CI/CD
- ✅ Quick local development testing
- ✅ Infrastructure deployment validation
- ✅ Pod restart/upgrade sanity checks

### Use Full Validation For:
- ✅ Release candidate testing
- ✅ Before merging to main/master
- ✅ Monthly regression testing
- ✅ Provider-specific validation
- ✅ API contract validation

### Never Use Smoke Test For:
- ❌ Financial accuracy verification
- ❌ Cost calculation correctness
- ❌ IQE financial validation
- ❌ Customer-facing validation

---

## Troubleshooting

### Smoke Test Fails, Full Validation Passes
**Cause:** Likely data format issue in hardcoded CSV
**Action:** Update `_generate_minimal_aws_csv()` to match nise format

### Full Validation Times Out
**Cause:** Nise generation takes too long or cluster is overloaded
**Action:** Use `--smoke-test` for quick validation, run full validation off-hours

### IQE Tests Pass in Smoke, Fail in Full
**Cause:** Financial validation tests require realistic data
**Action:** This is expected - IQE financial tests should only run in full validation mode

---

## Summary

**Smoke Test:** Fast, lightweight, infrastructure validation
**Full Validation:** Slow, comprehensive, financial correctness validation

**Choose wisely based on your testing goals!** 🎯

