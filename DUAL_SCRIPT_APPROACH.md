# Dual E2E Testing Strategy: OCP-Only vs All-Providers

**Date:** 2025-11-19
**Purpose:** Maintain two parallel E2E test scripts for different use cases

---

## Overview

We maintain **two E2E validation scripts** with different scopes:

| Script | Scope | Use Case | Priority |
|--------|-------|----------|----------|
| **`ocp-e2e-validate.sh`** | OCP only | Production readiness testing | ⭐ Priority 1 |
| **`e2e-validate.sh`** | All providers (AWS/Azure/GCP/OCP) | Future SQL migration testing | Priority 2 |

---

## Why Two Scripts?

### Strategic Decision

**First releases will support OCP providers only.**

However, we're planning future work to replace Trino with direct PostgreSQL queries for hyperscaler providers (AWS/Azure/GCP). To prepare for this migration:

- ✅ **Keep existing multi-cloud code** for future SQL migration testing
- ✅ **Create focused OCP-only script** for immediate production needs
- ✅ **Avoid code duplication** - both scripts use the same Python framework

---

## Script Comparison

### `ocp-e2e-validate.sh` (OCP-Only) ⭐

**Purpose:** Production readiness validation for OCP deployments

**Usage:**
```bash
# Smoke test (fast, ~30-60 seconds)
./scripts/ocp-e2e-validate.sh --smoke-test --force

# Full validation with nise (~3-5 minutes)
./scripts/ocp-e2e-validate.sh --force

# Skip IQE tests
./scripts/ocp-e2e-validate.sh --smoke-test --skip-tests --force
```

**What It Tests:**
- ✅ OCP provider creation
- ✅ OCP pod_usage.csv & storage_usage.csv upload
- ✅ Trino table creation (openshift_pod_usage_line_items_daily, etc.)
- ✅ PostgreSQL summary population via Trino
- ✅ OCP-specific API endpoints
- ✅ IQE tests for OCP

**Data Modes:**
1. **Smoke Test (`--smoke-test`):** 4-pod minimal CSV (fast)
2. **Full Validation:** Nise-generated realistic OCP data

**Benefits:**
- 🚀 Fast feedback loop
- ✅ Focused on production requirements
- 📝 Simpler logs (no multi-cloud noise)
- 🎯 Clear pass/fail for OCP functionality

---

### `e2e-validate.sh` (All Providers)

**Purpose:** Comprehensive multi-cloud testing for future SQL migration work

**Usage:**
```bash
# AWS smoke test
./scripts/e2e-validate.sh --provider-type AWS --smoke-test --force

# OCP full validation
./scripts/e2e-validate.sh --provider-type OCP --force

# Azure with nise
./scripts/e2e-validate.sh --provider-type Azure --force

# GCP validation
./scripts/e2e-validate.sh --provider-type GCP --force
```

**What It Tests:**
- ✅ All provider types (AWS, Azure, GCP, OCP)
- ✅ Provider-specific data formats
- ✅ Trino table creation for all providers
- ✅ Multi-cloud data processing
- ✅ Cross-provider API validation

**Data Modes:**
1. **Smoke Test (`--smoke-test`):**
   - AWS: 4-row AWS CUR CSV (130+ columns)
   - OCP: 4-pod minimal CSV (20 columns)
   - Azure/GCP: Not yet implemented

2. **Full Validation:**
   - All providers: Nise-generated realistic data

**Benefits:**
- 🔬 Comprehensive coverage for SQL migration testing
- 🔄 Validates multi-cloud data processing
- 📊 Useful for regression testing after Koku changes
- 🧪 Ensures code works for all provider types

**Current Status:**
- ✅ AWS: Fully implemented (smoke + nise)
- ✅ OCP: Fully implemented (smoke + nise)
- ⚠️ Azure: Nise only (no smoke test yet)
- ⚠️ GCP: Nise only (no smoke test yet)

---

## Technical Implementation

### Shared Python Framework

Both scripts use the same underlying Python modules:

```
scripts/
├── e2e-validate.sh              # Multi-cloud wrapper
├── ocp-e2e-validate.sh          # OCP-only wrapper
└── e2e_validator/
    ├── cli.py                   # Shared CLI logic
    ├── phases/
    │   ├── preflight.py         # Shared
    │   ├── provider.py          # Shared
    │   ├── data_upload.py       # Shared (routes by provider_type)
    │   ├── processing.py        # Shared
    │   └── iqe_tests.py         # Shared
    └── clients/
        ├── kubernetes.py        # Shared
        ├── database.py          # Shared
        ├── s3.py                # Shared
        └── nise.py              # Shared
```

**Key Point:** No code duplication! Both scripts call the same Python code with different parameters.

---

## Data Generation Details

### OCP Data Format (Simpler!)

**Smoke Test CSV (4 pods):**

```csv
# pod_usage.csv
report_period_start,report_period_end,interval_start,interval_end,namespace,pod,node,resource_id,pod_usage_cpu_core_seconds,pod_request_cpu_core_seconds,pod_limit_cpu_core_seconds,pod_usage_memory_byte_seconds,pod_request_memory_byte_seconds,pod_limit_memory_byte_seconds,node_capacity_cpu_cores,node_capacity_memory_bytes,resource_id_matched,cluster_id,cluster_alias,node_role,pod_labels
2024-11-01 00:00:00+00:00,2024-11-30 23:59:59+00:00,2024-11-01 00:00:00+00:00,2024-11-01 01:00:00+00:00,openshift-apiserver,apiserver-abc123,master-1,i-master1,3600,3600,7200,4294967296,4294967296,8589934592,4,17179869184,True,test-cluster-123,smoke-test-cluster,master,{"app":"apiserver","tier":"control-plane"}
...
```

```csv
# storage_usage.csv
report_period_start,report_period_end,interval_start,interval_end,namespace,pod,persistentvolumeclaim,persistentvolume,storageclass,persistentvolumeclaim_capacity_bytes,persistentvolumeclaim_capacity_byte_seconds,volume_request_storage_byte_seconds,persistentvolumeclaim_usage_byte_seconds,persistentvolume_labels,persistentvolumeclaim_labels,cluster_id,cluster_alias
2024-11-01 00:00:00+00:00,2024-11-30 23:59:59+00:00,2024-11-01 00:00:00+00:00,2024-11-01 01:00:00+00:00,openshift-monitoring,prometheus-ghi012,prometheus-pvc,pv-prometheus-123,gp2,10737418240,38654705664000,38654705664000,5368709120000,{},{"app":"prometheus"},test-cluster-123,smoke-test-cluster
...
```

**Only 20 columns vs 130+ for AWS CUR!**

**Nise-Generated (Full):**
- Multiple days of pod usage
- Realistic node capacity and usage patterns
- Storage volumes with actual usage
- Node labels and pod labels
- Multiple namespaces and workloads

---

### AWS Data Format (Complex)

**Smoke Test CSV (4 rows):**

```csv
# AWS CUR format - 130+ columns!
identity/LineItemId,identity/TimeInterval,bill/InvoiceId,bill/BillingEntity,bill/BillType,bill/PayerAccountId,...
e6fce739e6bcb6ce,2024-11-01T00:00:00Z/2024-11-01T01:00:00Z,12345678,AWS,Anniversary,123456789012,...
```

**Covers:**
- EC2 instance (t3.micro)
- S3 storage
- RDS instance (db.t3.micro)
- Data transfer

**Nise-Generated (Full):**
- Realistic AWS CUR data
- Multiple resource types
- Tags and cost allocation
- Reserved instances and savings plans

---

## When to Use Which Script

### Use `ocp-e2e-validate.sh` For:

✅ **Production readiness checks** before OCP release
✅ **CI/CD pipelines** for OCP deployment
✅ **Daily validation** of OCP functionality
✅ **Customer-facing demos** (fast, focused)
✅ **Troubleshooting OCP-specific issues**

### Use `e2e-validate.sh` For:

✅ **SQL migration testing** (future work)
✅ **Regression testing** after Koku code changes
✅ **Multi-cloud validation** (if/when supported)
✅ **Cross-provider comparison testing**
✅ **Comprehensive pre-release validation**

---

## Example Workflows

### Typical Development Flow (OCP Focus)

```bash
# 1. Quick smoke test after code change
./scripts/ocp-e2e-validate.sh --smoke-test --force

# 2. Full validation before commit
./scripts/ocp-e2e-validate.sh --force

# 3. Pre-release comprehensive test (optional)
./scripts/e2e-validate.sh --provider-type OCP --force
```

### SQL Migration Testing (Future)

```bash
# Test all providers with SQL-based aggregation (future)
./scripts/e2e-validate.sh --provider-type AWS --force
./scripts/e2e-validate.sh --provider-type Azure --force
./scripts/e2e-validate.sh --provider-type GCP --force
./scripts/e2e-validate.sh --provider-type OCP --force
```

---

## Maintenance Strategy

### Adding Features

**For OCP-specific features:**
1. Update shared Python modules (`data_upload.py`, `processing.py`, etc.)
2. Test with `ocp-e2e-validate.sh`
3. Optionally test with `e2e-validate.sh --provider-type OCP` for comprehensive validation

**For multi-cloud features:**
1. Update shared Python modules
2. Test with `e2e-validate.sh` for all providers
3. Verify OCP still works with `ocp-e2e-validate.sh`

### Deprecation Plan

**When SQL migration is complete:**
- ✅ Keep `ocp-e2e-validate.sh` (OCP still needs Trino)
- ✅ Update `e2e-validate.sh` to test SQL-based aggregation for AWS/Azure/GCP
- ✅ Remove Trino table creation workarounds for hyperscalers
- ✅ Keep Trino table creation workaround for OCP

---

## Performance Comparison

| Scenario | OCP-Only Script | All-Providers Script |
|----------|----------------|---------------------|
| **Smoke Test** | ~30 seconds | ~40 seconds |
| **Full Validation** | ~3-5 minutes | ~5-10 minutes |
| **Log Verbosity** | Low (OCP only) | High (all providers) |
| **Failure Isolation** | Easy (single provider) | Harder (multi-provider) |

---

## Summary

| Aspect | OCP-Only | All-Providers |
|--------|----------|--------------|
| **Purpose** | Production readiness | SQL migration testing |
| **Priority** | ⭐ Priority 1 | Priority 2 |
| **Scope** | OCP only | AWS/Azure/GCP/OCP |
| **Speed** | Faster | Slower |
| **Complexity** | Simple | Complex |
| **Use in CI/CD** | ✅ Yes | ⚠️ Optional |
| **Customer-facing** | ✅ Yes | ❌ No |

**Bottom Line:** Use `ocp-e2e-validate.sh` for day-to-day work. Keep `e2e-validate.sh` for future SQL migration testing.

