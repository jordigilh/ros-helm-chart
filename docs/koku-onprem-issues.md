# Koku On-Prem Deployment: Issues and Resolutions

**Date:** December 13, 2025
**Last Updated:** December 13, 2025 23:35 UTC

---

## Issue #1: Unleash Connection Error

### Status: ✅ RESOLVED

**Symptom:** `cost-onprem-koku-api-masu` pod in `CrashLoopBackOff` with:
```
requests.exceptions.ConnectionError: HTTPConnectionPool(host='unleash', port=4242):
Max retries exceeded with url: /api/client/features
```

**Root Cause:** Image was built from `main` branch, missing `DisabledUnleashClient`.

**Fix Applied:**
1. Rebuilt image from `koku-onprem-integration` branch (commit `8203cc71`)
2. Pushed to `quay.io/insights-onprem/koku:latest`
3. Restarted all Koku deployments

**Verification:**
- No more Unleash connection errors in logs
- `DisabledUnleashClient` is now used when `KOKU_ONPREM_DEPLOYMENT=true`

---

## Issue #2: MASU Pod OOM Killed (Exit Code 137)

### Status: ✅ RESOLVED - Helm Chart Updated

**Symptom:** `cost-onprem-koku-api-masu` pod repeatedly killed with Exit Code 137 (OOM).

```bash
$ kubectl describe pod -n cost-onprem <masu-pod>
    Last State:     Terminated
      Reason:       Error
      Exit Code:    137  # OOM Killed
```

**Root Cause:** Missing `POD_CPU_LIMIT` environment variable in Helm chart.

### Technical Analysis

**Gunicorn worker calculation** (from `koku/gunicorn_conf.py`):
```python
cpu_resources = ENVIRONMENT.int("POD_CPU_LIMIT", default=multiprocessing.cpu_count())
workers = ENVIRONMENT.int("GUNICORN_WORKERS", default=(cpu_resources * 2 + 1))
```

**SaaS Configuration** (from `deploy/kustomize/patches/masu.yaml`):
```yaml
- name: POD_CPU_LIMIT
  valueFrom:
    resourceFieldRef:
      containerName: koku-clowder-masu
      resource: limits.cpu
```

**On-Prem Helm Chart:** `POD_CPU_LIMIT` is **NOT SET**.

### What Happens

| Scenario | POD_CPU_LIMIT | cpu_resources | Workers | Memory Impact |
|----------|---------------|---------------|---------|---------------|
| **SaaS** | `100m` (from resourceFieldRef) | 0 (int) | 1 | Low (~200Mi) |
| **On-Prem** | NOT SET | Host CPUs (e.g., 16) | 33 | HIGH (OOM) |

With 16 host CPUs visible to the container:
- Workers spawned: `16 * 2 + 1 = 33`
- Each worker: ~20-30 MB
- Total: ~700-1000 MB → Exceeds 700Mi limit → **OOM KILL**

---

## Required Helm Chart Fix

### Option 1: Add POD_CPU_LIMIT (Recommended - Matches SaaS)

In `cost-onprem/templates/_helpers-koku.tpl` or the masu deployment template, add:

```yaml
- name: POD_CPU_LIMIT
  valueFrom:
    resourceFieldRef:
      containerName: masu  # or appropriate container name
      resource: limits.cpu
```

### Option 2: Set GUNICORN_WORKERS Explicitly

```yaml
- name: GUNICORN_WORKERS
  value: "3"  # or appropriate value for memory limit
```

### Option 3: Increase Memory Limits (Not Recommended)

```yaml
resources:
  requests:
    memory: "1Gi"
  limits:
    memory: "2Gi"
```

**Recommendation:** Use Option 1 to match SaaS behavior.

### Fix Applied

Added `POD_CPU_LIMIT` with `resourceFieldRef` to all 4 deployments:

- `cost-onprem/templates/cost-management/masu/deployment.yaml`
- `cost-onprem/templates/cost-management/api/deployment-reads.yaml`
- `cost-onprem/templates/cost-management/api/deployment-writes.yaml`
- `cost-onprem/templates/cost-management/masu/deployment-listener.yaml`

**Verification:**
```
$ kubectl exec -n cost-onprem deploy/cost-onprem-koku-api-masu -- printenv POD_CPU_LIMIT
1

$ kubectl logs -n cost-onprem deploy/cost-onprem-koku-api-masu | grep "Booting worker"
[2025-12-14 00:06:37 +0000] [19] [INFO] Booting worker with pid: 19
[2025-12-14 00:06:37 +0000] [21] [INFO] Booting worker with pid: 21
[2025-12-14 00:06:37 +0000] [20] [INFO] Booting worker with pid: 20
# Only 3 workers instead of 33!
```

---

## Affected Deployments

The `POD_CPU_LIMIT` env var should be added to all Koku deployments that run gunicorn:

| Deployment | Needs POD_CPU_LIMIT |
|------------|---------------------|
| `cost-onprem-koku-api-masu` | ✅ Yes |
| `cost-onprem-koku-api-reads` | ✅ Yes |
| `cost-onprem-koku-api-writes` | ✅ Yes |
| `cost-onprem-koku-api-listener` | ✅ Yes |
| Celery workers | ❌ No (don't use gunicorn) |

---

## SaaS Reference

From `deploy/kustomize/patches/koku-reads.yaml`:
```yaml
- name: POD_CPU_LIMIT # required to spin up appropriate number of gunicorn workers
  valueFrom:
    resourceFieldRef:
      containerName: koku-api-reads
      resource: limits.cpu
```

This pattern is used in:
- `koku-reads.yaml`
- `koku-writes.yaml`
- `masu.yaml`
- `listener.yaml`

---

## Verification After Fix

After adding `POD_CPU_LIMIT`:

```bash
# Check the environment variable is set
kubectl exec -n cost-onprem <masu-pod> -- env | grep POD_CPU_LIMIT
# Expected: POD_CPU_LIMIT=100m (or whatever the CPU limit is)

# Check gunicorn worker count in logs
kubectl logs -n cost-onprem <masu-pod> | grep "Booting worker"
# Expected: Only 1-3 workers, not 30+
```

---

## Current Image Status

```
Image: quay.io/insights-onprem/koku:latest
Branch: koku-onprem-integration
Commit: 8203cc71
Architecture: amd64
DisabledUnleashClient: ✅ Included
```

---

## Contact

- **Unleash fix / Koku image:** @jordigilh
- **Helm chart fix:** ROS Helm Chart team
