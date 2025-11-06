# Single Chart Implementation Plan

**Date**: November 6, 2025
**Status**: ✅ **READY FOR IMPLEMENTATION**
**Confidence**: 🟢 **95% HIGH CONFIDENCE**

---

## Executive Summary

**Decision**: Implement **single Helm chart** (not 3 charts) containing:
- ✅ Existing ROS components
- ✅ Infrastructure (PostgreSQL, Redis, MinIO, Ingress)
- ✅ Koku components (API + 13 workers)
- ✅ Trino (minimal profile for validation)

**Rationale**:
- Faster iteration
- Simpler for initial deployment
- Wait for customer feedback before splitting
- Can refactor to multiple charts later

---

## Implementation Answers Summary

| Question | Answer | Implementation Impact |
|----------|--------|---------------------|
| **Koku Image** | `quay.io/project-koku/koku` | ✅ Ready to use |
| **Analytics** | Trino with minimal profile | ✅ 4-6GB resources |
| **Environment** | OpenShift, integration tests | ✅ Minimal resources, OCP-specific features |
| **Secrets** | Generate all automatically | ✅ Helm hooks for secret generation |
| **Chart Strategy** | Single chart | ✅ Extend existing ros-ocp chart |
| **Koku Workers** | All 13 with minimal resources | ✅ Development profile |
| **Testing** | None yet | ⚠️ Manual validation needed |
| **Network Policies** | Yes, OCP only, service-based | ✅ Analyze interactions |
| **Monitoring** | ServiceMonitor exists | ✅ Add for new services |
| **Backup** | None | ✅ Skip for now |

---

## Architecture: Single Chart Approach

### Current Structure
```
ros-ocp/
├── Chart.yaml
├── values.yaml
├── values-openshift.yaml
└── templates/
    ├── ROS components (existing)
    ├── Infrastructure (existing: DBs, Redis, MinIO)
    └── NEW: Add Koku + Trino
```

### Extended Structure (What We'll Add)
```
ros-ocp/templates/
├── [Existing ROS components - unchanged]
├── [Existing infrastructure - unchanged]
├── NEW: Koku Components
│   ├── deployment-koku-api-reads.yaml
│   ├── deployment-koku-api-writes.yaml
│   ├── deployment-koku-celery-beat.yaml
│   ├── deployment-koku-celery-worker-default.yaml
│   ├── deployment-koku-celery-worker-priority.yaml
│   ├── deployment-koku-celery-worker-refresh.yaml
│   ├── deployment-koku-celery-worker-summary.yaml
│   ├── deployment-koku-celery-worker-hcs.yaml
│   ├── deployment-koku-celery-worker-priority-xl.yaml
│   ├── deployment-koku-celery-worker-priority-penalty.yaml
│   ├── deployment-koku-celery-worker-refresh-xl.yaml
│   ├── deployment-koku-celery-worker-refresh-penalty.yaml
│   ├── deployment-koku-celery-worker-summary-xl.yaml
│   ├── deployment-koku-celery-worker-summary-penalty.yaml
│   ├── statefulset-db-koku.yaml
│   ├── service-koku-api.yaml
│   ├── secret-koku-django.yaml (auto-generated)
│   ├── configmap-koku.yaml
│   └── networkpolicy-koku.yaml (OCP only)
├── NEW: Trino Components
│   ├── statefulset-trino-coordinator.yaml
│   ├── deployment-trino-worker.yaml
│   ├── deployment-hive-metastore.yaml
│   ├── statefulset-db-hive-metastore.yaml
│   ├── service-trino-coordinator.yaml
│   ├── service-hive-metastore.yaml
│   ├── configmap-trino.yaml
│   └── networkpolicy-trino.yaml (OCP only)
└── NEW: Updated Ingress
    └── deployment-ingress.yaml (update to insights-ingress-go)
```

---

## Resource Requirements (Minimal Development Profile)

### Total Cluster Requirements
Based on minimal profile for integration testing:

| Component | Pods | CPU Request | Memory Request | CPU Limit | Memory Limit | Storage |
|-----------|------|-------------|----------------|-----------|--------------|---------|
| **Existing ROS** | ~13 | ~4 cores | ~10 GB | ~6 cores | ~16 GB | ~40 GB |
| **Koku API** | 5 | 1.5 cores | 3 GB | 3 cores | 6 GB | - |
| **Koku Workers** | 13 | 1.3 cores | 2.6 GB | 2.6 cores | 5.2 GB | - |
| **Koku DB** | 1 | 0.5 cores | 1 GB | 1 core | 2 GB | 20 GB |
| **Trino** | 4 | 0.65 cores | 2.5 GB | 1.35 cores | 5 GB | 12 GB |
| **TOTAL** | **~36** | **~8 cores** | **~19 GB** | **~14 cores** | **~34 GB** | **~72 GB** |

**Cluster Minimum**:
- CPU: 10-12 cores (with overhead)
- Memory: 24-30 GB (with overhead)
- Storage: 100 GB

---

## Implementation Steps

### Step 1: Update Chart Metadata (Day 1)
```yaml
# ros-ocp/Chart.yaml
name: ros-ocp
version: 2.0.0  # Bump version
description: Resource Optimization Service with Cost Management
dependencies: []  # No external charts
```

### Step 2: Extend values.yaml (Day 1)
Add Koku and Trino configuration sections to existing `values.yaml`:

```yaml
# ros-ocp/values.yaml

# ... existing ROS configuration ...

# NEW: Koku Configuration
koku:
  enabled: true

  image:
    repository: quay.io/project-koku/koku
    tag: "latest"  # TODO: Specify version
    pullPolicy: IfNotPresent

  api:
    reads:
      enabled: true
      replicas: 2  # Minimal for dev
      resources:
        requests:
          cpu: 300m
          memory: 500Mi
        limits:
          cpu: 600m
          memory: 1Gi

    writes:
      enabled: true
      replicas: 1  # Minimal for dev
      resources:
        requests:
          cpu: 300m
          memory: 500Mi
        limits:
          cpu: 600m
          memory: 1Gi

  celery:
    beat:
      enabled: true
      replicas: 1  # Must be 1 (single scheduler)
      resources:
        requests:
          cpu: 100m
          memory: 200Mi
        limits:
          cpu: 200m
          memory: 400Mi

    workers:
      default:
        enabled: true
        replicas: 1
        queue: default
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      priority:
        enabled: true
        replicas: 1
        queue: priority
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      refresh:
        enabled: true
        replicas: 1
        queue: refresh
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      summary:
        enabled: true
        replicas: 1
        queue: summary
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      hcs:
        enabled: true
        replicas: 1
        queue: hcs
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      # XL workers (minimal for dev)
      priorityXl:
        enabled: true
        replicas: 1
        queue: priority_xl
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      priorityPenalty:
        enabled: true
        replicas: 1
        queue: priority_penalty
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      refreshXl:
        enabled: true
        replicas: 1
        queue: refresh_xl
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      refreshPenalty:
        enabled: true
        replicas: 1
        queue: refresh_penalty
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      summaryXl:
        enabled: true
        replicas: 1
        queue: summary_xl
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      summaryPenalty:
        enabled: true
        replicas: 1
        queue: summary_penalty
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 200m
            memory: 400Mi

      subsExtraction:
        enabled: false  # Disabled per ClowdApp
        replicas: 0
        queue: subs_extraction

      subsTransmission:
        enabled: false  # Disabled per ClowdApp
        replicas: 0
        queue: subs_transmission

  database:
    # Use existing PostgreSQL but separate database
    host: db-ros.{{ .Release.Namespace }}.svc.cluster.local
    port: 5432
    name: koku
    user: koku
    # Password generated automatically
    sslMode: disable

  django:
    # Secret key generated automatically
    secretKeyLength: 50

  service:
    type: ClusterIP
    port: 8000

# NEW: Trino Configuration (Minimal Profile)
trino:
  enabled: true
  profile: minimal  # minimal, dev, or production

  coordinator:
    enabled: true
    replicas: 1
    resources:
      requests:
        cpu: 250m
        memory: 1Gi
      limits:
        cpu: 500m
        memory: 2Gi
    storage:
      size: 5Gi

  worker:
    enabled: true
    replicas: 1  # Minimal for dev
    resources:
      requests:
        cpu: 250m
        memory: 1Gi
      limits:
        cpu: 500m
        memory: 2Gi
    storage:
      size: 5Gi

  metastore:
    enabled: true
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 250m
        memory: 512Mi

    database:
      # Use existing PostgreSQL
      host: db-ros.{{ .Release.Namespace }}.svc.cluster.local
      port: 5432
      name: metastore
      user: metastore
      # Password generated automatically
      storage:
        size: 2Gi

# UPDATE: Ingress (use insights-ingress-go)
ingress:
  enabled: true
  # ... existing config ...
  # Update image to insights-ingress-go per reassessment
```

### Step 3: Create Koku Templates (Day 2-3)
Create 16 new Koku-related template files (see structure above).

### Step 4: Create Trino Templates (Day 3-4)
Create 7 new Trino-related template files.

### Step 5: Add Network Policies (Day 4-5)
Analyze service interactions and create NetworkPolicies for OpenShift.

### Step 6: Update Existing Components (Day 5)
- Update PostgreSQL to create koku + metastore databases
- Update Ingress to use insights-ingress-go
- Add Koku/Trino to valid upload types

### Step 7: Testing & Validation (Day 6-10)
- Deploy to test cluster
- Validate all components start
- Test service connectivity
- Validate Kafka message flow

---

## Secret Generation Strategy

### Auto-Generated Secrets
Use Helm's `randAlphaNum` function:

```yaml
# secret-koku-django.yaml
apiVersion: v1
kind: Secret
metadata:
  name: koku-django-secret
type: Opaque
data:
  secret-key: {{ randAlphaNum 50 | b64enc | quote }}

# secret-db-koku.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-koku-credentials
type: Opaque
data:
  password: {{ randAlphaNum 16 | b64enc | quote }}

# secret-db-metastore.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-metastore-credentials
type: Opaque
data:
  password: {{ randAlphaNum 16 | b64enc | quote }}
```

**Note**: These are generated once at `helm install`. Upgrade won't change them.

---

## Network Policy Analysis

### Service Communication Matrix

| Source | Destination | Port | Protocol | Purpose |
|--------|------------|------|----------|---------|
| koku-api | db-koku | 5432 | TCP | Database queries |
| koku-api | redis | 6379 | TCP | Cache |
| koku-api | kafka | 9092 | TCP | Messages |
| koku-api | minio | 9000 | TCP | Object storage |
| koku-api | trino-coordinator | 8080 | TCP | SQL queries |
| koku-celery-* | db-koku | 5432 | TCP | Database queries |
| koku-celery-* | redis | 6379 | TCP | Queue/cache |
| koku-celery-* | kafka | 9092 | TCP | Messages |
| koku-celery-* | minio | 9000 | TCP | Object storage |
| koku-celery-* | trino-coordinator | 8080 | TCP | SQL queries |
| trino-coordinator | hive-metastore | 9083 | TCP | Metadata |
| trino-coordinator | minio | 9000 | TCP | Data access |
| trino-coordinator | db-metastore | 5432 | TCP | Metastore DB |
| trino-worker | trino-coordinator | 8080 | TCP | Cluster comm |
| trino-worker | minio | 9000 | TCP | Data access |
| hive-metastore | db-metastore | 5432 | TCP | Database |
| ingress | koku-api | 8000 | TCP | HTTP requests |
| ingress | rosocp-api | 8000 | TCP | HTTP requests |

### NetworkPolicy Example (OCP Only)
```yaml
{{- if .Values.global.platform.openshift }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: koku-api
spec:
  podSelector:
    matchLabels:
      app: koku-api
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: ingress
    ports:
    - protocol: TCP
      port: 8000
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: postgresql
    ports:
    - protocol: TCP
      port: 5432
  - to:
    - podSelector:
        matchLabels:
          app: redis
    ports:
    - protocol: TCP
      port: 6379
  # ... more egress rules ...
{{- end }}
```

---

## Timeline & Deliverables

### Week 1: Foundation (Days 1-5)
- [x] Understand requirements
- [ ] Update Chart.yaml and values.yaml
- [ ] Create Koku deployment templates
- [ ] Create Koku service templates
- [ ] Update PostgreSQL to add koku database
- **Deliverable**: Can deploy Koku API (no workers yet)

### Week 2: Workers & Trino (Days 6-10)
- [ ] Create all 13 Celery worker templates
- [ ] Create Trino coordinator + worker templates
- [ ] Create Hive metastore templates
- [ ] Update MinIO configuration
- **Deliverable**: Full Koku + Trino deployment

### Week 3: Integration (Days 11-15)
- [ ] Update ingress to insights-ingress-go
- [ ] Create NetworkPolicies
- [ ] Secret generation implementation
- [ ] Integration testing
- **Deliverable**: Fully integrated chart

### Week 4: Polish & Docs (Days 16-20)
- [ ] Resource optimization
- [ ] Documentation updates
- [ ] Deployment scripts
- [ ] Troubleshooting guide
- **Deliverable**: Production-ready chart

---

## Validation Checklist

### After Deployment
- [ ] All pods in Running state
- [ ] Koku API responds to `/api/cost-management/v1/status/`
- [ ] Celery beat is scheduling tasks
- [ ] Workers are consuming from queues
- [ ] Trino coordinator accepts queries
- [ ] Kafka messages flow correctly
- [ ] Database connections working
- [ ] Redis connections working
- [ ] MinIO buckets accessible
- [ ] Network policies allow required traffic
- [ ] Secrets generated correctly

---

## Risks & Mitigations

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Resource constraints | Medium | High | Start minimal, monitor, adjust |
| Koku image issues | Low | High | Test image availability first |
| Trino memory usage | Medium | Medium | Use minimal profile, can disable |
| Network policy blocks | Medium | Medium | Test without first, add incrementally |
| Secret generation issues | Low | High | Test Helm functions early |
| Integration complexity | Medium | High | Incremental deployment |

---

## Next Immediate Actions

### Right Now (I can start):
1. **Check cluster resources** (running command)
2. **Create feature branch**: `feature/single-chart-koku-integration`
3. **Update values.yaml** with Koku section
4. **Create first Koku template**: `deployment-koku-api-reads.yaml`

### Today (You can decide):
- Which Koku version/tag to use?
- Any specific configuration requirements for Koku?
- Should I start with just Koku API first, or full deployment?

---

## Questions for Source Code Analysis

For NetworkPolicy creation, should I analyze:
1. **Koku repository** (`../koku/`) for:
   - What services Koku connects to
   - What ports it uses
   - API endpoints exposed

2. **Trino configuration** for:
   - Coordinator-worker communication
   - Metastore connections
   - Client connections

**Permission**: May I read the Koku source code to understand service interactions?

---

**Status**: ✅ **READY TO IMPLEMENT**
**Confidence**: 🟢 **95% HIGH CONFIDENCE**
**Timeline**: 4 weeks to production-ready single chart
**Immediate Next Step**: Update values.yaml with Koku configuration

Should I proceed with implementation?

