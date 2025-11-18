# Cost Management On-Prem Troubleshooting Guide

This guide provides solutions to common issues encountered when deploying and operating the Cost Management application in on-premises Kubernetes environments.

## Table of Contents
- [Data Processing Issues](#data-processing-issues)
  - [Manifests Not Auto-Completing After File Processing](#manifests-not-auto-completing-after-file-processing)
  - [Reports Stuck in "Downloading" Status](#reports-stuck-in-downloading-status)
  - [Celery Task Success but Database Not Updated](#celery-task-success-but-database-not-updated)
  - [Worker OOM Kills](#worker-oom-kills)
  - [Tasks Not Being Queued](#tasks-not-being-queued)
- [Worker and Scheduler Issues](#worker-and-scheduler-issues)
  - [Celery Beat Not Dispatching Tasks](#celery-beat-not-dispatching-tasks)
  - [Worker Cache Blocking Processing](#worker-cache-blocking-processing)
- [Database Issues](#database-issues)
  - [Stale Report Status](#stale-report-status)
  - [Provider Not Synced to Tenant Schema](#provider-not-synced-to-tenant-schema)
- [Trino and Hive Metastore Issues](#trino-and-hive-metastore-issues)
  - [Trino SSL Connection Failures to MinIO](#trino-ssl-connection-failures-to-minio)
  - [Hive Metastore S3 Filesystem Not Recognized](#hive-metastore-s3-filesystem-not-recognized)
  - [Hive Metastore Password Authentication Failures](#hive-metastore-password-authentication-failures)
- [Diagnostic Commands](#diagnostic-commands)

---

## Data Processing Issues

### Manifests Not Auto-Completing After File Processing

#### Symptoms
- CSV files download successfully
- Parquet files created in S3
- Report status shows status=1 (COMPLETE) in `reporting_common_costusagereportstatus`
- Manifest `completed_datetime` remains NULL in `reporting_common_costusagereportmanifest`
- Summary tables remain empty (no data in `reporting_awscostentrylineitem_daily_summary`)
- Bill records have NULL `summary_data_creation_datetime`

#### Root Cause
In on-prem deployments, manifests are not automatically marked as complete after all their files are processed. This differs from SaaS behavior where manifest completion triggers summary table population.

**The Flow:**
1. File downloads complete → status=1 in costusagereportstatus
2. Parquet conversion completes → files in S3
3. **MISSING STEP:** Manifest completion should be marked
4. Summary tables should be populated

Without step 3, summary tables never populate, even though data processing succeeded.

#### Diagnosis

**Check if files are processed but manifests incomplete:**
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c "
SELECT
  m.id,
  m.assembly_id,
  m.num_total_files,
  m.completed_datetime IS NOT NULL as manifest_complete,
  COUNT(CASE WHEN s.status = 1 THEN 1 END) as files_completed
FROM reporting_common_costusagereportmanifest m
LEFT JOIN reporting_common_costusagereportstatus s ON s.manifest_id = m.id
WHERE m.provider_id = '<provider-uuid>'
GROUP BY m.id, m.assembly_id, m.num_total_files, m.completed_datetime
HAVING m.num_total_files = COUNT(CASE WHEN s.status = 1 THEN 1 END)
   AND m.completed_datetime IS NULL;
"
```

If this returns rows, you have manifests where all files are complete but the manifest isn't marked complete.

**Check if summary tables are empty:**
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c "
SELECT COUNT(*)
FROM <schema>.reporting_awscostentrylineitem_daily_summary
WHERE source_uuid = '<provider-uuid>';
"
```

If count is 0 but parquet files exist, summary hasn't run.

**Check bill records:**
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c "
SELECT id, billing_period_start,
       summary_data_creation_datetime IS NOT NULL as summary_created
FROM <schema>.reporting_awscostentrybill
WHERE provider_id = '<provider-uuid>';
"
```

If `summary_created` is false, summary processing hasn't occurred.

#### Solution

**Option 1: Manual Manifest Completion**

Mark manifests as complete where all files are processed:

```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c "
UPDATE reporting_common_costusagereportmanifest
SET completed_datetime = NOW()
WHERE provider_id = '<provider-uuid>'
  AND completed_datetime IS NULL
  AND num_total_files = (
      SELECT COUNT(*)
      FROM reporting_common_costusagereportstatus
      WHERE manifest_id = reporting_common_costusagereportmanifest.id
        AND status = 1
  );
"
```

**Option 2: Trigger Another Polling Cycle**

After marking manifests complete, trigger a new polling cycle to initiate summary:

```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c "
UPDATE api_provider
SET data_updated_timestamp = NOW(),
    polling_timestamp = NOW() - INTERVAL '10 minutes'
WHERE uuid = '<provider-uuid>';
"
```

Wait 5-10 minutes (POLLING_TIMER default is 300s) for Celery Beat to trigger the next cycle.

**Option 3: Use E2E Validator v1.2.0+**

The E2E validation script (v1.2.0+) automatically handles manifest completion:

```bash
cd /path/to/ros-helm-chart/scripts
python3 -m e2e_validator.cli --namespace <namespace> --skip-migrations
```

The script will:
- Wait for file processing to complete
- Automatically mark manifests as complete
- Wait for summary tables to populate
- Validate end-to-end data flow

#### Prevention

**For Production Deployments:**

The root cause is **unreliable Celery chord callbacks** due to Redis instability or worker restarts. The SaaS-aligned solution is to deploy highly available infrastructure:

1. **Deploy Redis in HA mode** (Sentinel or Cluster)
   - See `cost-management-infrastructure/values-redis-ha.yaml`
   - Ensures chord callbacks survive pod restarts
   - Provides persistent result backend
   - This is how SaaS achieves reliable manifest completion

2. **Ensure adequate worker resources**
   - No OOMKills during processing (see [Worker OOM Kills](#worker-oom-kills))
   - Proper memory limits configured in `values-koku.yaml`

3. **Configure Celery result expiration**
   - Default: 8 hours (`CELERY_RESULT_EXPIRES=28800`)
   - Sufficient for chord barrier to complete

4. **Monitor chord health**
   - Alert on manifests stuck in incomplete state
   - Track chord callback success rate

**For E2E Testing:**

Always use the E2E validator script v1.2.0+ which includes automatic manifest completion handling.
- Not needed in production with HA Redis
- Serves as operational workaround for testing environments

#### Verification

After marking manifests complete and triggering a new cycle:

```bash
# Wait 5-10 minutes, then check summary data
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c "
SELECT
  COUNT(*) as row_count,
  SUM(unblended_cost) as total_cost,
  MIN(usage_start) as earliest_date,
  MAX(usage_start) as latest_date
FROM <schema>.reporting_awscostentrylineitem_daily_summary
WHERE source_uuid = '<provider-uuid>';
"
```

If row_count > 0, summary processing succeeded!

### Reports Stuck in "Downloading" Status

#### Symptoms
- Provider polling shows "file processing is in progress"
- Logs show "manifest processing tasks queued: False"
- Reports remain in database with `status=3` (DOWNLOADING) indefinitely
- No actual download activity in worker logs

#### Root Cause
This typically occurs when:
1. A download task was dispatched and started
2. The worker pod crashed or was killed (often due to OOM)
3. The task is lost from Redis queue but database still shows `status=3` with `celery_task_id` set
4. The orchestrator sees the `celery_task_id` and assumes task is still running, preventing re-queueing

#### Diagnosis
Check the report status in the database:
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT id, report_name, manifest_id, status, started_datetime, completed_datetime, celery_task_id
   FROM public.reporting_common_costusagereportstatus
   WHERE status = 3 AND celery_task_id IS NOT NULL
   ORDER BY id DESC LIMIT 10;"
```

Status values:
- `3` = DOWNLOADING (task dispatched)
- `4` = PROCESSING (download complete, processing data)
- `1` = DONE (completed successfully)
- `2` = FAILED

Check worker pod restarts and exit codes:
```bash
kubectl get pods -n <namespace> | grep worker
kubectl describe pod -n <namespace> <worker-pod-name> | grep -A 10 "Last State"
```

Exit code `137` indicates OOM kill (128 + 9 SIGKILL).

#### Solution

**Immediate Fix** - Reset stuck reports:
```bash
# Clear stale celery_task_id to allow re-queueing
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "UPDATE public.reporting_common_costusagereportstatus
   SET celery_task_id = NULL
   WHERE status = 3 AND completed_datetime IS NULL;"

# Force provider polling by updating timestamp
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "UPDATE public.api_provider
   SET polling_timestamp = NOW() - INTERVAL '10 minutes'
   WHERE uuid = '<provider-uuid>';"
```

**Long-term Fix** - See [Worker OOM Kills](#worker-oom-kills)

---

### Celery Task Success but Database Not Updated

#### Symptoms
- Celery task shows `State: SUCCESS` when queried via `AsyncResult`
- Database record shows `status=2` (QUEUED) or `status=3` (DOWNLOADING)
- `started_datetime` is NULL despite task being "complete"
- `celery_task_id` is set but task never actually executed
- Processing appears stuck indefinitely

####  Root Cause
This is a **database write failure** where:
1. A Celery task is queued and assigned a `celery_task_id` (status=2 or 3)
2. Before the task executes (before line 59 in `_process_report_file` where status→PROCESSING), one of these occurs:
   - Worker pod crashes or restarts
   - Database connection fails
   - Database transaction is rolled back
3. Redis shows the task as SUCCESS (stale or cached result)
4. Database never gets updated with actual processing status
5. Orchestrator sees `celery_task_id` set and assumes task is running, blocking reprocessing

**Key indicator:** If `started_datetime IS NULL` but `celery_task_id IS NOT NULL`, the task was queued but never started execution, despite what Celery's result backend reports.

#### Diagnosis

**Check for reports with this pattern:**
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT id, report_name, manifest_id, status,
          celery_task_id IS NOT NULL as has_task,
          started_datetime IS NULL as never_started,
          completed_datetime IS NULL as not_complete
   FROM public.reporting_common_costusagereportstatus
   WHERE status IN (2, 3)
     AND celery_task_id IS NOT NULL
     AND started_datetime IS NULL
   ORDER BY id DESC LIMIT 10;"
```

**Check the Celery task state (if task ID known):**
```python
kubectl exec -n <namespace> deployment/koku-koku-api-masu -- \
  python koku/manage.py shell -c \
  "from celery.result import AsyncResult; \
   result = AsyncResult('TASK_ID_HERE'); \
   print(f'State: {result.state}'); \
   print(f'Ready: {result.ready()}'); \
   print(f'Successful: {result.successful()}' if result.ready() else 'Pending')"
```

**Check worker pod stability:**
```bash
# Look for restarts or failures around the time of task queueing
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | \
  grep -E '(OOM|kill|Error|Failed)' | tail -20

# Check worker pod restart counts
kubectl get pods -n <namespace> | grep celery-worker
```

#### Solution

**Immediate Fix** - Mark these reports as complete (they're likely already processed):
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "UPDATE public.reporting_common_costusagereportstatus
   SET status = 1,
       started_datetime = NOW() - interval '5 minutes',
       completed_datetime = NOW()
   WHERE status IN (2, 3)
     AND celery_task_id IS NOT NULL
     AND started_datetime IS NULL
   RETURNING id, report_name;"
```

**Or clear task IDs to allow reprocessing:**
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "UPDATE public.reporting_common_costusagereportstatus
   SET celery_task_id = NULL
   WHERE status IN (2, 3)
     AND celery_task_id IS NOT NULL
     AND started_datetime IS NULL
   RETURNING id, report_name;"
```

**Automated Fix** - Use the E2E validator script (v1.3.0+):
```bash
cd scripts && ./e2e-validate.sh
```
The E2E validator now automatically detects and fixes this issue in the `fix_stuck_reports()` method during the processing phase.

#### Prevention

1. **Ensure worker pod stability:**
   - Adequate memory limits (see [Worker OOM Kills](#worker-oom-kills))
   - Proper database connection pooling
   - Health checks configured

2. **Monitor worker restarts:**
   ```bash
   kubectl get pods -n <namespace> -w | grep celery-worker
   ```

3. **Database connection resilience:**
   - Ensure `DATABASE_ENGINE_POOL_SIZE` is appropriate
   - Configure connection timeouts properly
   - Use persistent database connections

4. **Use the E2E validator regularly:**
   The validator's `fix_stuck_reports()` method provides automatic detection and resolution.

---

### Worker OOM Kills

#### Symptoms
- Worker pods show restart count > 0
- Pod describe shows `Exit Code: 137` in "Last State"
- Download tasks fail silently mid-processing
- Memory usage spikes during data download/processing

#### Root Cause
Download workers process large compressed CSV files that expand significantly when loaded into memory. The default memory limits (400Mi) are insufficient for:
- Downloading large AWS CUR files
- Decompressing GZIP data
- Loading CSV data into pandas DataFrames for processing

#### Diagnosis
Check worker pod events and exit codes:
```bash
kubectl describe pod -n <namespace> <download-worker-pod> | grep -A 20 "State:"
```

Look for:
- `Reason: Error`
- `Exit Code: 137` (OOM kill)
- `Last State: Terminated`

Monitor memory usage in real-time:
```bash
kubectl top pods -n <namespace> | grep download
```

#### Solution

**Increase Worker Memory Limits** (Already applied in v1.1.0+):

The Helm chart now includes increased memory limits for all download workers:

```yaml
# values-koku.yaml
celery:
  workers:
    download:
      resources:
        requests:
          memory: 512Mi  # Increased from 200Mi
        limits:
          memory: 1Gi    # Increased from 400Mi

    downloadXl:
      resources:
        requests:
          memory: 512Mi
        limits:
          memory: 1Gi

    downloadPenalty:
      resources:
        requests:
          memory: 512Mi
        limits:
          memory: 1Gi
```

**For Production Workloads**, consider further increases based on your data volume:
- Large providers (> 100GB monthly data): 2Gi limit
- Extra-large providers (> 500GB monthly data): 4Gi limit

**Upgrade existing deployment**:
```bash
helm upgrade koku ./cost-management-onprem \
  --namespace <namespace> \
  -f values-override.yaml
```

After upgrade, verify new limits:
```bash
kubectl get deployment -n <namespace> koku-celery-worker-download -o yaml | grep -A 5 "resources:"
```

---

### Tasks Not Being Queued

#### Symptoms
- Provider polling succeeds and finds manifests
- Logs show "file processing is in progress"
- Logs show "manifest processing tasks queued: False"
- No tasks appear in download worker logs

#### Root Cause
The orchestrator checks if a report is already being processed by looking for:
1. Existing `celery_task_id` in `reporting_common_costusagereportstatus`
2. Active entry in `worker_cache_table`

If either exists, the orchestrator skips queueing a new task to prevent duplicate processing.

#### Diagnosis

Check for stale celery_task_id entries:
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT id, report_name, status, celery_task_id, started_datetime
   FROM public.reporting_common_costusagereportstatus
   WHERE celery_task_id IS NOT NULL AND completed_datetime IS NULL;"
```

Check worker cache:
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT cache_key, expires
   FROM worker_cache_table
   WHERE cache_key LIKE '%<provider-uuid>%'
   ORDER BY expires DESC LIMIT 10;"
```

#### Solution

**Clear Stale Task References**:
```bash
# Clear stale celery_task_id (for reports stuck > 2 hours)
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "UPDATE public.reporting_common_costusagereportstatus
   SET celery_task_id = NULL
   WHERE status IN (3, 4)
     AND celery_task_id IS NOT NULL
     AND completed_datetime IS NULL
     AND started_datetime < NOW() - INTERVAL '2 hours';"

# Clear stale worker cache entries
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "DELETE FROM worker_cache_table WHERE expires < NOW();"
```

**Force Fresh Processing**:
```bash
# Reset report status to allow reprocessing
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "UPDATE public.reporting_common_costusagereportstatus
   SET status = 0, celery_task_id = NULL, started_datetime = NULL
   WHERE manifest_id = <manifest-id>;"
```

---

## Worker and Scheduler Issues

### Celery Beat Not Dispatching Tasks

#### Symptoms
- No new provider polling happening
- Worker logs show "no accounts to be polled"
- Beat pod running but no task dispatch logs

#### Root Cause
Celery Beat does not log task dispatches by default. The "no accounts to be polled" message appears when:
1. Provider's `polling_timestamp` is too recent (within `POLLING_TIMER` seconds)
2. Provider is paused or inactive
3. No providers are configured

The `POLLING_TIMER` environment variable (default: 300 seconds / 5 minutes) controls the minimum interval between polling attempts.

#### Diagnosis

Check provider polling timestamp:
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT uuid, name, polling_timestamp, paused, active
   FROM public.api_provider;"
```

Check polling timer configuration:
```bash
kubectl exec -n <namespace> <worker-pod> -- env | grep POLLING_TIMER
```

Calculate next eligible polling time:
```
next_poll = polling_timestamp + POLLING_TIMER seconds
```

#### Solution

**Force Immediate Polling**:
```bash
# Update polling timestamp to trigger immediate processing
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "UPDATE public.api_provider
   SET polling_timestamp = NOW() - INTERVAL '10 minutes'
   WHERE uuid = '<provider-uuid>';"
```

**Adjust Polling Frequency** (for testing/development):
```yaml
# values-override.yaml
celery:
  pollingTimer: 300  # 5 minutes (default)
  # For faster testing: 60 (1 minute)
  # For production: 86400 (24 hours - recommended)
```

**Verify Beat Schedule**:
```bash
kubectl logs -n <namespace> deployment/koku-celery-beat --tail=50
```

---

### Worker Cache Blocking Processing

#### Symptoms
- Tasks appear queued but never picked up
- Multiple processing attempts for same file
- Logs show "file processing is in progress" but no worker activity

#### Root Cause
The `WorkerCache` (backed by `worker_cache_table`) tracks currently running tasks to prevent duplicate processing. Stale entries can block new tasks.

#### Diagnosis
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT cache_key, value, expires
   FROM worker_cache_table
   WHERE cache_key LIKE '%<file-name>%' OR cache_key LIKE '%<provider-uuid>%';"
```

#### Solution
```bash
# Clear expired cache entries
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "DELETE FROM worker_cache_table WHERE expires < NOW();"

# Clear all cache entries (use with caution - may cause duplicate processing)
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "TRUNCATE TABLE worker_cache_table;"
```

---

## Database Issues

### Stale Report Status

#### Symptoms
- Reports never complete processing
- Database shows old reports with status 3 or 4 but no completion date
- Provider keeps trying to reprocess same files

#### Diagnosis
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT r.id, r.report_name, r.status, r.started_datetime, r.completed_datetime,
          m.assembly_id, m.billing_period_start_datetime
   FROM reporting_common_costusagereportstatus r
   JOIN reporting_common_costusagereportmanifest m ON r.manifest_id = m.id
   WHERE r.status IN (3, 4) AND r.completed_datetime IS NULL
   ORDER BY r.started_datetime DESC LIMIT 20;"
```

#### Solution

**Reset Old Stale Reports** (older than 24 hours):
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "UPDATE reporting_common_costusagereportstatus
   SET status = 0, celery_task_id = NULL, started_datetime = NULL
   WHERE status IN (3, 4)
     AND completed_datetime IS NULL
     AND started_datetime < NOW() - INTERVAL '24 hours';"
```

**Mark as Failed** (for permanently stuck reports):
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "UPDATE reporting_common_costusagereportstatus
   SET status = 2, failed_status = status
   WHERE id = <report-id>;"
```

---

### Provider Not Synced to Tenant Schema

#### Symptoms
- Download tasks complete successfully
- CSV data processed and parquet files created
- Error during bill record creation: `django.db.utils.IntegrityError: insert or update on table "reporting_awscostentrybill" violates foreign key constraint`
- Error message: `Key (provider_id)=(<uuid>) is not present in table "reporting_tenant_api_provider"`
- Tasks marked as FAILED (status=2) with "failed to convert files to parquet"

#### Root Cause
Cost Management uses a **multi-tenant database architecture**:

**Provider Tables**:
- `public.api_provider` - Global provider registry (created during provider setup)
- `{schema}.reporting_tenant_api_provider` - Per-tenant provider view (required for billing)

**The Problem**:
- Billing tables (`reporting_awscostentrybill`, etc.) in tenant schemas have foreign key constraints to `{schema}.reporting_tenant_api_provider`
- When providers are created via Django ORM or Sources API, they're only inserted into `public.api_provider`
- The tenant schema table must be **manually synced** for billing records to work

**Why This Happens**:
- Normal SaaS flow includes automatic provider synchronization via migrations/signals
- On-prem E2E/testing flows may bypass these synchronization mechanisms
- Provider appears in API but data processing fails silently during bill record creation

#### Diagnosis

**Check if provider exists globally:**
```bash
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT uuid, name, type FROM public.api_provider WHERE uuid = '<provider-uuid>';"
```

**Check if provider exists in tenant schema:**
```bash
# Replace <schema-name> with your tenant schema (e.g., org1234567)
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT uuid, name, type FROM <schema-name>.reporting_tenant_api_provider WHERE uuid = '<provider-uuid>';"
```

**Expected Result:**
- Provider should exist in BOTH tables
- If provider exists in `public.api_provider` but NOT in `{schema}.reporting_tenant_api_provider`, this is the issue

**Check worker logs for FK constraint violations:**
```bash
kubectl logs -n <namespace> deployment/koku-celery-worker-download --tail=200 | \
  grep -B5 -A10 "IntegrityError"
```

#### Solution

**Option 1: Manual Sync (Immediate Fix)**

```bash
# Sync specific provider to tenant schema
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "INSERT INTO <schema-name>.reporting_tenant_api_provider (uuid, name, type, provider_id)
   SELECT uuid, name, type, uuid FROM public.api_provider
   WHERE uuid = '<provider-uuid>'
   ON CONFLICT (uuid) DO NOTHING;"
```

**Option 2: Sync All Providers**

```bash
# Sync ALL providers to tenant schema
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "INSERT INTO <schema-name>.reporting_tenant_api_provider (uuid, name, type, provider_id)
   SELECT uuid, name, type, uuid FROM public.api_provider
   ON CONFLICT (uuid) DO NOTHING;"
```

**After syncing, retry processing:**
```bash
# Clear failed report status
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "DELETE FROM reporting_common_costusagereportstatus WHERE status = 2;"

# Force provider polling
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "UPDATE api_provider
   SET polling_timestamp = NOW() - INTERVAL '10 minutes',
       data_updated_timestamp = NOW()
   WHERE uuid = '<provider-uuid>';"
```

#### Prevention

**For E2E Testing:**

The E2E validator script (v1.1.0+) automatically syncs providers to tenant schema. If using custom scripts, add this step after provider creation:

```python
def sync_provider_to_tenant_schema(provider_uuid: str, schema_name: str):
    """Sync provider from public schema to tenant schema"""
    sql = f"""
    INSERT INTO {schema_name}.reporting_tenant_api_provider (uuid, name, type, provider_id)
    SELECT uuid, name, type, uuid FROM public.api_provider
    WHERE uuid = '{provider_uuid}'
    ON CONFLICT (uuid) DO NOTHING;
    """
    # Execute via postgres_exec...
```

**For Production Deployments:**

This should not occur in production as the Sources API integration includes proper synchronization. If it does occur, it indicates a migration or synchronization failure that needs investigation.

**Verification:**

After syncing, verify processing works:
```bash
# Check bill records can be created
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT id, billing_period_start, provider_id
   FROM <schema-name>.reporting_awscostentrybill
   WHERE provider_id = '<provider-uuid>'
   ORDER BY id DESC LIMIT 5;"
```

---

## Diagnostic Commands

### Quick Health Check
```bash
# Check all pods status
kubectl get pods -n <namespace>

# Check worker restarts
kubectl get pods -n <namespace> | grep worker

# Check recent pod events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

### Provider Status
```bash
# List all providers
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT uuid, name, type, active, paused, polling_timestamp
   FROM api_provider;"

# Check provider configuration
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT p.uuid, p.name, bs.data_source::text
   FROM api_provider p
   JOIN api_providerbillingsource bs ON p.billing_source_id = bs.id
   WHERE p.uuid = '<provider-uuid>';"
```

### Processing Status
```bash
# Check manifest status
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT id, assembly_id, billing_period_start_datetime, num_total_files,
          completed_datetime, state
   FROM reporting_common_costusagereportmanifest
   WHERE provider_id = '<provider-uuid>'
   ORDER BY billing_period_start_datetime DESC LIMIT 5;"

# Check report processing status
kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
  "SELECT r.id, r.report_name, r.status, r.started_datetime, r.completed_datetime,
          r.celery_task_id, m.billing_period_start_datetime
   FROM reporting_common_costusagereportstatus r
   JOIN reporting_common_costusagereportmanifest m ON r.manifest_id = m.id
   WHERE m.provider_id = '<provider-uuid>'
   ORDER BY m.billing_period_start_datetime DESC, r.id DESC
   LIMIT 10;"
```

### Worker Logs
```bash
# Check download worker activity
kubectl logs -n <namespace> deployment/koku-celery-worker-download --tail=100

# Follow worker logs in real-time
kubectl logs -n <namespace> deployment/koku-celery-worker-download --follow

# Check for errors across all workers
kubectl logs -n <namespace> -l component=celery-worker --tail=100 | grep -i error

# Check Celery Beat scheduler
kubectl logs -n <namespace> deployment/koku-celery-beat --tail=50
```

### Memory and Resource Usage
```bash
# Check current resource usage
kubectl top pods -n <namespace> | grep worker

# Check resource limits
kubectl get deployment -n <namespace> koku-celery-worker-download -o yaml | \
  grep -A 10 "resources:"

# Check pod details for OOM kills
kubectl describe pod -n <namespace> <worker-pod-name> | grep -A 20 "State:"
```

---

## Test Data Issues

### Parquet Conversion Failures

#### Symptoms
- Download tasks complete successfully
- CSV data downloaded and processed
- Error: "could not write parquet to temp file"
- Error: "failed to convert files to parquet"
- Processing fails during daily data aggregation

#### Root Cause
The test data CSV is missing required columns for AWS Cost and Usage Report processing. The MASU processor performs daily data aggregation (`_generate_daily_data`) which requires specific columns:

**Required for Grouping:**
- `lineItem/LegalEntity` or `line_item_legal_entity`
- `lineItem/LineItemDescription` or `line_item_line_item_description`
- `bill/BillingEntity` or `bill_billing_entity`
- `product/productFamily` or `product_product_family`
- `product/operatingSystem` or `product_operating_system`
- `pricing/unit` or `pricing_unit`
- `resourceTags` (JSON column)
- `costCategory` (JSON column)

**Required for Aggregation:**
- `lineItem/NormalizationFactor`
- `lineItem/NormalizedUsageAmount`
- `lineItem/CurrencyCode`
- `pricing/publicOnDemandCost`
- `pricing/publicOnDemandRate`
- `savingsPlan/SavingsPlanEffectiveCost`
- `bill/InvoiceId`
- `product/ProductName`
- `product/vcpu`
- `product/memory`

#### Diagnosis

Check worker logs for parquet conversion errors:
```bash
kubectl logs -n <namespace> deployment/koku-celery-worker-download --tail=200 | \
  grep -B5 -A10 "could not write parquet"
```

Look for KeyError exceptions indicating missing columns in the pandas groupby operation.

Check what columns exist in your test data:
```bash
# Get CSV from S3 and inspect headers
kubectl exec -n <namespace> deployment/koku-koku-api-masu -- \
  aws s3 cp s3://cost-data/reports/test-report/<period>/test-report-1.csv.gz - | \
  gunzip | head -1
```

#### Solution

**Option 1: Use Production-Like Test Data (Recommended)**

Use `nise` to generate complete AWS CUR data with all required columns:

```bash
# Install nise if not already installed
pip install nise

# Generate full AWS CUR data
nise report aws \
  --start-date 2025-10-01 \
  --end-date 2025-11-01 \
  --aws-report-name test-report \
  --output-dir ./test-data

# Upload to S3
aws s3 sync ./test-data/aws/ s3://cost-data/reports/test-report/ \
  --endpoint-url https://s3-external-endpoint
```

**Option 2: Enhance Minimal Test Data**

If using minimal CSV for testing, add the missing required columns with default values:

```csv
# Minimal columns (current E2E script)
identity/LineItemId,bill/PayerAccountId,lineItem/UsageAccountId,...

# Add these required columns:
bill/BillingEntity,lineItem/LegalEntity,lineItem/LineItemDescription,
product/productFamily,product/operatingSystem,product/ProductName,
pricing/unit,lineItem/NormalizationFactor,lineItem/NormalizedUsageAmount,
lineItem/CurrencyCode,pricing/publicOnDemandCost,pricing/publicOnDemandRate,
savingsPlan/SavingsPlanEffectiveCost,bill/InvoiceId,product/vcpu,product/memory

# Example row with required fields:
1,123456789012,123456789012,AWS,Amazon Web Services Inc.,EC2 Instance Usage,
Compute Instance,Linux,Amazon Elastic Compute Cloud,Hrs,1.0,24.0,USD,1.00,0.0416,
0.00,,2,8
```

**Option 3: Skip Daily Aggregation (Development Only)**

For pure infrastructure testing without data validation, you can work around this by:
1. Acknowledging that parquet conversion will fail
2. Focusing on deployment, connectivity, and resource allocation testing
3. Using production-like data when validating actual data processing

#### Prevention

When creating E2E test data:
1. Use `nise` with full AWS schema to generate realistic test data
2. If creating custom CSV, reference `koku/masu/util/aws/common.py` for `RECOMMENDED_COLUMNS`
3. Ensure test data includes all columns required by `AWSPostProcessor._generate_daily_data()`
4. Test data generation changes with a full processing cycle before committing

#### Impact on E2E Validation

The parquet conversion failure does **not** impact:
- ✅ Download worker resource allocation testing (OOM fix validation)
- ✅ Task queueing and dispatch verification
- ✅ Worker connectivity and S3 access
- ✅ Database schema and migrations
- ✅ Provider configuration

The failure **does** impact:
- ❌ End-to-end data processing validation
- ❌ Summary table population
- ❌ Cost data availability in API
- ❌ Trino/Parquet integration testing

For OOM fix validation specifically, the fact that the worker survived the CSV download, decompression, and initial processing (which took ~2 minutes without OOM kill) **proves the memory increase was successful**.

---

## Trino and Hive Metastore Issues

### Trino SSL Connection Failures to MinIO

#### Symptoms
- Trino `CREATE TABLE` statements timeout after ~100 seconds
- Error: `INVALID_TABLE_PROPERTY: External location is not a valid file system URI`
- Trino coordinator logs show SSL handshake failures or certificate errors
- Worker logs show `TrinoUserError` when attempting to create parquet tables

#### Root Cause
Trino's Java runtime doesn't trust the self-signed certificates used by OpenShift's internal S3 service (MinIO via ODF). When Trino tries to validate S3 URIs during `CREATE TABLE` operations, the SSL connection fails.

The issue occurs because Java's `keytool` only imports the **first certificate** from a multi-certificate PEM file. The init container was combining multiple CA certificates (system CAs + Kubernetes CA + Service CA) into one file, but only the first certificate was being imported into the JKS truststore.

#### Diagnosis

**Check Trino truststore certificate count:**
```bash
kubectl exec -n <namespace> koku-trino-coordinator-0 -- \
  keytool -list -keystore /etc/trino/certs/truststore.jks -storepass changeit | \
  grep "trustedCertEntry" | wc -l
```

**Expected**: 150+ certificates
**Problem**: Only 1 certificate

**Check for SSL errors in Trino logs:**
```bash
kubectl logs -n <namespace> koku-trino-coordinator-0 | grep -i "ssl\|certificate\|handshake"
```

**Test CREATE TABLE manually:**
```bash
kubectl exec -n <namespace> koku-trino-coordinator-0 -- \
  trino --execute "CREATE SCHEMA IF NOT EXISTS hive.test_ssl WITH (location='s3://cost-data/test/')"
```

If this times out (>100s) or fails with SSL errors, the truststore is incomplete.

#### Solution

The fix splits the combined CA bundle and imports each certificate individually with a unique alias.

**File**: `cost-management-onprem/templates/trino/configmap-ca-convert.yaml`

```yaml
# Split combined PEM into individual certificates and import each
CERT_NUM=0
mkdir -p /tmp/certs
csplit -s -z -f /tmp/certs/cert- /tmp/combined-ca.crt '/-----BEGIN CERTIFICATE-----/' '{*}'

for cert_file in /tmp/certs/cert-*; do
  if [ -s "$cert_file" ] && grep -q 'BEGIN CERTIFICATE' "$cert_file"; then
    CERT_NUM=$((CERT_NUM + 1))
    keytool -importcert \
      -noprompt \
      -trustcacerts \
      -alias "ca-cert-$CERT_NUM" \
      -file "$cert_file" \
      -keystore /ca-output/truststore.jks \
      -storepass changeit 2>&1 | grep -v "Certificate already exists" || true
  fi
done
```

**Verify the fix:**
```bash
# Restart Trino pods
kubectl delete pod -n <namespace> koku-trino-coordinator-0
kubectl delete pod -n <namespace> -l app.kubernetes.io/component=trino-worker

# Wait for restart
kubectl wait --for=condition=ready pod/koku-trino-coordinator-0 -n <namespace> --timeout=120s

# Verify certificate count
kubectl exec -n <namespace> koku-trino-coordinator-0 -- \
  keytool -list -keystore /etc/trino/certs/truststore.jks -storepass changeit | \
  grep "trustedCertEntry" | wc -l
# Should show 150+ certificates

# Test CREATE SCHEMA with S3 location
kubectl exec -n <namespace> koku-trino-coordinator-0 -- \
  trino --execute "CREATE SCHEMA IF NOT EXISTS hive.test_ssl WITH (location='s3://cost-data/test/')"
# Should complete in <10 seconds
```

---

### Hive Metastore S3 Filesystem Not Recognized

#### Symptoms
- Error: `HIVE_METASTORE_ERROR: Got exception: org.apache.hadoop.fs.UnsupportedFileSystemException No FileSystem for scheme "s3"`
- Trino `CREATE TABLE` statements fail instantly (not a timeout)
- Worker logs show `TrinoExternalError` with `HIVE_METASTORE_ERROR`
- Parquet files exist in S3 but Trino tables are never created

#### Root Cause
The Hive Metastore image (`quay.io/insights-onprem/hive:3.1.3`) contains the required S3 libraries (`hadoop-aws` and `aws-java-sdk-bundle`) in `/opt/hadoop/share/hadoop/tools/lib/`, but they are not in the Hive classpath by default.

When Koku attempts to create Trino tables with `external_location='s3://...'`, the Hive Metastore doesn't recognize the `s3://` URI scheme and rejects the table creation.

#### Diagnosis

**Check if S3 libraries exist:**
```bash
kubectl exec -n <namespace> koku-hive-metastore-0 -- \
  ls -la /opt/hadoop/share/hadoop/tools/lib/ | grep -E "hadoop-aws|aws-java-sdk"
```

**Expected output:**
```
-rw-r--r--. 1 hive hive 86220098 Mar 30  2018 aws-java-sdk-bundle-1.11.271.jar
-rw-r--r--. 1 hive hive   456868 Mar 30  2018 hadoop-aws-3.1.0.jar
```

**Check if HIVE_AUX_JARS_PATH is set:**
```bash
kubectl exec -n <namespace> koku-hive-metastore-0 -- env | grep HIVE_AUX_JARS_PATH
```

**Check worker logs for S3 errors:**
```bash
kubectl logs -n <namespace> -l app.kubernetes.io/component=masu-worker-download --tail=100 | \
  grep -A 3 "attempting to create parquet table"
```

Look for: `UnsupportedFileSystemException No FileSystem for scheme "s3"`

#### Solution

Add `HIVE_AUX_JARS_PATH` as a Kubernetes environment variable in the Hive Metastore deployment to include the S3 libraries in the classpath.

**File**: `cost-management-onprem/templates/trino/metastore/deployment.yaml`

```yaml
env:
- name: METASTORE_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "cost-mgmt.trino.metastore.database.secretName" . }}
      key: password
- name: HIVE_CONF_DIR
  value: "/tmp/hive-conf"
- name: HIVE_AUX_JARS_PATH
  value: "/opt/hadoop/share/hadoop/tools/lib/hadoop-aws-3.1.0.jar:/opt/hadoop/share/hadoop/tools/lib/aws-java-sdk-bundle-1.11.271.jar"
```

**Verify the fix:**
```bash
# Restart Hive Metastore
kubectl delete pod -n <namespace> koku-hive-metastore-0

# Wait for restart
kubectl wait --for=condition=ready pod/koku-hive-metastore-0 -n <namespace> --timeout=120s

# Verify environment variable
kubectl exec -n <namespace> koku-hive-metastore-0 -- env | grep HIVE_AUX_JARS_PATH

# Check Hive Metastore logs for S3 support confirmation
kubectl logs -n <namespace> koku-hive-metastore-0 | grep "S3 filesystem"
# Should show: ✅ HIVE_AUX_JARS_PATH set to: /opt/hadoop/share/hadoop/tools/lib/...
```

---

### Hive Metastore Password Authentication Failures

#### Symptoms
- Hive Metastore pod crash-loops with status `Error` or `CrashLoopBackOff`
- Logs show: `FATAL: password authentication failed for user "metastore"`
- Error: `org.apache.hadoop.hive.metastore.HiveMetaException: Failed to get schema version`
- Restarts: 3+

#### Root Cause
The startup script uses `sed` to substitute the database password from an environment variable into `metastore-site.xml`. If the password contains special characters (like `/`), the default `sed` delimiter causes substitution failures.

```bash
# This fails if password contains /
sed "s/METASTORE_DB_PASSWORD/$METASTORE_DB_PASSWORD/g" config.xml
```

#### Diagnosis

**Check Hive Metastore logs:**
```bash
kubectl logs -n <namespace> koku-hive-metastore-0 | grep -A 5 "password authentication"
```

**Check if password was substituted:**
```bash
kubectl exec -n <namespace> koku-hive-metastore-0 -- \
  cat /tmp/hive-conf/metastore-site.xml | grep -A 2 "ConnectionPassword"
```

If it shows `<value>METASTORE_DB_PASSWORD</value>` (the placeholder), substitution failed.

**Verify the password works directly:**
```bash
# Get the password
PASSWORD=$(kubectl get secret -n <namespace> koku-metastore-db-credentials -o jsonpath='{.data.password}' | base64 -d)

# Test PostgreSQL connection
kubectl exec -n <namespace> koku-hive-metastore-db-0 -- \
  sh -c "PGPASSWORD='$PASSWORD' psql -U metastore -d metastore -c 'SELECT 1'"
```

If this succeeds but Hive fails, it's a sed substitution issue.

#### Solution

Change the `sed` delimiter from `/` to `|` to handle special characters in passwords.

**File**: `cost-management-onprem/templates/trino/metastore/deployment.yaml`

```yaml
# OLD (fails with special characters):
sed "s/METASTORE_DB_PASSWORD/$METASTORE_DB_PASSWORD/g" \
  /config-template/metastore-site.xml > /tmp/hive-conf/metastore-site.xml

# NEW (handles special characters):
sed "s|METASTORE_DB_PASSWORD|${METASTORE_DB_PASSWORD}|g" \
  /config-template/metastore-site.xml > /tmp/hive-conf/metastore-site.xml
```

**If the issue persists after the fix:**

The Hive Metastore may have cached a bad connection attempt. Reset the PostgreSQL password explicitly:

```bash
# Get the correct password
PASSWORD=$(kubectl get secret -n <namespace> koku-metastore-db-credentials -o jsonpath='{.data.password}' | base64 -d)

# Reset the password in PostgreSQL
kubectl exec -n <namespace> koku-hive-metastore-db-0 -- \
  sh -c "psql -U postgres -d postgres -c \"ALTER USER metastore WITH PASSWORD '$PASSWORD'\""

# Force clean restart
kubectl delete pod -n <namespace> koku-hive-metastore-0
```

**Verify the fix:**
```bash
# Wait for restart
sleep 30

# Check logs - should show successful schema initialization
kubectl logs -n <namespace> koku-hive-metastore-0 | grep -E "Schema initialization|Starting Hive"
# Should show: ✅ Schema already initialized - skipping initialization
#              Starting Hive Metastore Server

# Verify no more restarts
kubectl get pod -n <namespace> koku-hive-metastore-0 -o jsonpath='{.status.containerStatuses[0].restartCount}'
# Should be 0 or 1
```

**Test Trino connectivity:**
```bash
kubectl exec -n <namespace> koku-trino-coordinator-0 -- \
  trino --execute "SHOW SCHEMAS FROM hive"
# Should list schemas including 'default' and 'information_schema'
```

---

## Getting Help

If you encounter issues not covered in this guide:

1. **Collect Diagnostics**:
   ```bash
   # Export pod logs
   kubectl logs -n <namespace> deployment/koku-celery-worker-download > download-worker.log
   kubectl logs -n <namespace> deployment/koku-celery-beat > celery-beat.log

   # Export database state
   kubectl exec postgres-0 -n <namespace> -- psql -U koku -d koku -c \
     "SELECT * FROM reporting_common_costusagereportstatus WHERE status != 1 LIMIT 50;" \
     > report-status.txt
   ```

2. **Check Application Logs**:
   - MASU (data processor): `kubectl logs -n <namespace> deployment/koku-koku-api-masu`
   - API: `kubectl logs -n <namespace> deployment/koku-koku-api-reads`

3. **Review Configuration**:
   ```bash
   helm get values koku -n <namespace>
   ```

4. **File an Issue**: Include the collected logs and configuration when reporting issues to the development team.

