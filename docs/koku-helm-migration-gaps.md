# Koku to Helm Chart Migration - Component Gap Analysis

**Date**: November 6, 2025
**Purpose**: Identify all components in Koku ClowdApp that are missing from the ROS Helm chart

## Executive Summary

The Koku ClowdApp has **16 deployments** plus supporting infrastructure. The current ROS Helm chart has **8 deployments** focused on ROS-specific functionality. This document identifies the **missing 8+ Koku-specific components** that need to be added for a complete migration.

---

## Current State: What's in the Helm Chart

### ✅ Already Implemented

| Component | Type | Purpose | In Helm Chart |
|-----------|------|---------|---------------|
| **rosocp-api** | Deployment | ROS API for recommendations | ✅ Yes |
| **rosocp-processor** | Deployment | Processes uploaded cost data | ✅ Yes |
| **rosocp-recommendation-poller** | Deployment | Polls Kruize for recommendations | ✅ Yes |
| **rosocp-housekeeper** | Deployment | Maintenance tasks | ✅ Yes |
| **ingress** | Deployment | Upload service with JWT auth | ✅ Yes |
| **kruize** | Deployment | ML recommendation engine | ✅ Yes |
| **sources-api** | Deployment | Source management | ✅ Yes |
| **db-ros** | StatefulSet | PostgreSQL for ROS | ✅ Yes |
| **db-kruize** | StatefulSet | PostgreSQL for Kruize | ✅ Yes |
| **db-sources** | StatefulSet | PostgreSQL for Sources | ✅ Yes |
| **redis/valkey** | Deployment | Caching layer | ✅ Yes |
| **minio/ODF** | StatefulSet/External | Object storage | ✅ Yes |

**Total**: 8 application deployments + 5 infrastructure components = **13 pods**

---

## Gap Analysis: What's Missing from Koku ClowdApp

### ❌ Missing: Koku Cost Management Components

From the ClowdApp YAML, these components are **NOT** in the helm chart:

#### 1. Koku API Deployments (2 components)

| Component | Replicas | Purpose | Status |
|-----------|----------|---------|--------|
| **koku-api-reads** | 3 | Read-only cost management API queries | ❌ Missing |
| **koku-api-writes** | 2 | Cost management API mutations/writes | ❌ Missing |

**Key Differences from `rosocp-api`**:
- These are the **Koku/cost-management API** (different codebase)
- Use Django framework
- Connect to Koku database (not ROS database)
- Serve cost management data and reports
- Separate read/write deployments for performance

**Image**: `${IMAGE}:${IMAGE_TAG}` from ClowdApp (needs to be identified)

**Environment Variables** (~150 unique to Koku):
```yaml
- DJANGO_SECRET_KEY
- DJANGO_LOG_LEVEL
- DJANGO_LOG_FORMATTER
- GUNICORN_WORKERS
- GUNICORN_THREADS
- GUNICORN_LOG_LEVEL
- RBAC_SERVICE_PATH
- RBAC_CACHE_TTL
- PROMETHEUS_MULTIPROC_DIR
- KOKU_LOG_LEVEL
- UNLEASH_LOG_LEVEL
- KOKU_ENABLE_SENTRY
- KOKU_SENTRY_DSN
- DEMO_ACCOUNTS
- POD_CPU_LIMIT
- ACCOUNT_ENHANCED_METRICS
- CACHED_VIEWS_DISABLED
- RETAIN_NUM_MONTHS
- TAG_ENABLED_LIMIT
- USE_READREPLICA
# ... ~140 more
```

---

#### 2. Celery Worker Deployments (13 components)

All workers are **MISSING** from helm chart:

| Worker Type | Queue | Replicas | Purpose | Status |
|-------------|-------|----------|---------|--------|
| **worker-download** | `default` | 2 | Default queue, data ingestion | ❌ Missing |
| **worker-priority** | `priority` | 2 | High-priority tasks | ❌ Missing |
| **worker-priority-xl** | `priority_xl` | 2 | Large high-priority tasks | ❌ Missing |
| **worker-priority-penalty** | `priority_penalty` | 2 | Priority tasks with penalties | ❌ Missing |
| **worker-refresh** | `refresh` | 2 | Data refresh operations | ❌ Missing |
| **worker-refresh-xl** | `refresh_xl` | 2 | Large refresh operations | ❌ Missing |
| **worker-refresh-penalty** | `refresh_penalty` | 2 | Refresh with penalties | ❌ Missing |
| **worker-summary** | `summary` | 2 | Report/summary generation | ❌ Missing |
| **worker-summary-xl** | `summary_xl` | 2 | Large summary generation | ❌ Missing |
| **worker-summary-penalty** | `summary_penalty` | 2 | Summary with penalties | ❌ Missing |
| **worker-hcs** | `hcs` | 1 | HCS integration | ❌ Missing |
| **worker-subs-extraction** | `subs_extraction` | 0 | Subscription extraction (disabled) | ❌ Missing |
| **worker-subs-transmission** | `subs_transmission` | 0 | Subscription transmission (disabled) | ❌ Missing |

**Total Workers**: 13 deployments (11 active, 2 disabled)
**Total Active Pods**: 22 worker pods

**Common Worker Configuration**:
- Image: Same as Koku API
- Command: `celery worker` with specific queue
- Environment: Same base config as Koku API plus:
  - `WORKER_QUEUE` (specific to each worker)
  - `CELERY_BROKER_URL` (Redis)
  - `CELERY_RESULT_BACKEND` (Database)

---

#### 3. Celery Beat Scheduler (1 component)

| Component | Replicas | Purpose | Status |
|-----------|----------|---------|--------|
| **celery-beat** | 1 | Task scheduler for periodic jobs | ❌ Missing |

**Purpose**: Schedules periodic Celery tasks (reports, cleanup, aggregations)

**Configuration**:
```yaml
command:
  - celery
  - beat
  - --app=koku
  - --scheduler=django_celery_beat.schedulers:DatabaseScheduler
```

**Resource Requirements**:
- CPU: 50-100m
- Memory: 128-256Mi
- **Must be single replica** (leader election)

---

### Missing Infrastructure Components

#### 4. Koku Database (1 component)

| Component | Type | Purpose | Status |
|-----------|------|---------|--------|
| **db-koku** | StatefulSet | PostgreSQL for Koku cost data | ❌ Missing |

**Different from existing databases**:
- Stores cost management data (cloud costs, OCP costs, etc.)
- Much larger dataset than ROS database
- Requires **read replica support** for api-reads

**Configuration**:
```yaml
database:
  koku:
    name: koku
    user: koku
    password: ${DATABASE_PASSWORD}
    size: 20-50Gi  # Larger than ROS
    readReplica:
      enabled: true  # For api-reads performance
```

---

#### 5. Trino Query Engine (Optional but Recommended)

| Component | Type | Purpose | Status |
|-----------|------|---------|--------|
| **trino-coordinator** | StatefulSet | SQL query engine coordinator | ❌ Missing |
| **trino-worker** | Deployment | Trino query workers | ❌ Missing |

**Not explicitly in ClowdApp** but referenced in environment variables:
- `TRINO_S3A_OR_S3` environment variable in ClowdApp
- Used for querying large cost datasets from S3/object storage
- Enables complex analytical queries

**Configuration**:
```yaml
trino:
  coordinator:
    replicas: 1
    resources:
      memory: 6-8Gi
  worker:
    replicas: 2-4
    resources:
      memory: 6-8Gi
```

**Additional Requirements**:
- Hive Metastore (for table metadata)
- S3/MinIO catalog configuration

---

#### 6. Hive Metastore (Optional, for Trino)

| Component | Type | Purpose | Status |
|-----------|------|---------|--------|
| **hive-metastore** | Deployment | Metadata store for Trino | ❌ Missing |

**Required if Trino is deployed**:
- Stores table schemas and metadata
- Connects to object storage (S3/MinIO)

---

### Supporting Configuration

#### 7. Secrets and ConfigMaps

**Missing secrets**:

| Secret | Purpose | Status |
|--------|---------|--------|
| `koku-secret` | Django secret key | ❌ Missing |
| `koku-aws` | AWS credentials for cloud cost data | ❌ Missing |
| `koku-gcp` | GCP credentials for cloud cost data | ❌ Missing |
| `koku-read-only-db` | Read replica database credentials | ❌ Missing |
| `sentry-secret` (optional) | Error tracking DSN | ❌ Missing |

**Missing ConfigMaps**:
- Celery configuration
- Trino catalog configuration
- Hive metastore configuration

---

## Complete Component Matrix

### Summary Table

| Component Category | ClowdApp Count | Helm Chart Count | Missing |
|-------------------|----------------|------------------|---------|
| **API Deployments** | 2 (reads, writes) | 1 (rosocp-api) | 2 Koku APIs |
| **Workers** | 13 | 1 (rosocp-processor) | 13 Celery workers |
| **Schedulers** | 1 (celery-beat) | 0 | 1 |
| **Databases** | 1 (koku) | 3 (ros, kruize, sources) | 1 (koku) |
| **Query Engines** | 1 (trino) | 0 | 1 (trino) + metastore |
| **Supporting Services** | Various | Various | - |
| **Total Deployments** | 16+ | 8 | **8+** |

---

## Detailed Missing Components List

### Priority 1: Core Koku Components (Required)

1. ✅ **koku-api-reads** (Deployment)
   - Replicas: 3
   - Image: Koku Django application
   - Connects to: Koku read replica DB
   - Exposes: `/api/cost-management/v1/*`

2. ✅ **koku-api-writes** (Deployment)
   - Replicas: 2
   - Image: Same as api-reads
   - Connects to: Koku primary DB
   - Exposes: `/api/cost-management/v1/*` (write operations)

3. ✅ **db-koku** (StatefulSet)
   - Type: PostgreSQL 16
   - Size: 20-50Gi
   - Purpose: Store cost management data

4. ✅ **db-koku-replica** (StatefulSet, optional but recommended)
   - Type: PostgreSQL 16
   - Size: Same as primary
   - Purpose: Read replica for api-reads

---

### Priority 2: Background Processing (High Value)

5. ✅ **celery-worker-download** (Deployment)
   - Queue: `default`
   - Purpose: Data download and ingestion

6. ✅ **celery-worker-priority** (Deployment)
   - Queue: `priority`
   - Purpose: High-priority tasks

7. ✅ **celery-worker-refresh** (Deployment)
   - Queue: `refresh`
   - Purpose: Data refresh operations

8. ✅ **celery-worker-summary** (Deployment)
   - Queue: `summary`
   - Purpose: Report generation

9. ✅ **celery-worker-hcs** (Deployment)
   - Queue: `hcs`
   - Purpose: HCS integration

10. ✅ **celery-beat** (Deployment)
    - Replicas: 1
    - Purpose: Task scheduler

---

### Priority 3: Extended Workers (Optional, Can Start Disabled)

11. **celery-worker-priority-xl** (Deployment)
12. **celery-worker-priority-penalty** (Deployment)
13. **celery-worker-refresh-xl** (Deployment)
14. **celery-worker-refresh-penalty** (Deployment)
15. **celery-worker-summary-xl** (Deployment)
16. **celery-worker-summary-penalty** (Deployment)
17. **celery-worker-subs-extraction** (Deployment, currently disabled in ClowdApp)
18. **celery-worker-subs-transmission** (Deployment, currently disabled in ClowdApp)

---

### Priority 4: Analytics Engine (Optional)

19. **trino-coordinator** (StatefulSet)
    - Purpose: SQL query engine for analytics
    - Resources: 6-8Gi memory

20. **trino-worker** (Deployment)
    - Replicas: 2-4
    - Purpose: Query execution workers

21. **hive-metastore** (Deployment)
    - Purpose: Metadata store for Trino
    - Connects to: PostgreSQL, S3/MinIO

---

## Environment Variables Gap Analysis

### Koku-Specific Environment Variables (Not in ROS Chart)

From ClowdApp, these ~150 environment variables are used by Koku API and workers:

#### Django Configuration
```yaml
- DJANGO_SECRET_KEY
- DJANGO_DEBUG
- DJANGO_LOG_LEVEL (values: DEBUG, INFO, WARNING, ERROR)
- DJANGO_LOG_FORMATTER (values: json, verbose, simple)
- DJANGO_LOG_HANDLERS (values: console, watchtower, file)
- DJANGO_LOG_DIRECTORY
- DJANGO_LOGGING_FILE
```

#### Gunicorn Configuration
```yaml
- GUNICORN_WORKERS (default: 2 * CPU + 1)
- GUNICORN_THREADS
- GUNICORN_LOG_LEVEL
- POD_CPU_LIMIT (auto-calculate workers)
```

#### Database Configuration
```yaml
- DATABASE_ENGINE (postgresql)
- DATABASE_NAME
- DATABASE_USER
- DATABASE_PASSWORD
- DATABASE_HOST
- DATABASE_PORT
- DATABASE_SSLMODE
- USE_READREPLICA (true for api-reads)
- KOKU_READ_ONLY_DB (read replica credentials)
- DB_POOL_SIZE
- DB_MAX_OVERFLOW
```

#### Celery Configuration
```yaml
- CELERY_BROKER_URL
- CELERY_RESULT_BACKEND
- WORKER_QUEUE (specific to each worker)
- CELERY_LOG_LEVEL
```

#### RBAC/Authentication
```yaml
- RBAC_SERVICE_PATH
- RBAC_CACHE_TTL
- RBAC_CACHE_TIMEOUT
- CACHE_TIMEOUT
```

#### Storage Configuration
```yaml
- S3_BUCKET_NAME (or REQUESTED_BUCKET)
- S3_ENDPOINT
- S3_ACCESS_KEY
- S3_SECRET_KEY
- AWS_SHARED_CREDENTIALS_FILE
- GOOGLE_APPLICATION_CREDENTIALS
```

#### Monitoring/Observability
```yaml
- PROMETHEUS_MULTIPROC_DIR
- KOKU_ENABLE_SENTRY
- KOKU_SENTRY_ENVIRONMENT
- KOKU_SENTRY_DSN
```

#### Koku Application Settings
```yaml
- CLOWDER_ENABLED (false for helm)
- API_PATH_PREFIX (/api/cost-management/v1)
- APP_DOMAIN
- DEVELOPMENT (false for production)
- KOKU_LOG_LEVEL
- UNLEASH_LOG_LEVEL
- RETAIN_NUM_MONTHS
- NOTIFICATION_CHECK_TIME
- ACCOUNT_ENHANCED_METRICS
- CACHED_VIEWS_DISABLED
- QE_SCHEMA
- ENHANCED_ORG_ADMIN
- TAG_ENABLED_LIMIT
- DEMO_ACCOUNTS
```

#### Trino Configuration (if using Trino)
```yaml
- TRINO_HOST
- TRINO_PORT
- TRINO_S3A_OR_S3
```

---

## Migration Strategy

### Phase 1: Core Koku API (Weeks 1-2)
**Goal**: Get Koku API operational

**Components to Add**:
1. ✅ Koku database (StatefulSet)
2. ✅ Koku API-reads (Deployment)
3. ✅ Koku API-writes (Deployment)
4. ✅ Koku secrets (django-secret-key, etc.)
5. ✅ Koku service and route

**Deliverables**:
- Working Koku API endpoints
- Cost management data queries functional
- ~5 new pods

**Validation**:
```bash
curl http://koku-api/api/cost-management/v1/status/
```

---

### Phase 2: Essential Workers (Weeks 3-4)
**Goal**: Background task processing

**Components to Add**:
1. ✅ Celery Beat scheduler
2. ✅ celery-worker-download (default queue)
3. ✅ celery-worker-priority (priority queue)
4. ✅ celery-worker-refresh (refresh queue)
5. ✅ celery-worker-summary (summary queue)

**Deliverables**:
- Task queue processing
- Scheduled job execution
- ~9 new pods (1 beat + 8 workers)

**Validation**:
```bash
# Check workers are consuming
kubectl logs deployment/celery-worker-priority | grep "ready"

# Check beat is scheduling
kubectl logs deployment/celery-beat | grep "Scheduler"
```

---

### Phase 3: Extended Workers (Weeks 5-6, Optional)
**Goal**: Complete worker pool coverage

**Components to Add**:
1. ✅ celery-worker-priority-xl
2. ✅ celery-worker-priority-penalty
3. ✅ celery-worker-refresh-xl
4. ✅ celery-worker-refresh-penalty
5. ✅ celery-worker-summary-xl
6. ✅ celery-worker-summary-penalty
7. ✅ celery-worker-hcs
8. 🤔 celery-worker-subs-* (currently disabled in ClowdApp)

**Deliverables**:
- Full worker pool coverage
- Specialized task processing
- ~12 additional pods

---

### Phase 4: Analytics (Weeks 7-8, Optional)
**Goal**: Advanced query capabilities

**Components to Add**:
1. ✅ Trino coordinator
2. ✅ Trino workers
3. ✅ Hive Metastore
4. ✅ Trino configuration

**Deliverables**:
- SQL query engine
- Fast analytics queries
- ~4-6 new pods

**Validation**:
```bash
kubectl exec -it trino-coordinator -- trino --execute "SHOW CATALOGS;"
```

---

## Resource Requirements

### Current Helm Chart
- **Pods**: ~13
- **CPU**: ~4-6 cores
- **Memory**: ~12-16 GB
- **Storage**: ~40-50 GB

### After Complete Migration
- **Pods**: ~35-45
- **CPU**: ~12-16 cores
- **Memory**: ~30-40 GB
- **Storage**: ~80-100 GB

### Per-Phase Requirements

| Phase | Additional Pods | Additional CPU | Additional Memory |
|-------|----------------|----------------|-------------------|
| Phase 1 (Core Koku) | +5 | +2-3 cores | +6-8 GB |
| Phase 2 (Essential Workers) | +9 | +1-2 cores | +4-6 GB |
| Phase 3 (Extended Workers) | +12 | +2-3 cores | +6-8 GB |
| Phase 4 (Analytics) | +6 | +4-6 cores | +12-16 GB |

---

## Critical Information Needed

### Before Starting Migration

1. **Image Information** ❓
   - What is the Koku image repository? (`${IMAGE}` in ClowdApp)
   - What tag should be used? (`${IMAGE_TAG}` in ClowdApp)
   - Is it the same image for API and workers?

2. **Database Strategy** ❓
   - Should we deploy Koku database or use external?
   - Do we need read replica immediately or can add later?
   - What is the expected data size?

3. **Worker Priority** ❓
   - Which worker types are actually needed initially?
   - Can we start with 3-5 worker types instead of all 13?
   - Which queues have the most traffic?

4. **Trino Requirements** ❓
   - Is Trino actually needed?
   - Is it used in production?
   - Can it be added later?

5. **Cloud Provider Integration** ❓
   - Do we need AWS credentials support?
   - Do we need GCP credentials support?
   - Is this for multi-cloud cost ingestion?

6. **Feature Flags** ❓
   - Which Koku features should be enabled?
   - Are there any features we can skip initially?
   - What are the minimal requirements?

---

## Decision Tree

```
Start Here: Do we need full Koku functionality?
│
├─[YES] → Full Migration (Phases 1-4)
│   ├─ Phase 1: Core Koku API (Required)
│   ├─ Phase 2: Essential Workers (Highly Recommended)
│   ├─ Phase 3: Extended Workers (Optional)
│   └─ Phase 4: Analytics/Trino (Optional)
│
└─[NO] → Minimal Migration
    ├─ Only Phase 1 (API + Database)
    ├─ Add workers later as needed
    └─ Skip Trino initially

Next: What worker types are critical?
│
├─[All] → Deploy all 13 worker types (Phase 2 + 3)
├─[Essential] → Deploy 4-5 critical workers only (Phase 2)
└─[None] → API only, add workers later

Next: Do we need advanced analytics?
│
├─[YES] → Deploy Trino + Hive Metastore (Phase 4)
└─[NO] → Skip Trino, use PostgreSQL queries
```

---

## Recommendation

### Suggested Approach: **Incremental Migration**

**Week 1-2: Core Koku API** ✅
- Add Koku database
- Add api-reads and api-writes
- Verify basic API functionality
- **Pod count**: 13 → 18 (+5)

**Week 3-4: Essential Workers** ✅
- Add celery-beat scheduler
- Add 4-5 critical worker types
- Verify task processing
- **Pod count**: 18 → 27 (+9)

**Week 5+: Evaluate and Expand** 🤔
- Based on usage patterns, add:
  - More worker types if needed
  - Trino if analytics required
  - Cloud provider integration if needed

### Why This Approach?
- ✅ **Low risk**: Add components incrementally
- ✅ **Fast feedback**: Validate each phase before next
- ✅ **Flexible**: Can stop at any phase
- ✅ **Cost effective**: Don't over-provision initially
- ✅ **Learning**: Understand actual requirements before full deployment

---

## Next Steps

1. **Answer Critical Questions** above
2. **Identify Koku image** repository and tag
3. **Review Phase 1 scope** (just API or include workers?)
4. **Generate Django secret key**
5. **Create Phase 1 implementation ticket**
6. **Set up dev/test environment**

---

## Appendix: Quick Reference

### Components NOT in Helm Chart (from ClowdApp)

**Definitely Missing**:
1. koku-api-reads ❌
2. koku-api-writes ❌
3. db-koku ❌
4. celery-beat ❌
5-17. 13 celery workers ❌

**Possibly Missing** (not explicit in ClowdApp):
18. trino-coordinator ❓
19. trino-worker ❓
20. hive-metastore ❓

**Total Missing**: 17+ components

---

**Document Status**: Ready for Review
**Next Action**: Confirm missing components and prioritize migration phases

