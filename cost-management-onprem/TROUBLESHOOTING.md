# Cost Management On-Prem Troubleshooting Guide

This guide provides solutions to common issues encountered when deploying and operating the Cost Management application in on-premises Kubernetes environments.

## Table of Contents
- [Data Processing Issues](#data-processing-issues)
  - [Reports Stuck in "Downloading" Status](#reports-stuck-in-downloading-status)
  - [Worker OOM Kills](#worker-oom-kills)
  - [Tasks Not Being Queued](#tasks-not-being-queued)
- [Worker and Scheduler Issues](#worker-and-scheduler-issues)
  - [Celery Beat Not Dispatching Tasks](#celery-beat-not-dispatching-tasks)
  - [Worker Cache Blocking Processing](#worker-cache-blocking-processing)
- [Database Issues](#database-issues)
  - [Stale Report Status](#stale-report-status)
- [Diagnostic Commands](#diagnostic-commands)

---

## Data Processing Issues

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

