# Force Operator Upload for End-to-End Validation

This guide explains how to manually trigger the Cost Management Metrics Operator to package and upload ROS metrics immediately, bypassing the default 6-hour cycle. This is useful for:

- **Development & Testing**: Validate the end-to-end data pipeline without waiting hours
- **Debugging**: Quickly test changes to ingress, processor, or Kruize
- **Demonstrations**: Show the complete data flow on demand

## Table of Contents

- [Overview](#overview)
- [Important Limitation](#important-limitation)
- [Prerequisites](#prerequisites)
- [Method 1: Using the Script (Recommended)](#method-1-using-the-script-recommended)
- [Method 2: Manual Commands](#method-2-manual-commands)
- [Verification Steps](#verification-steps)
- [Troubleshooting](#troubleshooting)

## Overview

By default, the Cost Management Metrics Operator operates on these cycles:

| Operation | Default Interval | Can Be Forced? |
|-----------|-----------------|----------------|
| **Metrics Collection** | Every hour (at :00) | ⚠️ Limited (requires timestamp manipulation) |
| **Packaging** | Every 6 hours (360 min) | ✅ Yes |
| **Upload** | Immediately after packaging | ✅ Yes |

**Scenario 2** (documented here) forces **packaging + upload** of already-collected metrics, bypassing the 6-hour wait.

## Important Limitation

**Kruize's Time Interval Behavior:**

Kruize uses a default `measurement_duration` of **15 minutes**. Each experiment result is uniquely identified by the combination of `(experiment_name, interval_end_time)` in the database. If you upload the same experiment with the same `interval_end_time` multiple times, Kruize will **reject duplicate entries** with the error:

```
Detail: Key (experiment_name, interval_end_time, interval_start_time)=(...)  already exists.
```

**Technical Note:** While the error message shows all three fields for context, the actual database unique constraint is only on `(experiment_name, interval_end_time)`. The `interval_start_time` is included in the error message to help identify the time range but is not part of the primary key.

**What this means for testing:**
- ✅ The **end-to-end pipeline** (Operator → Ingress → Processor → Kruize) still works and can be validated
- ⚠️ Kruize will **reject duplicate data** for the same `interval_end_time`, but the flow itself succeeds
- ✅ Perfect for **testing the pipeline**, just don't expect new recommendations from duplicate uploads
- 📊 The duplicate rejection proves that Kruize received and attempted to process the data

**Workaround for getting fresh recommendations:**
Wait for the next hourly metrics collection (top of the hour), which generates new `interval_end_time` values that won't conflict with existing data.

## Prerequisites

Before forcing an upload, ensure:

1. **Metrics have been collected recently** (within the last hour)
2. **ServiceMonitors are deployed** (see [installation.md](installation.md))
3. **User-workload monitoring is enabled**:
   ```bash
   # Verify user workload monitoring is enabled
   oc get pods -n openshift-user-workload-monitoring
   # Should show prometheus-user-workload-* pods

   # If not enabled, run:
   oc apply -f - <<EOF
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: cluster-monitoring-config
     namespace: openshift-monitoring
   data:
     config.yaml: |
       enableUserWorkload: true
   EOF
   ```
   See [installation.md](installation.md#6-user-workload-monitoring-required-for-ros-metrics) for more details.
4. **The operator is running**:
   ```bash
   kubectl get pods -n costmanagement-metrics-operator -l app.kubernetes.io/name=costmanagement-metrics-operator
   ```

Check when metrics were last collected:
```bash
kubectl get costmanagementmetricsconfig -n costmanagement-metrics-operator \
  costmanagementmetricscfg-tls -o jsonpath='{.status.prometheus.last_query_success_time}'
```

Expected output: A recent timestamp like `2025-10-22T14:00:00Z`

## Method 1: Using the Script (Recommended)

We provide a convenience script that handles all the steps:

```bash
./scripts/force-operator-package-upload.sh
```

**What the script does:**
1. Checks last metrics collection time
2. Resets the packaging timestamp to bypass the 6-hour timer
3. Triggers operator reconciliation with the `force-collection` annotation
4. Waits 60 seconds for processing
5. Reports upload status

**Example output:**
```
🚀 Force Packaging & Upload to Ingress
========================================

📊 Checking last metrics collection time...
   Last collection: 2025-10-22T14:00:00Z

⏰ Step 1: Resetting packaging timestamp...
   ✅ Timestamp reset to 2020-01-01 (forces repackaging)

🔄 Step 2: Triggering operator reconciliation...
   ✅ Reconciliation triggered

⏳ Waiting 60 seconds for operator to package and upload...

📋 Checking upload status...
   Last upload status: 202 Accepted
   Last successful upload: 2025-10-22T14:01:15Z

✅ SUCCESS! Operator successfully packaged and uploaded metrics.
```

## Method 2: Manual Commands

If you prefer manual control or need to understand the internals:

### Step 1: Reset Packaging Timestamp

This tricks the operator into thinking 6+ hours have passed since the last packaging:

```bash
kubectl patch costmanagementmetricsconfig \
  -n costmanagement-metrics-operator costmanagementmetricscfg-tls \
  --type='json' \
  -p='[{"op": "replace", "path": "/status/packaging/last_successful_packaging_time", "value": "2020-01-01T00:00:00Z"}]' \
  --subresource=status
```

**What this does:**
- Modifies the `last_successful_packaging_time` in the CR status
- The operator checks if `(current_time - last_packaging_time) >= 360 minutes`
- Setting it to `2020-01-01` ensures the condition is always true

### Step 2: Trigger Reconciliation

Force the operator to reconcile immediately:

```bash
kubectl annotate -n costmanagement-metrics-operator \
  costmanagementmetricsconfig costmanagementmetricscfg-tls \
  clusterconfig.openshift.io/force-collection="$(date +%s)" --overwrite
```

**What this does:**
- Updates the `force-collection` annotation with the current Unix timestamp
- Kubernetes triggers a reconciliation event
- The operator re-evaluates all cycle timers and finds packaging is "overdue"

### Step 3: Monitor Progress

Watch the operator logs in real-time:

```bash
OPERATOR_POD=$(kubectl get pods -n costmanagement-metrics-operator \
  -l app.kubernetes.io/name=costmanagement-metrics-operator \
  -o jsonpath='{.items[0].metadata.name}')

kubectl logs -n costmanagement-metrics-operator $OPERATOR_POD -f | grep -E "(packaging|upload|ros-)"
```

**Expected log output:**
```
INFO  executing file packaging
INFO  adding file to tar.gz  {"file": "...ros-openshift-container-202510.csv"}
INFO  adding file to tar.gz  {"file": "...ros-openshift-namespace-202510.csv"}
INFO  file packaging was successful
INFO  executing upload
INFO  uploading file: 20251022T140230_123456-cost-mgmt.tar.gz
INFO  request response  {"status": 202, "URL": "http://cost-onprem-ingress..."}
```

## Verification Steps

After forcing the upload, verify each stage of the pipeline:

### 1. Verify Operator Packaged Files

Check that new packages were created:

```bash
kubectl get costmanagementmetricsconfig -n costmanagement-metrics-operator \
  costmanagementmetricscfg-tls -o jsonpath='{.status.packaging.packaged_files[-3:]}' | jq
```

Look for recent timestamps in the filenames (e.g., `20251022T140230`).

### 2. Verify Upload Success

```bash
kubectl get costmanagementmetricsconfig -n costmanagement-metrics-operator \
  costmanagementmetricscfg-tls -o jsonpath='{.status.upload}' | jq
```

**Expected output:**
```json
{
  "last_upload_status": "202 Accepted",
  "last_successful_upload_time": "2025-10-22T14:02:30Z",
  "last_payload_files": [
    "...-ros-openshift-container-202510.5.csv",
    "...-ros-openshift-namespace-202510.6.csv"
  ]
}
```

Key indicators:
- ✅ `last_upload_status`: `"202 Accepted"` (not `500 Internal Server Error`)
- ✅ `last_payload_files`: Contains `ros-openshift-container` and `ros-openshift-namespace`

### 3. Verify Ingress Received Upload

Check ingress logs for successful processing:

```bash
kubectl logs -n cost-onprem -l app.kubernetes.io/component=ingress -c ingress \
  --tail=50 --since=5m | grep -E "(ROS|upload)"
```

**Expected output:**
```json
{"msg":"Successfully identified ROS files","ros_files_found":2}
{"msg":"Successfully uploaded ROS file","file_name":"...ros-openshift-container-202510.5.csv"}
{"msg":"Successfully uploaded ROS file","file_name":"...ros-openshift-namespace-202510.6.csv"}
{"msg":"Successfully sent ROS event message","topic":"hccm.ros.events","uploaded_files":2}
{"msg":"Upload processed successfully"}
```

### 4. Verify Processor Consumed Messages

Check that the processor received Kafka messages:

```bash
kubectl logs -n cost-onprem -l app.kubernetes.io/component=processor \
  --tail=50 --since=5m | grep -E "(Message received|ros-openshift)"
```

**Expected output:**
```
Message received from kafka hccm.ros.events[0]@123: {...}
Recommendation request sent for experiment - 12345|...|cost-onprem|statefulset|cost-onprem-kafka
```

### 5. Verify Kruize Received Experiments

Check Kruize logs for experiment creation:

```bash
kubectl logs -n cost-onprem -l app.kubernetes.io/component=ros-optimization \
  --tail=100 --since=5m | grep -E "(experiment_name|CreateExperiment|UpdateResults)"
```

**Expected output:**
```
DEBUG [CreateExperiment.java]-[{"experiment_name":"12345|...|cost-onprem|statefulset|..."}]
DEBUG [UpdateResults.java]-updateResults API request payload for requestID 26 is [...]
```

**Note on duplicate data:**
If you see errors like `Key (...) already exists`, this is **expected behavior** when uploading the same time period multiple times. The pipeline itself is working correctly.

## Troubleshooting

### Issue: Upload Status Shows "500 Internal Server Error"

**Symptoms:**
```bash
$ kubectl get costmanagementmetricsconfig ... -o jsonpath='{.status.upload.error}'
status: 500 | error response: {"error":"Failed to process upload"}
```

**Common causes:**

1. **No ROS files in manifest** (ingress rejects it):
   ```bash
   # Check ingress logs
   kubectl logs -n cost-onprem -l app.kubernetes.io/component=ingress -c ingress --tail=20
   ```

   If you see: `"no ROS files specified in manifest"`, it means:
   - ServiceMonitors are not deployed
   - Prometheus is not scraping ROS pods
   - Operator collected only Cost Management metrics, not ROS metrics

   **Fix**: Follow [installation.md](installation.md) to deploy ServiceMonitors and enable user-workload monitoring.

2. **Old packages without ROS files**:
   The operator tries to upload packages from before ServiceMonitors were deployed.

   **Fix**: Delete old packages and force a new packaging:
   ```bash
   # Delete packages older than today
   OPERATOR_POD=$(kubectl get pods -n costmanagement-metrics-operator \
     -l app.kubernetes.io/name=costmanagement-metrics-operator \
     -o jsonpath='{.items[0].metadata.name}')

   kubectl exec -n costmanagement-metrics-operator $OPERATOR_POD -- \
     sh -c 'cd tmp/costmanagement-metrics-operator-reports/upload && \
            rm -f $(date +%Y%m%d -d "yesterday")*'

   # Run force script again
   ./scripts/force-operator-package-upload.sh
   ```

### Issue: Operator Not Packaging Despite Force

**Symptoms:**
- Annotation is applied but no new packages appear
- Operator logs show reconciliation but no packaging activity

**Check:**
```bash
# Verify the packaging timestamp was reset
kubectl get costmanagementmetricsconfig -n costmanagement-metrics-operator \
  costmanagementmetricscfg-tls \
  -o jsonpath='{.status.packaging.last_successful_packaging_time}'
```

If it shows a recent time (last 6 hours), the timestamp patch didn't work.

**Fix:**
```bash
# Ensure you're using --subresource=status
kubectl patch costmanagementmetricsconfig \
  -n costmanagement-metrics-operator costmanagementmetricscfg-tls \
  --type='json' \
  -p='[{"op": "replace", "path": "/status/packaging/last_successful_packaging_time", "value": "2020-01-01T00:00:00Z"}]' \
  --subresource=status
```

### Issue: No Recent Metrics Collection

**Symptoms:**
```bash
$ kubectl get costmanagementmetricsconfig ... \
    -o jsonpath='{.status.prometheus.last_query_success_time}'
2025-10-22T09:00:00Z  # More than 2 hours ago
```

**Impact:**
- Forced packaging will succeed, but packages will contain old data
- Won't see recent workload changes

**Options:**

1. **Wait for next collection** (happens on the hour, e.g., 14:00, 15:00)
2. **Force metrics collection** (advanced):
   ```bash
   kubectl patch costmanagementmetricsconfig \
     -n costmanagement-metrics-operator costmanagementmetricscfg-tls \
     --type='json' \
     -p='[{"op": "replace", "path": "/status/prometheus/last_query_success_time", "value": "2020-01-01T00:00:00Z"}]' \
     --subresource=status

   kubectl annotate -n costmanagement-metrics-operator \
     costmanagementmetricsconfig costmanagementmetricscfg-tls \
     clusterconfig.openshift.io/force-collection="$(date +%s)" --overwrite
   ```

### Issue: Kruize Shows "already exists" Errors

**This is expected!** See [Important Limitation](#important-limitation).

**What's happening:**
- You forced an upload with the same `interval_end_time` as a previous upload
- Kruize's database has a unique constraint on `(experiment_name, interval_end_time)`
- Kruize rejects the duplicate entry with a PostgreSQL constraint violation error
- The pipeline itself is working fine

**Example error from Kruize logs:**
```
Detail: Key (experiment_name, interval_end_time, interval_start_time)=(12345|...|statefulset|..., 2025-10-22 03:30:00, 2025-10-22 03:15:01) already exists.
```

**Verification:**
The fact that you see this error means:
- ✅ Ingress accepted the upload
- ✅ Processor consumed the Kafka message
- ✅ Kruize received the experiment data
- ✅ Kruize attempted to insert it into the database
- ⚠️ Database rejected it as a duplicate (this proves the pipeline works!)

**To get fresh data accepted by Kruize:**
- Wait for the next hourly metrics collection (e.g., if it's 14:30, wait until 15:00)
- New collections will have different `interval_end_time` values and won't be rejected

## Summary

**Quick Reference:**

| Scenario | Command | Wait Time | Result |
|----------|---------|-----------|--------|
| **Upload existing packages** | `kubectl annotate ... force-collection="$(date +%s)"` | 0 min | Uploads queued packages |
| **Package + upload NOW** | `./scripts/force-operator-package-upload.sh` | ~1 min | Packages recent metrics & uploads |
| **Fresh collection + package + upload** | Wait for :00 hour, then run script | Up to 60 min | New metrics collected & uploaded |

**For end-to-end validation:**
1. Ensure metrics were collected (check last query time)
2. Run `./scripts/force-operator-package-upload.sh`
3. Follow [Verification Steps](#verification-steps)
4. Expect Kruize to reject duplicates (this is normal!)

## See Also

- [Installation Guide](installation.md) - How to deploy ServiceMonitors
- [Troubleshooting Guide](troubleshooting.md) - Common issues and fixes
- [Configuration Reference](configuration.md) - Operator configuration options

