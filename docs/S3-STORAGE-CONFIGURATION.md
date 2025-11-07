# S3 Storage Configuration - Current State Analysis

**Date**: November 7, 2025
**Status**: ⚠️ **S3 Access Not Working** - Will fail during integration testing

---

## Executive Summary

**Finding**: Trino is configured to use `http://minio:9000` but **no MinIO service exists**. When integration testing starts and Koku tries to write Parquet files to S3, it will fail.

**Solution**: Reconfigure Trino to use **ODF NooBaa S3-compatible storage** at `http://s3.openshift-storage.svc:80`

---

## Current Configuration

### What's Configured

```bash
# Trino Coordinator Environment
HADOOP_S3A_ENDPOINT=http://minio:9000  # ❌ DOES NOT EXIST
HADOOP_S3A_PATH_STYLE_ACCESS=true
HADOOP_S3A_SSL_ENABLED=false
```

### What Actually Exists

```bash
# ODF NooBaa S3 Service
Service: s3.openshift-storage.svc
Port: 80 (HTTP)
Credentials: noobaa-admin secret (already configured ✅)
```

### Verification

```bash
$ oc get svc -A | grep -E "minio|s3"
openshift-storage  s3  LoadBalancer  172.30.98.14  80:30563/TCP  ✅

$ oc get svc -n cost-mgmt minio
Error: service "minio" not found  ❌
```

---

## Why It's "Working" Right Now

Trino appears operational because:

1. ✅ **Hive Metastore is running** - Stores metadata in PostgreSQL
2. ✅ **Trino can connect to Hive Metastore** - Queries metadata successfully
3. ✅ **No S3 operations have been attempted yet** - No tables exist

**Test Results**:
```sql
SHOW SCHEMAS FROM hive;
-- Returns: "default", "information_schema"  ✅

SHOW TABLES FROM hive.default;
-- Returns: (empty)  ⚠️ No tables = No S3 access tested yet
```

---

## When It Will Break

S3 access will fail when:

1. **Koku workers process cost data** → Write Parquet files to S3
2. **Koku creates Hive tables** → Table locations point to S3
3. **Trino queries data** → Tries to read from S3
4. **Integration testing starts** → Upload payload → Celery workers → S3 write

**Expected Error**:
```
UnknownHostException: minio: Name or service not known
Connection refused: minio:9000
```

---

## Architecture: Trino + ODF (No MinIO Needed)

### What is MinIO?

**MinIO** = Open-source, self-hosted, S3-compatible object storage

### What is ODF NooBaa?

**OpenShift Data Foundation (ODF)** = Red Hat's storage solution
**NooBaa** = S3-compatible object storage component of ODF

### Do We Need MinIO?

**NO!** ❌

- **MinIO** is ONE implementation of S3-compatible storage
- **ODF NooBaa** is ANOTHER implementation of S3-compatible storage
- **Trino doesn't care** - it just needs an S3-compatible API

---

## How S3 Storage Works

```
┌─────────────────────────────────────────────────────────────┐
│                     Koku Workers                            │
│  1. Process cost data                                       │
│  2. Generate Parquet files                                  │
│  3. Upload to S3 (via AWS SDK)                             │
└────────────────┬────────────────────────────────────────────┘
                 │
                 │ PUT /bucket/path/file.parquet
                 ▼
┌─────────────────────────────────────────────────────────────┐
│              ODF NooBaa (S3-Compatible API)                 │
│  • Endpoint: http://s3.openshift-storage.svc:80            │
│  • Credentials: noobaa-admin secret                         │
│  • Storage: Ceph RBD (block devices) ✅                     │
└────────────────┬────────────────────────────────────────────┘
                 │
                 │ Stores as blocks
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                    Ceph Storage Cluster                     │
│  • Block devices (RBD)                                      │
│  • Distributed, replicated                                  │
│  • Managed by ODF                                           │
└─────────────────────────────────────────────────────────────┘

LATER: Trino reads data
┌─────────────────────────────────────────────────────────────┐
│                   Trino (Query Engine)                      │
│  1. Gets metadata from Hive Metastore                       │
│  2. Finds S3 location (s3://bucket/path/)                   │
│  3. Reads Parquet files via S3 API                          │
└────────────────┬────────────────────────────────────────────┘
                 │
                 │ GET /bucket/path/file.parquet
                 ▼
┌─────────────────────────────────────────────────────────────┐
│              ODF NooBaa (S3-Compatible API)                 │
│  • Returns data from Ceph                                   │
└─────────────────────────────────────────────────────────────┘
```

### Key Points

1. **ODF uses block devices (Ceph RBD)** for underlying storage ✅
2. **NooBaa exposes S3 API** on top of Ceph ✅
3. **Applications see S3**, not block devices ✅
4. **No MinIO needed** - NooBaa provides the same functionality ✅

---

## What Needs to Be Fixed

### 1. Update Trino S3 Endpoint

**Current** (broken):
```yaml
env:
  - name: HADOOP_S3A_ENDPOINT
    value: "http://minio:9000"
```

**Fixed**:
```yaml
env:
  - name: HADOOP_S3A_ENDPOINT
    value: "http://s3.openshift-storage.svc:80"
```

### 2. Update Koku S3 Configuration

**Check**: Does Koku also have hardcoded MinIO endpoint?

Location to verify: `costManagement.api.reads.env.S3_ENDPOINT`

### 3. Make It Configurable

**Problem**: Currently hardcoded in `_helpers.tpl`:

```yaml
{{- define "cost-mgmt.storage.endpoint" -}}
{{- printf "http://minio:9000" -}}
{{- end -}}
```

**Solution**: Move to `values.yaml`:

```yaml
infrastructure:
  storage:
    # S3-compatible object storage endpoint
    # For ODF: http://s3.openshift-storage.svc:80
    # For MinIO: http://minio:9000
    endpoint: "http://s3.openshift-storage.svc:80"

    # Credentials secret (ODF uses noobaa-admin)
    credentialsSecret:
      name: "noobaa-admin"
      accessKeyKey: "AWS_ACCESS_KEY_ID"
      secretKeyKey: "AWS_SECRET_ACCESS_KEY"
```

---

## Testing S3 Access

Once fixed, test with:

```bash
# 1. Create a test table in Trino pointing to S3
oc exec -it cost-mgmt-...-trino-coordinator-0 -- trino

CREATE SCHEMA IF NOT EXISTS hive.test;

CREATE TABLE hive.test.sample (
    id INT,
    name VARCHAR
)
WITH (
    format = 'PARQUET',
    external_location = 's3a://koku-report/test/'
);

# 2. Try to insert data (will test S3 write)
INSERT INTO hive.test.sample VALUES (1, 'test');

# 3. Try to query (will test S3 read)
SELECT * FROM hive.test.sample;
```

**Expected result after fix**: ✅ Success
**Current result**: ❌ "minio: Name or service not found"

---

## Comparison: MinIO vs ODF NooBaa

| Feature | MinIO (Self-Hosted) | ODF NooBaa (Integrated) |
|---------|---------------------|-------------------------|
| **S3 API** | ✅ Yes | ✅ Yes |
| **Deployment** | Separate pod/service | Integrated with ODF |
| **Storage Backend** | Local disks, PVs | Ceph (block + object) |
| **High Availability** | Requires multi-node setup | Built-in (Ceph replication) |
| **Resource Usage** | ~500MB RAM per pod | Shared with ODF (efficient) |
| **Maintenance** | Manual upgrades | ODF operator manages |
| **Integration** | Manual | Native OpenShift |
| **Cost** | Free (self-managed) | Included with ODF |

**For OpenShift**: **ODF NooBaa is the better choice** ✅

---

## Files to Update

1. **`templates/_helpers.tpl`** - Fix `cost-mgmt.storage.endpoint` helper
2. **`templates/trino/coordinator/statefulset.yaml`** - Update `HADOOP_S3A_ENDPOINT`
3. **`templates/trino/worker/deployment.yaml`** - Update `HADOOP_S3A_ENDPOINT`
4. **`templates/_helpers-koku.tpl`** - Verify `cost-mgmt.koku.s3.endpoint`
5. **`values-koku.yaml`** - Add `infrastructure.storage.endpoint` config

---

## Summary

**Q: Does Trino need MinIO?**
**A**: No. Trino needs **S3-compatible storage**. ODF NooBaa provides this.

**Q: Can Trino access ODF buckets directly?**
**A**: Yes. NooBaa provides an S3-compatible API. Just point Trino to `s3.openshift-storage.svc:80`.

**Q: How is Trino working right now?**
**A**: It's only "working" because no S3 operations have been attempted yet. Once integration testing starts (Koku writes Parquet files), it will fail because `minio:9000` doesn't exist.

**Q: Is ODF using block devices?**
**A**: Yes. ODF uses **Ceph RBD (block devices)** for storage, and **NooBaa exposes an S3 API** on top of it. Applications interact via S3 API, ODF handles the block device management internally.

---

**Action Required**: Update S3 endpoint from `minio:9000` to `s3.openshift-storage.svc:80` before integration testing.

**Priority**: **P0 - Critical** - Will block integration testing ❌

