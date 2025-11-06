# Koku Deployment Test Guide
**Testing Phases 1-4 Implementation on OpenShift**

**Date**: November 6, 2025
**Cluster**: stress.parodos.dev
**Status**: 🧪 **READY FOR TESTING**

---

## Pre-Deployment Checklist

### ✅ What We Have
- ✅ values-koku.yaml (820 lines, all configuration)
- ✅ _helpers-koku.tpl (520 lines, 50+ helpers)
- ✅ 33 templates (22 Koku + 13 Trino)
- ✅ Minimal resource profile (3.25 cores, 7.3GB RAM)

### ⚠️ What's Missing (Not Blocking)
- ⚠️ NetworkPolicies (can be added later)
- ⚠️ Documentation (for production use)

### 🔍 Pre-Flight Checks

```bash
# 1. Check you're on the right cluster
oc cluster-info

# 2. Check available resources
oc get nodes -o wide

# 3. Check if namespace exists
oc get namespace cost-mgmt

# 4. Check current context
oc whoami
oc project
```

---

## Deployment Steps

### Step 1: Create Namespace (if needed)

```bash
oc new-project cost-mgmt
```

### Step 2: Verify Chart Structure

```bash
cd /Users/jgil/go/src/github.com/insights-onprem/ros-helm-chart

# Check chart exists
ls -la cost-management-onprem/

# Verify values files exist
ls -la cost-management-onprem/values*.yaml

# Should see:
# - values.yaml (from PR #27, if merged)
# - values-koku.yaml (our new file)
```

### Step 3: Dry Run (Template Validation)

```bash
# Test template rendering without deploying
helm template cost-mgmt ./cost-management-onprem \
  -f cost-management-onprem/values-koku.yaml \
  --namespace cost-mgmt \
  --debug > /tmp/rendered-templates.yaml

# Check for errors
echo $?  # Should be 0

# Count resources that will be created
grep -c "^kind:" /tmp/rendered-templates.yaml

# Should see ~35-40 resources
```

### Step 4: Deploy Koku + Trino

```bash
# Deploy with both values files
helm install cost-mgmt ./cost-management-onprem \
  --namespace cost-mgmt \
  --create-namespace \
  -f cost-management-onprem/values-koku.yaml \
  --wait \
  --timeout 10m

# Note: We're using ONLY values-koku.yaml for now
# When PR #27 merges, we'll use both:
#   -f cost-management-onprem/values.yaml \
#   -f cost-management-onprem/values-koku.yaml
```

### Step 5: Watch Deployment

```bash
# Watch all pods in the namespace
watch -n 2 'oc get pods -n cost-mgmt'

# Or use OpenShift console
echo "OpenShift Console: https://console-openshift-console.apps.stress.parodos.dev/"
```

---

## Expected Pods

### Total Expected: 22 pods

| Component | Pods | Expected Status | Startup Time |
|-----------|------|-----------------|--------------|
| **Koku API** | | | |
| - koku-api-reads | 2 | Running | ~2-3 min |
| - koku-api-writes | 1 | Running | ~2-3 min |
| **Celery** | | | |
| - celery-beat | 1 | Running | ~1-2 min |
| - celery-worker-default | 1 | Running | ~1-2 min |
| - celery-worker-priority | 1 | Running | ~1-2 min |
| - celery-worker-refresh | 1 | Running | ~1-2 min |
| - celery-worker-summary | 1 | Running | ~1-2 min |
| - celery-worker-hcs | 1 | Running | ~1-2 min |
| - celery-worker-priority-xl | 1 | Running | ~1-2 min |
| - celery-worker-refresh-xl | 1 | Running | ~1-2 min |
| - celery-worker-summary-xl | 1 | Running | ~1-2 min |
| - celery-worker-priority-penalty | 1 | Running | ~1-2 min |
| - celery-worker-refresh-penalty | 1 | Running | ~1-2 min |
| - celery-worker-summary-penalty | 1 | Running | ~1-2 min |
| **Database** | | | |
| - koku-db-0 | 1 | Running | ~1-2 min |
| **Trino** | | | |
| - trino-coordinator-0 | 1 | Running | ~2-3 min |
| - trino-worker | 1 | Running | ~2-3 min |
| - hive-metastore | 1 | Running | ~2-3 min |
| - hive-metastore-db-0 | 1 | Running | ~1-2 min |

---

## Verification Steps

### 1. Check Pod Status

```bash
# All pods
oc get pods -n cost-mgmt

# Group by component
oc get pods -n cost-mgmt -l app.kubernetes.io/component=cost-management-api
oc get pods -n cost-mgmt -l app.kubernetes.io/component=cost-management-celery
oc get pods -n cost-mgmt -l app.kubernetes.io/component=trino-coordinator
oc get pods -n cost-mgmt -l app.kubernetes.io/component=postgresql

# Check for any failing pods
oc get pods -n cost-mgmt --field-selector=status.phase!=Running
```

### 2. Check Services

```bash
# List all services
oc get svc -n cost-mgmt

# Should see:
# - cost-mgmt-koku-api (ClusterIP, port 8000)
# - cost-mgmt-koku-db (ClusterIP None, port 5432)
# - cost-mgmt-trino-coordinator (ClusterIP, port 8080)
# - cost-mgmt-hive-metastore (ClusterIP, port 9083)
# - cost-mgmt-hive-metastore-db (ClusterIP None, port 5432)
```

### 3. Check PersistentVolumeClaims

```bash
# List PVCs
oc get pvc -n cost-mgmt

# Should see:
# - data-cost-mgmt-koku-db-0 (20Gi, Bound)
# - data-cost-mgmt-trino-coordinator-0 (5Gi, Bound)
# - data-cost-mgmt-hive-metastore-db-0 (2Gi, Bound)

# Check storage class used
oc get pvc -n cost-mgmt -o custom-columns=NAME:.metadata.name,STORAGECLASS:.spec.storageClassName,SIZE:.spec.resources.requests.storage
```

### 4. Check Secrets

```bash
# List secrets
oc get secrets -n cost-mgmt

# Should see:
# - cost-mgmt-django-secret
# - cost-mgmt-koku-db-credentials
# - cost-mgmt-metastore-db-credentials
```

### 5. Check ConfigMaps

```bash
# List configmaps
oc get cm -n cost-mgmt

# Should see:
# - cost-mgmt-trino-coordinator-config
# - cost-mgmt-trino-worker-config
# - cost-mgmt-hive-metastore-config
```

### 6. Check Logs

```bash
# Koku API (reads)
oc logs -n cost-mgmt deployment/cost-mgmt-koku-api-reads --tail=50

# Koku API (writes)
oc logs -n cost-mgmt deployment/cost-mgmt-koku-api-writes --tail=50

# Celery Beat
oc logs -n cost-mgmt deployment/cost-mgmt-celery-beat --tail=50

# Celery Worker (default)
oc logs -n cost-mgmt deployment/cost-mgmt-celery-worker-default --tail=50

# Koku Database
oc logs -n cost-mgmt statefulset/cost-mgmt-koku-db --tail=50

# Trino Coordinator
oc logs -n cost-mgmt statefulset/cost-mgmt-trino-coordinator --tail=50

# Trino Worker
oc logs -n cost-mgmt deployment/cost-mgmt-trino-worker --tail=50

# Hive Metastore
oc logs -n cost-mgmt deployment/cost-mgmt-hive-metastore --tail=50
```

### 7. Test API Health

```bash
# Port forward to Koku API
oc port-forward -n cost-mgmt svc/cost-mgmt-koku-api 8000:8000 &

# Test health endpoint (in another terminal)
curl http://localhost:8000/api/cost-management/v1/status/

# Expected response:
# {"commit":"<commit_hash>","server_address":"...","platform_info":...}

# Kill port forward
pkill -f "port-forward.*8000"
```

### 8. Test Trino Connection

```bash
# Port forward to Trino
oc port-forward -n cost-mgmt svc/cost-mgmt-trino-coordinator 8080:8080 &

# Test Trino info endpoint
curl http://localhost:8080/v1/info

# Test Trino UI (in browser)
echo "Open: http://localhost:8080/ui/"

# Kill port forward
pkill -f "port-forward.*8080"
```

---

## Common Issues & Troubleshooting

### Issue 1: Pods Stuck in `ContainerCreating`

**Symptoms**:
```bash
NAME                          READY   STATUS              RESTARTS   AGE
cost-mgmt-koku-db-0           0/1     ContainerCreating   0          5m
```

**Possible Causes**:
1. PVC not binding (storage class issue)
2. Image pull issues
3. Security context problems

**Troubleshooting**:
```bash
# Check pod events
oc describe pod <pod-name> -n cost-mgmt

# Check PVC status
oc get pvc -n cost-mgmt
oc describe pvc <pvc-name> -n cost-mgmt

# Check if storage class exists
oc get storageclass
```

**Solution**:
```bash
# If no default storage class, set one
oc patch storageclass <storage-class-name> -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

---

### Issue 2: Pods in `CrashLoopBackOff`

**Symptoms**:
```bash
NAME                          READY   STATUS             RESTARTS   AGE
cost-mgmt-koku-api-reads-...  0/1     CrashLoopBackOff   3          2m
```

**Troubleshooting**:
```bash
# Check pod logs
oc logs <pod-name> -n cost-mgmt --previous

# Check for common issues:
# - Database connection failures
# - Missing environment variables
# - Missing secrets
```

**Common Fixes**:
1. **Database not ready**: Wait for DB pod to be Running first
2. **Secret not found**: Check secrets exist
3. **Invalid config**: Check ConfigMaps

---

### Issue 3: Database Connection Failures

**Symptoms** in logs:
```
django.db.utils.OperationalError: could not connect to server
```

**Troubleshooting**:
```bash
# Check if database pod is running
oc get pods -n cost-mgmt -l app.kubernetes.io/name=koku-database

# Check database logs
oc logs -n cost-mgmt statefulset/cost-mgmt-koku-db

# Test database connection from another pod
oc run -it --rm debug --image=postgres:15-alpine --restart=Never -n cost-mgmt -- \
  psql -h cost-mgmt-koku-db -U koku -d koku
```

---

### Issue 4: Trino Not Starting

**Symptoms**:
```
Trino coordinator pod failing to start
```

**Troubleshooting**:
```bash
# Check Trino logs
oc logs -n cost-mgmt statefulset/cost-mgmt-trino-coordinator

# Check if metastore is running
oc get pods -n cost-mgmt -l app.kubernetes.io/component=hive-metastore

# Check metastore logs
oc logs -n cost-mgmt deployment/cost-mgmt-hive-metastore
```

**Common Issues**:
1. Metastore not ready yet
2. Metastore database not accessible
3. S3/MinIO credentials missing

---

### Issue 5: Missing Shared Infrastructure

**Symptoms**:
```
Error: services "redis" not found
Error: services "kafka" not found
Error: services "minio" not found
```

**Cause**: Koku templates assume shared infrastructure exists (from PR #27 / existing ROS chart)

**Solution Options**:

**Option A**: Deploy ROS first (if PR #27 is merged)
```bash
# Deploy base infrastructure + ROS
helm install cost-mgmt ./cost-management-onprem \
  --namespace cost-mgmt \
  --create-namespace \
  -f cost-management-onprem/values.yaml \
  -f cost-management-onprem/values-koku.yaml
```

**Option B**: Deploy infrastructure separately (if testing Koku standalone)
```bash
# Deploy Redis
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: cost-mgmt
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: cost-mgmt
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
EOF

# Similar for Kafka and MinIO (see existing charts)
```

---

## Resource Usage Monitoring

### Check Actual Resource Usage

```bash
# Overall namespace usage
oc adm top pods -n cost-mgmt

# Compare with requests
oc get pods -n cost-mgmt -o custom-columns=\
NAME:.metadata.name,\
CPU_REQ:.spec.containers[*].resources.requests.cpu,\
MEM_REQ:.spec.containers[*].resources.requests.memory

# Check node capacity
oc describe nodes | grep -A 5 "Allocated resources"
```

### Expected vs Actual

| Metric | Expected (Request) | Typical Actual | Status |
|--------|-------------------|----------------|---------|
| CPU | 3.25 cores | 1-2 cores | ✅ Well within limits |
| Memory | 7.3 GB | 5-6 GB | ✅ Well within limits |
| Storage | 32 Gi | 32 Gi | ✅ As expected |

---

## Success Criteria

### ✅ Deployment Successful If:

1. **All 22 pods reach `Running` state**
2. **No pods in `CrashLoopBackOff` or `Error`**
3. **All PVCs bound successfully**
4. **Koku API health endpoint responds** (200 OK)
5. **Trino coordinator accepts connections** (info endpoint works)
6. **Database migrations complete** (check Koku API logs)
7. **Celery workers connect to Redis** (check worker logs)

### Sample Success Output

```bash
$ oc get pods -n cost-mgmt
NAME                                            READY   STATUS    RESTARTS   AGE
cost-mgmt-celery-beat-xxx                       1/1     Running   0          5m
cost-mgmt-celery-worker-default-xxx             1/1     Running   0          5m
cost-mgmt-celery-worker-hcs-xxx                 1/1     Running   0          5m
cost-mgmt-celery-worker-priority-xxx            1/1     Running   0          5m
cost-mgmt-celery-worker-priority-penalty-xxx    1/1     Running   0          5m
cost-mgmt-celery-worker-priority-xl-xxx         1/1     Running   0          5m
cost-mgmt-celery-worker-refresh-xxx             1/1     Running   0          5m
cost-mgmt-celery-worker-refresh-penalty-xxx     1/1     Running   0          5m
cost-mgmt-celery-worker-refresh-xl-xxx          1/1     Running   0          5m
cost-mgmt-celery-worker-summary-xxx             1/1     Running   0          5m
cost-mgmt-celery-worker-summary-penalty-xxx     1/1     Running   0          5m
cost-mgmt-celery-worker-summary-xl-xxx          1/1     Running   0          5m
cost-mgmt-hive-metastore-xxx                    1/1     Running   0          5m
cost-mgmt-hive-metastore-db-0                   1/1     Running   0          6m
cost-mgmt-koku-api-reads-xxx                    1/1     Running   0          5m
cost-mgmt-koku-api-reads-yyy                    1/1     Running   0          5m
cost-mgmt-koku-api-writes-xxx                   1/1     Running   0          5m
cost-mgmt-koku-db-0                             1/1     Running   0          6m
cost-mgmt-trino-coordinator-0                   1/1     Running   0          5m
cost-mgmt-trino-worker-xxx                      1/1     Running   0          5m
```

---

## Next Steps After Successful Deployment

### 1. Functional Testing
- Create a test source
- Upload sample cost data
- Query via API
- Verify Trino queries work

### 2. Add NetworkPolicies
- Deploy Phase 5 NetworkPolicy templates
- Test connectivity still works
- Verify isolation between components

### 3. Performance Testing
- Monitor resource usage under load
- Adjust resource requests/limits if needed
- Scale workers if necessary

### 4. Production Readiness
- Add monitoring/alerting
- Configure backup/restore
- Document operational procedures

---

## Cleanup (if needed)

```bash
# Uninstall the release
helm uninstall cost-mgmt -n cost-mgmt

# Delete PVCs (if you want to start fresh)
oc delete pvc -n cost-mgmt --all

# Delete namespace
oc delete namespace cost-mgmt
```

---

## Summary

**What to Run**:
```bash
# 1. Dry run first
helm template cost-mgmt ./cost-management-onprem \
  -f cost-management-onprem/values-koku.yaml \
  --namespace cost-mgmt > /tmp/rendered.yaml

# 2. Deploy
helm install cost-mgmt ./cost-management-onprem \
  --namespace cost-mgmt \
  --create-namespace \
  -f cost-management-onprem/values-koku.yaml \
  --wait \
  --timeout 10m

# 3. Watch
watch -n 2 'oc get pods -n cost-mgmt'

# 4. Verify
oc port-forward -n cost-mgmt svc/cost-mgmt-koku-api 8000:8000 &
curl http://localhost:8000/api/cost-management/v1/status/
```

**Expected Result**: 22 pods Running, API responds, Trino accessible

**If Issues**: Check logs, describe pods, verify secrets/configmaps exist

---

**Status**: 🧪 **READY TO TEST**
**Confidence**: 🟢 **85% (High)** - Templates validated, may need infrastructure tweaks
**Estimated Time**: 15-30 minutes for full deployment

