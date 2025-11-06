# Koku to Helm Chart Migration - Component Checklist

**Quick Reference**: What's missing from the helm chart based on Koku ClowdApp analysis

## Summary

- **Current Helm Chart**: 8 deployments (ROS-focused)
- **Koku ClowdApp**: 16 deployments (Cost Management platform)
- **Missing**: 8+ core components + infrastructure

---

## ❌ Missing Components (Priority Order)

### Priority 1: Core Koku API (REQUIRED)

| # | Component | Type | Purpose | Image Source |
|---|-----------|------|---------|--------------|
| 1 | **koku-api-reads** | Deployment (3 replicas) | Cost management API - read queries | `${IMAGE}:${IMAGE_TAG}` from ClowdApp |
| 2 | **koku-api-writes** | Deployment (2 replicas) | Cost management API - write operations | Same as above |
| 3 | **db-koku** | StatefulSet | PostgreSQL database for cost data | `postgresql:16` |
| 4 | **koku-secret** | Secret | Django secret key | Generate new |
| 5 | **koku-service** | Service | Service for Koku API | - |

**Notes**:
- These are **different** from `rosocp-api` (different codebase, different database)
- Use Django framework
- Serve `/api/cost-management/v1/*` endpoints
- Require ~150 environment variables (vs ~20 in ROS)

---

### Priority 2: Task Scheduler (HIGHLY RECOMMENDED)

| # | Component | Type | Purpose |
|---|-----------|------|---------|
| 6 | **celery-beat** | Deployment (1 replica) | Schedules periodic Celery tasks |

**Notes**:
- Required for scheduled jobs (reports, cleanup, aggregations)
- Must be single replica (leader election)
- Uses database-backed schedule

---

### Priority 3: Essential Workers (HIGHLY RECOMMENDED)

| # | Component | Queue | Replicas | Purpose |
|---|-----------|-------|----------|---------|
| 7 | **celery-worker-download** | `default` | 2 | Data download/ingestion |
| 8 | **celery-worker-priority** | `priority` | 2 | High-priority tasks |
| 9 | **celery-worker-refresh** | `refresh` | 2 | Data refresh operations |
| 10 | **celery-worker-summary** | `summary` | 2 | Report generation |
| 11 | **celery-worker-hcs** | `hcs` | 1 | HCS integration |

**Notes**:
- All use same image as Koku API
- Different command: `celery worker --queue=<queue>`
- Connect to Redis (broker) and PostgreSQL (result backend)

---

### Priority 4: Extended Workers (OPTIONAL - Can Add Later)

| # | Component | Queue | Replicas | Notes |
|---|-----------|-------|----------|-------|
| 12 | **celery-worker-priority-xl** | `priority_xl` | 2 | Large priority tasks |
| 13 | **celery-worker-priority-penalty** | `priority_penalty` | 2 | Priority with penalties |
| 14 | **celery-worker-refresh-xl** | `refresh_xl` | 2 | Large refresh operations |
| 15 | **celery-worker-refresh-penalty** | `refresh_penalty` | 2 | Refresh with penalties |
| 16 | **celery-worker-summary-xl** | `summary_xl` | 2 | Large summaries |
| 17 | **celery-worker-summary-penalty** | `summary_penalty` | 2 | Summary with penalties |
| 18 | **celery-worker-subs-extraction** | `subs_extraction` | 0 | Disabled in ClowdApp |
| 19 | **celery-worker-subs-transmission** | `subs_transmission` | 0 | Disabled in ClowdApp |

**Notes**:
- Can start disabled and enable as needed
- Last 2 are currently disabled in production ClowdApp

---

### Priority 5: Analytics Engine (OPTIONAL)

| # | Component | Type | Purpose |
|---|-----------|------|---------|
| 20 | **trino-coordinator** | StatefulSet | SQL query engine coordinator |
| 21 | **trino-worker** | Deployment (2-4 replicas) | Query execution workers |
| 22 | **hive-metastore** | Deployment | Metadata store for Trino |

**Notes**:
- Not explicit in ClowdApp but referenced in env vars (`TRINO_S3A_OR_S3`)
- Used for complex analytical queries on large datasets
- High memory requirements (6-8Gi per pod)
- Can be added later if needed

---

### Priority 6: Database Read Replica (OPTIONAL BUT RECOMMENDED)

| # | Component | Type | Purpose |
|---|-----------|------|---------|
| 23 | **db-koku-replica** | StatefulSet | Read replica for api-reads |

**Notes**:
- Offloads 60-70% of database load
- Enables api-reads to scale independently
- Can be added after initial deployment

---

## 📋 Quick Migration Phases

### Phase 1: Minimal Viable (Week 1-2)
**Add**: Components 1-5 (Core Koku API)
- ✅ 2 API deployments
- ✅ 1 database
- ✅ Secrets and services
- **Result**: Working Koku API (~5 new pods)

### Phase 2: Background Processing (Week 3-4)
**Add**: Components 6-11 (Scheduler + Essential Workers)
- ✅ Celery beat
- ✅ 5 worker types
- **Result**: Task processing (~9 new pods)

### Phase 3: Full Workers (Week 5-6, Optional)
**Add**: Components 12-19 (Extended Workers)
- ✅ 8 additional worker types
- **Result**: Complete worker coverage (~12 new pods)

### Phase 4: Analytics (Week 7-8, Optional)
**Add**: Components 20-22 (Trino)
- ✅ Trino cluster
- ✅ Hive metastore
- **Result**: Analytics capabilities (~4-6 new pods)

---

## 🔍 Critical Information Needed

Before starting migration, answer these:

### ❓ Questions to Answer

1. **What is the Koku API image?**
   - Repository: `________________`
   - Tag: `________________`
   - Same for workers? Yes / No

2. **Database Strategy**
   - Deploy new Koku database? Yes / No
   - Use external database? Yes / No
   - Need read replica now? Yes / Later

3. **Worker Requirements**
   - Which worker types are actually used? `________________`
   - Can we start with 3-5 instead of 13? Yes / No
   - Which queues see most traffic? `________________`

4. **Trino/Analytics**
   - Is Trino needed now? Yes / No / Later
   - Is it used in production? Yes / No / Unknown

5. **Cloud Integration**
   - Need AWS credentials? Yes / No
   - Need GCP credentials? Yes / No
   - Purpose: `________________`

---

## 📊 Resource Impact

### Current State (ROS Helm Chart)
```
Pods:    ~13
CPU:     ~4-6 cores
Memory:  ~12-16 GB
Storage: ~40-50 GB
```

### After Phase 1 (Core Koku API)
```
Pods:    ~18 (+5)
CPU:     ~6-9 cores (+2-3)
Memory:  ~18-24 GB (+6-8 GB)
Storage: ~60-70 GB (+20 GB for Koku DB)
```

### After Phase 2 (+ Essential Workers)
```
Pods:    ~27 (+9)
CPU:     ~8-11 cores (+2)
Memory:  ~22-30 GB (+4-6 GB)
Storage: ~60-70 GB (same)
```

### After All Phases (Complete Migration)
```
Pods:    ~35-45 (+22-32)
CPU:     ~12-16 cores (+8-10)
Memory:  ~30-40 GB (+18-24 GB)
Storage: ~80-100 GB (+40-50 GB)
```

---

## ✅ Validation Checklist

### After Phase 1
- [ ] Koku API responds to health check
- [ ] Can query cost management endpoints
- [ ] Database migrations complete
- [ ] Secrets properly configured

```bash
# Test
curl http://koku-api/api/cost-management/v1/status/
```

### After Phase 2
- [ ] Celery beat is scheduling tasks
- [ ] Workers are consuming from queues
- [ ] Tasks complete successfully
- [ ] Redis connection working

```bash
# Test
kubectl logs deployment/celery-beat | grep "Scheduler"
kubectl logs deployment/celery-worker-priority | grep "ready"
```

### After Phase 3
- [ ] All worker types running
- [ ] No queue backlogs
- [ ] Task distribution working

### After Phase 4
- [ ] Trino accepts queries
- [ ] Hive metastore accessible
- [ ] Catalogs configured

```bash
# Test
kubectl exec -it trino-coordinator -- trino --execute "SHOW CATALOGS;"
```

---

## 🚀 Getting Started

### Step 1: Information Gathering
```bash
# Review ClowdApp for image details
grep "IMAGE" clowdapp.yaml

# Check environment variables
grep "env:" -A 200 clowdapp.yaml | less

# Identify worker configurations
grep "worker-" clowdapp.yaml
```

### Step 2: Generate Secrets
```bash
# Django secret key
python -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'

# Save to file
echo "your-secret-key" > django-secret-key.txt
```

### Step 3: Plan Phase 1
- [ ] Identify Koku image
- [ ] Create values.yaml entries
- [ ] Create deployment templates
- [ ] Create secret templates
- [ ] Create service templates
- [ ] Test deployment

---

## 📚 Reference Documents

- **[Complete Gap Analysis](docs/koku-helm-migration-gaps.md)** - Detailed component analysis
- **[Implementation Guide](docs/koku-migration-implementation-guide.md)** - Step-by-step templates
- **[Koku ClowdApp Source](https://github.com/insights-onprem/koku/blob/main/deploy/clowdapp.yaml)** - Original configuration

---

## 🎯 Recommended Next Action

1. ✅ **Answer the 5 critical questions** above
2. ✅ **Identify Koku image** repository and tag
3. ✅ **Choose migration phase** (1, 1+2, or all)
4. ✅ **Review implementation guide** for Phase 1
5. ✅ **Create Jira/GitHub issues** for tracking
6. ✅ **Set up test environment**
7. ✅ **Begin Phase 1 implementation**

---

**Last Updated**: November 6, 2025
**Status**: Ready for Implementation
**Next Review**: After Phase 1 completion

