# Hive Metastore Triage Report

**Date**: November 6, 2025
**Status**: ⚠️ **NON-CRITICAL** - Not blocking Koku functionality
**Priority**: **P3 - Low** (Can be fixed later)

---

## Executive Summary

**Current State**:
- ❌ Hive Metastore: CrashLoopBackOff (14 restarts)
- ✅ Koku API: 3/3 Ready and responding
- ✅ Celery Workers: 12/12 Running and processing
- ✅ Trino Cluster: Coordinator + Worker Running
- **No functional impact observed**

**Recommendation**: **DEFER FIX** - Not required for current Koku functionality

---

## Problem Analysis

### Root Causes Identified

#### 1. **Read-Only Filesystem Issue**

**Error**:
```
cp: cannot create regular file '/opt/hive-metastore/conf/metastore-site.xml': Read-only file system
```

**Cause**:
- ConfigMap mounted as `subPath` at line 78-79 of deployment.yaml
- ConfigMap mounts are read-only in Kubernetes
- Startup script (lines 52-53) tries to `sed` and copy back to same location

**Current Code (Broken)**:
```bash
# Line 52-53
sed "s/METASTORE_DB_PASSWORD/$METASTORE_DB_PASSWORD/g" \
  /opt/hive-metastore/conf/metastore-site.xml > /tmp/metastore-site.xml
cp /tmp/metastore-site.xml /opt/hive-metastore/conf/metastore-site.xml  # FAILS
```

**Fix Needed**: Use environment variable substitution in ConfigMap or mount config to /tmp

---

#### 2. **Missing Binaries**

**Errors**:
```
/bin/sh: 6: /opt/hive-metastore/bin/schematool: not found
/bin/sh: 9: /opt/hive-metastore/bin/start-metastore: not found
```

**Cause**:
- Image: `quay.io/insights-onprem/hive:3.1.3` (mirrored from `docker.io/apache/hive:3.1.3`)
- This is the **full Hive distribution** image, not the standalone Metastore image
- Binaries are likely at different paths or don't exist in this image variant

**Investigation Needed**:
- Check actual binary locations in the image: `/opt/hive/bin/` vs `/opt/hive-metastore/bin/`
- Verify if `apache/hive:3.1.3` includes standalone metastore service
- May need different image: `apache/hive-metastore:3.1.3` or build custom image

---

## Impact Assessment

### Current Impact: ✅ **NONE**

**Evidence**:
1. ✅ **Koku API is fully functional** (3/3 pods Ready)
2. ✅ **All Celery workers running** (12/12 operational)
3. ✅ **Trino Coordinator is Running** (no errors about Hive Metastore)
4. ✅ **No errors in Trino logs** about missing Hive catalog
5. ✅ **Database queries working** (PostgreSQL catalog functioning)

**Why it's not needed yet**:
- Koku may not be processing Parquet data yet (no cost data ingested)
- Trino's PostgreSQL catalog is working for database queries
- Hive catalog (for Parquet/S3 data) only needed when:
  - Cost data is uploaded to object storage (MinIO/ODF)
  - Workers create Parquet tables
  - API queries historical data from Parquet files

---

### Future Impact: ⚠️ **MEDIUM**

**Will be required when**:
1. **Cost data ingestion starts** - Workers upload Parquet files to S3
2. **Historical queries needed** - API queries Parquet data via Trino
3. **Large dataset processing** - Moving data from PostgreSQL to Parquet
4. **Production workload** - Real cost management operations

**Timeline**: Needed within **2-4 weeks** of production use

---

## Recommended Fix

### Option 1: **Quick Fix** (30 minutes) ⭐ **RECOMMENDED**

**Fix the startup script**:

```yaml
# In deployment.yaml, lines 47-59:
command:
  - /bin/sh
  - -c
  - |
    # Create writable config directory
    mkdir -p /tmp/hive-conf

    # Copy and modify config (read from ConfigMap, write to /tmp)
    sed "s/METASTORE_DB_PASSWORD/$METASTORE_DB_PASSWORD/g" \
      /config-template/metastore-site.xml > /tmp/hive-conf/metastore-site.xml

    # Export config location
    export METASTORE_HOME=/tmp/hive-conf

    # Use correct binary paths (check image first!)
    /opt/hive/bin/schematool -dbType postgres -initSchema || true
    /opt/hive/bin/hive --service metastore
```

**Changes needed**:
1. Mount ConfigMap to `/config-template` instead of `/opt/hive-metastore/conf`
2. Write processed config to `/tmp/hive-conf` (writable)
3. Update binary paths (likely `/opt/hive/bin/` not `/opt/hive-metastore/bin/`)
4. Update volumeMounts in deployment.yaml

---

### Option 2: **Use Environment Variables** (1 hour)

**Avoid sed entirely**:

1. Update ConfigMap to use environment variable placeholders that Hive understands
2. Configure Hive to read from environment variables
3. Pass `METASTORE_DB_PASSWORD` directly to Hive

**Pros**: Cleaner, no file manipulation needed
**Cons**: Requires understanding Hive's env var support

---

### Option 3: **Use Correct Image** (2 hours)

**Switch to standalone metastore image**:

```yaml
image:
  repository: apache/hive  # Try the official standalone variant
  tag: "3.1.3-standalone-metastore"  # If it exists
```

Or build custom image:
```dockerfile
FROM apache/hive:3.1.3
# Configure for standalone metastore service
# Add startup script
```

**Pros**: Purpose-built for metastore service
**Cons**: More research needed, may not exist

---

## Priority Justification

### Why P3 (Low Priority)?

1. ✅ **All critical components working** - API, workers, databases operational
2. ✅ **No user-facing impact** - Koku is functional for testing
3. ⏰ **Time-sensitive milestone** - Focus on getting Koku validated first
4. 🎯 **Can be fixed incrementally** - When Parquet data processing is needed
5. 📊 **Easy to detect when needed** - Will see Trino errors when workers try to create Hive tables

### When to Escalate to P1?

- ❌ Workers fail when processing cost data
- ❌ API returns errors for historical queries
- ❌ Production deployment imminent
- ❌ Data ingestion pipeline blocked

---

## Testing Strategy

### Verify Impact (5 minutes)

**Test if Hive Metastore is actually needed right now**:

```bash
# 1. Check Trino catalogs
oc exec -n cost-mgmt cost-mgmt-cost-management-onprem-trino-coordinator-0 -- \
  trino --execute "SHOW CATALOGS"

# Expected: Only "system" and "postgresql" catalogs (no "hive")

# 2. Try to query Hive catalog (should fail)
oc exec -n cost-mgmt cost-mgmt-cost-management-onprem-trino-coordinator-0 -- \
  trino --execute "SHOW SCHEMAS FROM hive"

# Expected: Error about Hive catalog not available

# 3. Check if workers are trying to use Hive
oc logs -n cost-mgmt -l celery-type=worker | grep -i "hive\|metastore"

# Expected: No errors (yet)
```

---

## Deployment Decision Tree

```
Is Koku API working?
├─ YES → Is cost data being ingested?
│         ├─ NO → ✅ DEFER Hive Metastore fix (current state)
│         └─ YES → Are workers creating Parquet tables?
│                   ├─ NO → ⚠️  Monitor logs
│                   └─ YES → ❌ FIX IMMEDIATELY (P1)
└─ NO → Fix API first (higher priority)
```

**Current State**: **DEFER** ✅

---

## Next Steps

### Immediate (Now):
1. ✅ **Document issue** (this report)
2. ✅ **Continue with Koku validation**
3. ✅ **Monitor for Hive-related errors**

### Short-term (1-2 weeks):
1. 🔍 **Inspect Hive image** - Find correct binary paths
2. 🔧 **Implement Option 1 fix** - Update startup script
3. ✅ **Test Hive Metastore** - Verify it can start
4. 🧪 **Test Trino Hive catalog** - Create test table

### Medium-term (3-4 weeks):
1. 📊 **Ingest sample cost data** - Test full pipeline
2. ✅ **Verify Parquet table creation** - Workers use Hive
3. 🚀 **Production readiness** - All components operational

---

## Code Changes Required

### File: `cost-management-onprem/templates/trino/metastore/deployment.yaml`

**Current (Broken)**:
```yaml
volumeMounts:
- name: config
  mountPath: /opt/hive-metastore/conf/metastore-site.xml
  subPath: metastore-site.xml  # Read-only!
- name: tmp
  mountPath: /tmp
```

**Fixed**:
```yaml
volumeMounts:
- name: config
  mountPath: /config-template  # Mount entire ConfigMap here
- name: hive-conf
  mountPath: /opt/hive-metastore/conf  # Writable location
- name: tmp
  mountPath: /tmp

volumes:
- name: config
  configMap:
    name: {{ include "cost-mgmt.trino.metastore.name" . }}-config
- name: hive-conf
  emptyDir: {}  # Writable volume for processed config
- name: tmp
  emptyDir: {}
```

**Command (lines 47-59)**:
```yaml
command:
  - /bin/sh
  - -c
  - |
    # Process config template
    sed "s/METASTORE_DB_PASSWORD/$METASTORE_DB_PASSWORD/g" \
      /config-template/metastore-site.xml > /opt/hive-metastore/conf/metastore-site.xml

    # Initialize schema (use correct path!)
    /opt/hive/bin/schematool -dbType postgres -initSchema || true

    # Start metastore (use correct path!)
    /opt/hive/bin/hive --service metastore
```

**Note**: Binary paths `/opt/hive/bin/` are **assumed** - need to verify in actual image!

---

## Estimated Effort

| Task | Time | Priority | Blocker? |
|------|------|----------|----------|
| Research correct image/paths | 30 min | P3 | No |
| Fix deployment.yaml | 15 min | P3 | No |
| Test Hive Metastore startup | 15 min | P3 | No |
| Verify Trino Hive catalog | 15 min | P3 | No |
| **Total** | **1.5 hours** | **P3** | **No** |

---

## Conclusion

**Verdict**: ⚠️ **DEFER FIX - Not blocking current work**

**Rationale**:
1. Koku API and workers are **fully operational** without Hive Metastore
2. Component will be needed for **production data processing**, not initial validation
3. Fix is **straightforward** (1-2 hours) when needed
4. **No errors observed** in Trino or worker logs
5. Current focus should be on **validating Koku functionality**, not optimizing all components

**Recommendation**:
- ✅ **Mark as "Known Issue" in deployment docs**
- ✅ **Continue with Koku API/worker testing**
- 🔜 **Fix before data ingestion testing** (Week 2-3)
- 📊 **Monitor logs for Hive-related errors**

---

**Status**: **Triaged - P3 (Low Priority)** ✅

