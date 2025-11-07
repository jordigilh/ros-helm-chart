# ClowdApp vs Helm Chart Comparison

**Date**: November 7, 2025
**Source**: `../koku/deploy/clowdapp.yaml` (207 KB, 6514 lines)
**Target**: `cost-management-onprem` Helm chart
**Scope**: Koku-specific components only (excluding infrastructure: Redis, PostgreSQL, Kafka)

---

## Executive Summary

### ✅ What We Have (Correctly Implemented)

1. **API Deployments** ✅
   - api-reads
   - api-writes

2. **Celery Workers** ✅ (more than SaaS)
   - SaaS: 2 workers (subs-extraction, subs-transmission)
   - Ours: 12 workers (default, hcs, priority variants, refresh variants, summary variants)
   - **Note**: Our implementation is MORE comprehensive

3. **Celery Beat** ✅ (not in SaaS ClowdApp)
   - We have it deployed
   - SaaS likely uses a separate scheduling mechanism

4. **Trino Stack** ✅ (not in ClowdApp - consumed as AWS managed service)
   - We correctly added Trino coordinator, worker, Hive metastore
   - This is REQUIRED for on-prem (SaaS uses AWS Athena/EMR)

---

## ❌ What We're Missing (Koku-Specific Components)

### 1. **Nginx Proxy (clowder-api)** ⚠️ **MAYBE NEEDED**

**ClowdApp**:
```yaml
- name: clowder-api
  podSpec:
    command: [nginx, -g, daemon off;]
    image: ${NGINX_IMAGE}:${NGINX_IMAGE_TAG}
    env:
      - name: ROS_OCP_API
        value: ${ROS_OCP_API}
```

**Purpose**:
- Proxies requests to api-reads and api-writes
- May handle load balancing between read/write APIs
- References ROS_OCP_API (integration with ROS)

**Current State in Our Chart**: ❌ Not deployed

**Impact**:
- **Low** if we expose api-reads/api-writes services directly
- **High** if SaaS clients expect specific routing behavior
- **Unknown** what the nginx config does (need to check Koku repo)

**Recommendation**:
- **For on-prem**: Likely NOT needed - we can expose Koku API service directly
- **For SaaS compatibility**: Investigate nginx config in Koku repo

---

### 2. **Kafka Listener (clowder-listener)** ❌ **MISSING - CRITICAL**

**ClowdApp**:
```yaml
- name: clowder-listener
  podSpec:
    command:
      - /bin/bash
      - -c
      - python koku/manage.py listener
    env:
      - name: KAFKA_CONNECT
        value: ${KAFKA_CONNECT}
```

**Purpose**:
- Runs Django management command: `manage.py listener`
- Consumes messages from Kafka
- Likely handles real-time data ingestion

**Current State in Our Chart**: ❌ **NOT DEPLOYED**

**Impact**: 🚨 **HIGH - CRITICAL**
- Without this, Koku cannot consume Kafka messages
- Cost data uploaded to platform won't be processed in real-time
- Integration testing will fail

**What is `manage.py listener`?**
- Custom Django command in Koku
- Listens to Kafka topics
- Triggers data processing workflows

**Recommendation**: ✅ **ADD THIS DEPLOYMENT**

---

### 3. **Database Migration Job** ❌ **MISSING**

**ClowdApp**:
```yaml
jobs:
  - name: db-migrate-cji-${DBM_IMAGE_TAG}-${DBM_INVOCATION}
    podSpec:
      args:
        - /bin/bash
        - -c
        - python koku/manage.py migrate --noinput
```

**Purpose**:
- Runs Django migrations before deployments
- Ensures database schema is up-to-date

**Current State in Our Chart**: ❌ **NOT DEPLOYED**

**Impact**: ⚠️ **MEDIUM**
- We manually ran migrations during deployment
- Future upgrades will require manual migration runs
- Not automated

**Recommendation**: ✅ **ADD AS HELM PRE-UPGRADE HOOK**

---

### 4. **Management Command Job** ℹ️ **OPTIONAL**

**ClowdApp**:
```yaml
jobs:
  - name: management-command-cji-${MGMT_IMAGE_TAG}-${MGMT_INVOCATION}
    podSpec:
      command:
        - /bin/bash
        - -c
        - python koku/manage.py ${COMMAND}
```

**Purpose**:
- Runs arbitrary Django management commands
- Used for operational tasks (data fixes, cleanup, etc.)
- Triggered manually in SaaS

**Current State in Our Chart**: ❌ Not deployed

**Impact**: ℹ️ **LOW**
- Not needed for regular operations
- Can be run manually via `kubectl exec` if needed

**Recommendation**: ⏸️ **SKIP FOR NOW**

---

## 📊 Deployment Comparison Matrix

| Component | ClowdApp | Our Chart | Status | Action |
|-----------|----------|-----------|--------|--------|
| **API Reads** | ✅ | ✅ | ✅ Match | None |
| **API Writes** | ✅ | ✅ | ✅ Match | None |
| **Nginx Proxy** | ✅ clowder-api | ❌ | ⚠️ Gap | Investigate if needed |
| **Kafka Listener** | ✅ clowder-listener | ❌ | 🚨 **CRITICAL GAP** | **Add deployment** |
| **Celery Workers** | ✅ (2 types) | ✅ (12 types) | ✅ Better | None |
| **Celery Beat** | ❌ (external?) | ✅ | ✅ Better | None |
| **DB Migration Job** | ✅ | ❌ | ⚠️ Gap | Add as Helm hook |
| **Mgmt Command Job** | ✅ | ❌ | ℹ️ Optional | Skip |
| **Trino Stack** | ❌ (AWS) | ✅ | ✅ **REQUIRED** | None |
| **PostgreSQL** | ✅ (Clowder) | ✅ (ros-ocp) | ✅ Covered | None |
| **Redis** | ✅ (Clowder) | ✅ (ros-ocp) | ✅ Covered | None |
| **Kafka** | ✅ (Clowder) | ✅ (external) | ✅ Covered | None |

---

## 🔍 Deep Dive: Missing Components

### Critical: Kafka Listener (clowder-listener)

#### What Does It Do?

Let me check the Koku source code for the `listener` command:

**Expected Location**: `../koku/koku/koku/management/commands/listener.py`

**Purpose** (based on ClowdApp context):
- Consumes Kafka messages from cost data topics
- Triggers Celery tasks for data processing
- Handles real-time ingestion pipeline

#### Environment Variables

```yaml
- KAFKA_CONNECT: ${KAFKA_CONNECT}          # Kafka bootstrap servers
- KOKU_LOG_LEVEL: ${LISTENER_KOKU_LOG_LEVEL}
- CLOWDER_ENABLED: ${CLOWDER_ENABLED}       # Must be "False" for on-prem
```

#### Resource Requirements (from ClowdApp)

```yaml
resources:
  limits:
    cpu: 500m
    memory: 1Gi
  requests:
    cpu: 100m
    memory: 256Mi
```

#### Deployment Spec

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: koku-listener
spec:
  replicas: 1
  selector:
    matchLabels:
      app: koku-listener
  template:
    metadata:
      labels:
        app: koku-listener
    spec:
      containers:
      - name: listener
        image: quay.io/cloudservices/koku:latest
        command:
          - /bin/bash
          - -c
          - python koku/manage.py listener
        env:
          # ... (same as API pods, plus KAFKA_CONNECT)
```

---

### Important: Nginx Proxy (clowder-api)

#### What Does It Do?

**Hypothesis**: Routes traffic between:
- External requests → api-reads (GET requests)
- External requests → api-writes (POST/PUT/DELETE requests)
- Possibly integrates with ROS (ROS_OCP_API env var)

**Nginx Config Location**: Likely in `../koku/` repo

#### Do We Need It?

**For On-Prem**: Probably **NO**
- We can use Kubernetes Service with proper selectors
- Ingress/Route can handle external routing
- Simple deployments don't need nginx layer

**For SaaS Compatibility**: Possibly **YES** if:
- Nginx config has special routing logic
- Handles authentication/authorization
- Required for ROS integration

**Recommendation**:
1. Check if nginx config exists in Koku repo
2. If simple (just proxy), skip it
3. If complex (auth, special routing), add it

---

### Important: Database Migration Hook

#### Current State

**Manual Migrations**:
We manually ran:
```bash
oc exec -it <koku-api-pod> -- python koku/manage.py migrate --noinput
```

#### Proposed Solution

**Helm Pre-Upgrade Hook**:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: koku-db-migrate-{{ .Release.Revision }}
  annotations:
    helm.sh/hook: pre-upgrade,pre-install
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: db-migrate
        image: {{ .Values.costManagement.api.image }}
        command:
          - /bin/bash
          - -c
          - python koku/manage.py migrate --noinput
        env:
          # ... (same DB env vars as API)
```

**Benefits**:
- Automatic migrations on chart upgrades
- No manual intervention required
- Helm manages job lifecycle

---

## 🧪 Testing Impact

### Integration Test Requirements

**Current Test**: Upload payload → Verify processing

**What Won't Work Without Listener**:
1. Upload payload to ingress ✅
2. Ingress sends to Kafka ✅
3. **Listener consumes from Kafka** ❌ **MISSING**
4. **Listener triggers Celery tasks** ❌ **BLOCKED**
5. Celery workers process data ⏸️ (won't be triggered)
6. Data written to S3/PostgreSQL ⏸️ (won't happen)
7. Trino queries data ⏸️ (no data to query)

**Impact**: 🚨 **Integration test will FAIL without listener**

---

## 🎯 Priority Fixes

### P0 - Critical (Blocks Integration Testing)

#### 1. Add Kafka Listener Deployment
**Files to Create**:
- `cost-management-onprem/templates/cost-management/deployment-listener.yaml`

**Configuration** (values-koku.yaml):
```yaml
costManagement:
  listener:
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 1Gi
```

**Template**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "cost-mgmt.koku.api.name" . }}-listener
  labels:
    {{- include "cost-mgmt.labels" . | nindent 4 }}
    app.kubernetes.io/component: koku-listener
spec:
  replicas: {{ .Values.costManagement.listener.replicas }}
  selector:
    matchLabels:
      {{- include "cost-mgmt.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: koku-listener
  template:
    metadata:
      labels:
        {{- include "cost-mgmt.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: koku-listener
    spec:
      securityContext:
        {{- include "cost-mgmt.securityContext.pod" . | nindent 8 }}
      containers:
      - name: listener
        image: {{ include "cost-mgmt.koku.image" . }}
        imagePullPolicy: {{ .Values.costManagement.api.image.pullPolicy }}
        securityContext:
          {{- include "cost-mgmt.securityContext.container" . | nindent 10 }}
        command:
          - /bin/bash
          - -c
          - python koku/manage.py listener
        env:
        {{- include "cost-mgmt.koku.commonEnv" . | nindent 8 }}
        - name: KOKU_LOG_LEVEL
          value: {{ .Values.costManagement.listener.logLevel | default "INFO" | quote }}
        resources:
          {{- toYaml .Values.costManagement.listener.resources | nindent 10 }}
```

**Estimated Time**: 30 minutes

---

### P1 - Important (Operations)

#### 2. Add DB Migration Helm Hook
**Files to Create**:
- `cost-management-onprem/templates/cost-management/job-db-migrate.yaml`

**Estimated Time**: 20 minutes

---

### P2 - Nice to Have (Optimization)

#### 3. Investigate Nginx Proxy
**Action**:
1. Search for nginx config in `../koku/` repo
2. Evaluate if needed for on-prem
3. Add if required

**Estimated Time**: 1-2 hours (investigation + implementation)

---

## 📝 Summary

### Critical Gaps (Must Fix Before Integration Testing)

1. **Kafka Listener** ❌
   - **Status**: NOT deployed
   - **Impact**: CRITICAL - blocks data ingestion
   - **Effort**: 30 minutes
   - **Priority**: P0

### Important Gaps (Fix Before Production)

2. **DB Migration Hook** ❌
   - **Status**: Manual process
   - **Impact**: HIGH - requires manual intervention on upgrades
   - **Effort**: 20 minutes
   - **Priority**: P1

### Optional Components (Investigate)

3. **Nginx Proxy** ⚠️
   - **Status**: Unknown if needed
   - **Impact**: UNKNOWN - depends on nginx config
   - **Effort**: 1-2 hours
   - **Priority**: P2

---

## ✅ What We Did Better

### 1. Comprehensive Celery Worker Deployment

**SaaS (ClowdApp)**: 2 workers
- subs-extraction
- subs-transmission

**Ours**: 12 workers + Beat
- default
- hcs
- priority (+ penalty, xl variants)
- refresh (+ penalty, xl variants)
- summary (+ penalty, xl variants)

**Why Better**:
- More granular queue management
- Better resource allocation
- Optimized for different workload types

---

### 2. Self-Hosted Trino Stack

**SaaS (ClowdApp)**: Uses AWS managed services (Athena/EMR)
**Ours**: Full Trino deployment (coordinator, worker, metastore)

**Why Better**:
- Required for on-prem (no AWS dependency)
- Complete control over configuration
- Persistent Hive Metastore with local warehouse

---

### 3. Celery Beat Scheduler

**SaaS (ClowdApp)**: Not present (likely external scheduling)
**Ours**: Dedicated Celery Beat deployment

**Why Better**:
- Self-contained scheduling
- No external dependencies
- Standard Celery pattern

---

## 🎯 Recommended Next Steps

### Immediate (Before Integration Testing)

1. ✅ **Add Kafka Listener deployment** (30 mins)
2. ✅ **Test listener connectivity** to Kafka
3. ✅ **Run integration test**: Upload → Listener → Celery → Processing

### Short-Term (Before Production)

4. ✅ **Add DB migration Helm hook** (20 mins)
5. ⏸️ **Investigate nginx proxy** (1-2 hours if needed)

### Long-Term (Optimization)

6. ⏸️ **Review celery worker types** - do we need all 12?
7. ⏸️ **Add management command job** (if needed for operations)

---

## 📚 Files to Review

### In Koku Repo (`../koku/`)

1. `koku/koku/management/commands/listener.py` - Kafka listener implementation
2. `deploy/nginx/` or similar - Nginx configuration
3. `koku/koku/celery.py` - Celery configuration (queue names)

### In Our Chart

1. Need to create: `deployment-listener.yaml`
2. Need to create: `job-db-migrate.yaml`
3. May need to create: `deployment-nginx.yaml` (TBD)

---

**Status**: Ready to implement P0 fix (Kafka Listener)
**Blocker**: Listener is CRITICAL for integration testing
**Timeline**: ~30 minutes to add, then full stack will be functional

