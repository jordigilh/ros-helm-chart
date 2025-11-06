# Deployment Current Status

**Updated**: 2025-11-06 14:30 EST

## 🎯 Current Situation

### ✅ Fixed Issues
1. **Configuration Error**: Fixed `NOTIFICATION_CHECK_TIME` (was "08:00", now "24")
2. **ImageStream Integration**: All 15 Koku pods now use in-cluster built image
3. **Security Contexts**: All 35 templates updated with OpenShift-compliant security contexts
4. **PostgreSQL Images**: Both Koku DB and Metastore DB use verified public image

### ⚠️ Blocking Issue: Docker Hub Rate Limits

**Current Error**:
```
Failed to pull image "trinodb/trino:latest": 
toomanyrequests: You have reached your unauthenticated pull rate limit.
https://www.docker.com/increase-rate-limit
```

**Affected Images**:
- `docker.io/trinodb/trino:latest` (Coordinator + Worker = 2 pods)
- `docker.io/apache/hive:3.1.3` (Metastore = 1 pod)

**Root Cause**: Docker Hub limits unauthenticated pulls to 100 per 6 hours per IP

## 📊 Pod Status Summary

| Component | Pods | Status | Blocker |
|-----------|------|--------|---------|
| Koku API (Reads) | 2 | CrashLoopBackOff | Waiting for Koku DB |
| Koku API (Writes) | 1 | CrashLoopBackOff | Waiting for Koku DB |
| Celery Beat | 1 | CrashLoopBackOff | Waiting for Koku DB |
| Celery Workers | 11 | CrashLoopBackOff | Waiting for Koku DB |
| **Koku DB** | **1** | **Running?** | **PostgreSQL image pulled** |
| **Trino Coordinator** | **1** | **❌ ImagePullBackOff** | **Docker Hub rate limit** |
| **Trino Worker** | **1** | **❌ ImagePullBackOff** | **Docker Hub rate limit** |
| **Hive Metastore** | **1** | **❌ ImagePullBackOff** | **Docker Hub rate limit** |
| **Metastore DB** | **1** | **Running?** | **PostgreSQL image pulled** |
| Koku Build | 1 | ✅ Completed | N/A |

## 🚀 Solutions (Choose One)

### Option 1: Mirror Images to Quay.io (RECOMMENDED)
**Best for**: Production, long-term solution

```bash
# 1. Authenticate to your Quay.io registry
skopeo login quay.io

# 2. Run the mirror script
cd /Users/jgil/go/src/github.com/insights-onprem/ros-helm-chart
./scripts/mirror-images-to-quay.sh

# 3. Update values-koku.yaml with your Quay registry
# (script will generate the exact config)

# 4. Upgrade and restart
helm upgrade cost-mgmt ./cost-management-onprem \\
  -n cost-mgmt \\
  -f cost-management-onprem/values-koku.yaml

# 5. Delete Trino pods to force repull
oc delete pods -n cost-mgmt -l app.kubernetes.io/component=trino-coordinator
oc delete pods -n cost-mgmt -l app.kubernetes.io/component=trino-worker
oc delete pods -n cost-mgmt -l app.kubernetes.io/component=trino-metastore
```

**Benefits**:
- ✅ No rate limits
- ✅ Faster pulls (your registry)
- ✅ Control over image versions
- ✅ Works for CI/CD pipelines

### Option 2: Wait for Rate Limit Reset
**Best for**: Quick testing, one-time deployment

```bash
# Docker Hub rate limits reset after 6 hours
# Current time: 14:30 EST
# Next reset: ~20:30 EST (if no other pulls from this IP)

# Check current rate limit status:
curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:trinodb/trino:pull" \\
  | jq -r '.token' \\
  | jwt decode - 2>/dev/null \\
  | grep rate

# Wait, then retry deployment
```

**Drawbacks**:
- ❌ Unpredictable (shared IP = shared limit)
- ❌ Will hit limits again on next deploy
- ❌ Not viable for CI/CD

### Option 3: Authenticate to Docker Hub
**Best for**: Temporary workaround

```bash
# 1. Create Docker Hub account (free)
# 2. Create OpenShift secret
oc create secret docker-registry dockerhub \\
  --docker-server=docker.io \\
  --docker-username=YOUR_USERNAME \\
  --docker-password=YOUR_PASSWORD \\
  -n cost-mgmt

# 3. Add to ServiceAccount
oc patch serviceaccount cost-mgmt-cost-management-onprem-trino \\
  -n cost-mgmt \\
  -p '{"imagePullSecrets": [{"name": "dockerhub"}]}'

# 4. Delete pods to retry pull
oc delete pods -n cost-mgmt -l app.kubernetes.io/component=trino-coordinator
oc delete pods -n cost-mgmt -l app.kubernetes.io/component=trino-worker
oc delete pods -n cost-mgmt -l app.kubernetes.io/component=trino-metastore
```

**Benefits**:
- ✅ Quick (if you have Docker Hub account)
- ✅ Raises limit to 200 pulls/6hr

**Drawbacks**:
- ❌ Still rate limited
- ❌ Requires credentials in cluster
- ❌ Not a long-term solution

## 📝 Files Created

### Documentation
- `docs/IMAGE-VERIFICATION-REPORT.md` - Complete image verification
- `docs/DEPLOYMENT-CURRENT-STATUS.md` - This file

### Scripts
- `scripts/mirror-images-to-quay.sh` - Automated image mirroring

### Commits
- `a1557c1` - Fix: Update Metastore DB to use verified PostgreSQL image
- `d4846b2` - Fix: Use verified Docker Hub images with migration plan
- `5950ed2` - Fix: Update all Koku templates to use ImageStream helper
- `a7474a3` - Fix: Correct NOTIFICATION_CHECK_TIME to integer value

## 🎯 Recommended Next Steps

1. **Immediate**: Choose Option 1, 2, or 3 above
2. **Once images pull successfully**: Monitor Koku DB and Metastore DB startup
3. **After databases are ready**: Koku API and Celery pods should automatically recover
4. **Validation**: Check all 25 pods are Running
5. **Testing**: Run integration tests from `docs/KOKU-DEPLOYMENT-TEST-GUIDE.md`

## 💡 Why This Happened

We hit Docker Hub rate limits because:
1. Initial deployment attempts pulled images multiple times
2. Testing different image registries used up pull quota
3. Deleting/recreating pods triggered additional pulls
4. All pulls from same IP share the limit

This is **normal** for Docker Hub and why mirroring to your own registry is standard practice for production deployments.

## 🔍 Current Image Status

| Image | Registry | Verified | Rate Limited |
|-------|----------|----------|--------------|
| `quay.io/sclorg/postgresql-13-c9s:latest` | Quay.io | ✅ | ❌ No |
| `docker.io/trinodb/trino:latest` | Docker Hub | ✅ | ⚠️ Yes |
| `docker.io/apache/hive:3.1.3` | Docker Hub | ✅ | ⚠️ Yes |
| `image-registry.../koku-api:latest` | In-cluster | ✅ Built | ❌ No |

