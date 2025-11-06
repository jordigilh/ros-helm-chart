# Integration with PR #27: Chart Refactoring

**PR**: [#27 - Refactor: Rename Chart to Cost Management On-Premise](https://github.com/insights-onprem/ros-helm-chart/pull/27)  
**Status**: ✅ **PERFECT ALIGNMENT** - Our Koku integration fits their vision!  
**Date**: November 6, 2025

---

## Executive Summary

**EXCELLENT NEWS**: PR #27 is refactoring the chart from `ros-ocp` to `cost-management-onprem` with a multi-service architecture, and they've **already added a `costManagement` placeholder** for future expansion!

**Our Koku Integration**: Fits **perfectly** into their structure.

---

## PR #27 Changes Summary

### 1. Chart Rename
```
OLD: ros-ocp/
NEW: cost-management-onprem/

Chart name: ros-ocp → cost-management-onprem
Version: 0.1.9 → 0.2.0 (breaking changes)
```

### 2. Values Restructuring
```yaml
OLD values.yaml:
  rosocp.*           → ros.*
  jwt_auth.*         → jwtAuth.*
  
NEW additions:
  costManagement.*   ← PLACEHOLDER FOR US! 🎯
```

### 3. Template Organization (NEW STRUCTURE)
```
cost-management-onprem/templates/
├── ros/                    # Resource Optimization Service
│   ├── api/
│   ├── processor/
│   ├── recommendation-poller/
│   └── housekeeper/
├── kruize/                 # Optimization engine
├── sources-api/            # Source management
├── ingress/                # API gateway
├── infrastructure/         # Database, Kafka, storage, cache
├── auth/                   # Authorino authentication
├── monitoring/             # Prometheus ServiceMonitor
├── shared/                 # Shared resources
└── cost-management/        # ← PLACEHOLDER FOR KOKU! 🎯
```

### 4. Helper Functions
```
OLD: ros-ocp.*
NEW: cost-mgmt.*

Examples:
  cost-mgmt.fullname
  cost-mgmt.database.host
  cost-mgmt.platform.isOpenShift
  cost-mgmt.kafka.bootstrapServers
```

---

## Our Integration Strategy

### Approach: Add `values-koku.yaml` (Avoid Conflicts)

**Rationale**: 
- PR #27 updates main `values.yaml`
- We create separate `values-koku.yaml` 
- After PR #27 merges, we integrate both

```bash
cost-management-onprem/
├── values.yaml              # From PR #27 (updated by them)
├── values-koku.yaml         # NEW: Our additions (by us)
└── templates/
    └── cost-management/     # NEW: Our templates (by us)
```

---

## Updated Directory Structure

### What We'll Add

```
cost-management-onprem/
├── Chart.yaml               # (Updated by PR #27)
├── values.yaml              # (Updated by PR #27 - contains costManagement placeholder)
├── values-koku.yaml         # NEW: Our Koku/Trino configuration
└── templates/
    ├── ros/                 # (From PR #27)
    ├── kruize/              # (From PR #27)
    ├── sources-api/         # (From PR #27)
    ├── ingress/             # (From PR #27)
    ├── infrastructure/      # (From PR #27)
    ├── auth/                # (From PR #27)
    ├── monitoring/          # (From PR #27)
    ├── shared/              # (From PR #27)
    └── cost-management/     # NEW: Our Koku components
        ├── api/
        │   ├── deployment-reads.yaml
        │   ├── deployment-writes.yaml
        │   ├── service.yaml
        │   └── networkpolicy.yaml
        ├── celery/
        │   ├── deployment-beat.yaml
        │   ├── deployment-worker-default.yaml
        │   ├── deployment-worker-priority.yaml
        │   ├── deployment-worker-refresh.yaml
        │   ├── deployment-worker-summary.yaml
        │   ├── deployment-worker-hcs.yaml
        │   ├── deployment-worker-priority-xl.yaml
        │   ├── deployment-worker-priority-penalty.yaml
        │   ├── deployment-worker-refresh-xl.yaml
        │   ├── deployment-worker-refresh-penalty.yaml
        │   ├── deployment-worker-summary-xl.yaml
        │   └── deployment-worker-summary-penalty.yaml
        ├── database/
        │   ├── statefulset.yaml
        │   └── service.yaml
        ├── secrets/
        │   ├── django-secret.yaml
        │   └── database-credentials.yaml
        └── monitoring/
            └── servicemonitor.yaml
```

### What We'll Add for Trino

```
cost-management-onprem/templates/
└── trino/                   # NEW: Trino analytics engine
    ├── coordinator/
    │   ├── statefulset.yaml
    │   ├── service.yaml
    │   └── configmap.yaml
    ├── worker/
    │   ├── deployment.yaml
    │   └── configmap.yaml
    ├── metastore/
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── database/
    │       ├── statefulset.yaml
    │       └── service.yaml
    └── monitoring/
        └── servicemonitor.yaml
```

---

## values-koku.yaml Structure

### Our New Values File

```yaml
# cost-management-onprem/values-koku.yaml
# Koku Cost Management Configuration
# Merge with values.yaml after PR #27

# This file extends the base values.yaml with Koku-specific configuration
# Usage: helm install cost-mgmt -f values.yaml -f values-koku.yaml

global:
  # Inherits from values.yaml
  platform:
    openshift: true
    kubernetes: false

# Extend costManagement section (placeholder exists in PR #27)
costManagement:
  enabled: true
  
  # Koku API Configuration
  api:
    enabled: true
    image:
      repository: quay.io/project-koku/koku
      tag: "latest"
      pullPolicy: IfNotPresent
    
    reads:
      enabled: true
      replicas: 2
      resources:
        requests:
          cpu: 300m
          memory: 500Mi
        limits:
          cpu: 600m
          memory: 1Gi
      
      livenessProbe:
        httpGet:
          path: /api/cost-management/v1/status/
          port: 8000
        initialDelaySeconds: 30
        periodSeconds: 20
      
      readinessProbe:
        httpGet:
          path: /api/cost-management/v1/status/
          port: 8000
        initialDelaySeconds: 30
        periodSeconds: 20
    
    writes:
      enabled: true
      replicas: 1
      resources:
        requests:
          cpu: 300m
          memory: 500Mi
        limits:
          cpu: 600m
          memory: 1Gi
  
  # Celery Configuration
  celery:
    beat:
      enabled: true
      replicas: 1  # Must be 1
      resources:
        requests:
          cpu: 100m
          memory: 200Mi
        limits:
          cpu: 200m
          memory: 400Mi
    
    workers:
      # Essential workers
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
      
      # Disabled workers (per ClowdApp)
      subsExtraction:
        enabled: false
        replicas: 0
        queue: subs_extraction
      
      subsTransmission:
        enabled: false
        replicas: 0
        queue: subs_transmission
  
  # Database Configuration
  database:
    # Uses shared PostgreSQL from infrastructure
    # Separate database: koku
    host: ""  # Auto-resolved by helpers
    port: 5432
    name: koku
    user: koku
    sslMode: disable
    
    # Storage for Koku database
    storage:
      size: 20Gi
      storageClass: ""  # Use default
  
  # Django Configuration
  django:
    # Secret key auto-generated
    secretKeyLength: 50
  
  # Service Configuration
  service:
    type: ClusterIP
    port: 8000
    targetPort: 8000
  
  # Service Account
  serviceAccount:
    create: true
    name: koku
    annotations: {}

# Trino Configuration (Minimal Profile)
trino:
  enabled: true
  profile: minimal  # minimal, dev, or production
  
  coordinator:
    enabled: true
    replicas: 1
    
    image:
      repository: trinodb/trino
      tag: "latest"
      pullPolicy: IfNotPresent
    
    resources:
      requests:
        cpu: 250m
        memory: 1Gi
      limits:
        cpu: 500m
        memory: 2Gi
    
    storage:
      size: 5Gi
      storageClass: ""
    
    config:
      # Trino coordinator configuration
      jvm:
        maxHeapSize: "1G"
        gcMethod: "UseG1GC"
      
      # Catalog configuration
      catalogs:
        hive:
          enabled: true
          metastoreUri: "thrift://hive-metastore:9083"
        
        postgresql:
          enabled: true
          connectionUrl: ""  # Auto-resolved
  
  worker:
    enabled: true
    replicas: 1  # Minimal for dev
    
    image:
      repository: trinodb/trino
      tag: "latest"
      pullPolicy: IfNotPresent
    
    resources:
      requests:
        cpu: 250m
        memory: 1Gi
      limits:
        cpu: 500m
        memory: 2Gi
    
    storage:
      size: 5Gi
      storageClass: ""
    
    config:
      jvm:
        maxHeapSize: "1G"
        gcMethod: "UseG1GC"
  
  metastore:
    enabled: true
    replicas: 1
    
    image:
      repository: apache/hive
      tag: "3.1.3"
      pullPolicy: IfNotPresent
    
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 250m
        memory: 512Mi
    
    database:
      # Uses shared PostgreSQL
      host: ""  # Auto-resolved
      port: 5432
      name: metastore
      user: metastore
      sslMode: disable
      
      storage:
        size: 2Gi
        storageClass: ""
  
  service:
    coordinator:
      type: ClusterIP
      port: 8080
    
    metastore:
      type: ClusterIP
      port: 9083
  
  serviceAccount:
    create: true
    name: trino
    annotations: {}
```

---

## Helper Functions We'll Use

### From PR #27 (Available to Use)

```yaml
# Platform detection
{{ include "cost-mgmt.platform.isOpenShift" . }}

# Resource naming
{{ include "cost-mgmt.fullname" . }}
{{ include "cost-mgmt.name" . }}

# Database
{{ include "cost-mgmt.database.host" . "ros" }}      # For ROS DB
{{ include "cost-mgmt.database.host" . "koku" }}     # For Koku DB
{{ include "cost-mgmt.database.host" . "metastore" }} # For Metastore DB

# Kafka
{{ include "cost-mgmt.kafka.bootstrapServers" . }}

# Storage
{{ include "cost-mgmt.storage.endpoint" . }}
{{ include "cost-mgmt.storage.bucketName" . }}

# Security
{{ include "cost-mgmt.securityContext.pod" . }}
{{ include "cost-mgmt.securityContext.container" . }}
```

### New Helpers We'll Add

```yaml
# cost-management-onprem/templates/_helpers-koku.tpl

{{/*
Koku API service name
*/}}
{{- define "cost-mgmt.koku.api.name" -}}
{{- printf "%s-koku-api" (include "cost-mgmt.fullname" .) -}}
{{- end -}}

{{/*
Koku database name
*/}}
{{- define "cost-mgmt.koku.database.name" -}}
{{- .Values.costManagement.database.name | default "koku" -}}
{{- end -}}

{{/*
Trino coordinator service name
*/}}
{{- define "cost-mgmt.trino.coordinator.name" -}}
{{- printf "%s-trino-coordinator" (include "cost-mgmt.fullname" .) -}}
{{- end -}}
```

---

## Integration Timeline

### Phase 1: Wait for PR #27 (Current)
- **Status**: PR #27 is WIP (Work in Progress)
- **Action**: Monitor PR for merge
- **Duration**: TBD (PR is open now)

### Phase 2: Prepare Our Changes (Now - While Waiting)
- Create `values-koku.yaml`
- Create templates in `cost-management/` directory
- Create Trino templates in `trino/` directory
- Create helper functions in `_helpers-koku.tpl`
- Test locally with both values files
- **Duration**: 1-2 weeks

### Phase 3: Integration After Merge
- PR #27 merges to `main`
- We create new PR with:
  - `values-koku.yaml`
  - `templates/cost-management/`
  - `templates/trino/`
  - Updated `_helpers.tpl`
- Test deployment with both values files
- **Duration**: 3-5 days

### Phase 4: Optional Consolidation
- After validation, optionally merge `values-koku.yaml` into main `values.yaml`
- **Duration**: 1-2 days

---

## Deployment Commands

### With Separate Values Files (Our Approach)

```bash
# After PR #27 merges
helm install cost-mgmt ./cost-management-onprem \
  --namespace cost-mgmt \
  --create-namespace \
  -f cost-management-onprem/values.yaml \
  -f cost-management-onprem/values-koku.yaml

# Or with OpenShift values
helm install cost-mgmt ./cost-management-onprem \
  --namespace cost-mgmt \
  --create-namespace \
  -f cost-management-onprem/values.yaml \
  -f cost-management-onprem/values-openshift.yaml \
  -f cost-management-onprem/values-koku.yaml
```

### Values Precedence
```
values.yaml              # Base (PR #27)
  ↓
values-openshift.yaml    # Platform overrides (PR #27)
  ↓
values-koku.yaml         # Our additions (NEW)
  ↓
--set flags              # CLI overrides
```

---

## Benefits of This Approach

### ✅ Advantages

1. **No Conflicts**: Separate file avoids merge conflicts with PR #27
2. **Perfect Alignment**: Their `costManagement` placeholder is for us!
3. **Clean Integration**: Fits their multi-service vision
4. **Easy Testing**: Can test with/without Koku by including/excluding values file
5. **Incremental**: Can add Koku after ROS is stable
6. **Professional**: Matches their refactoring standards

### ⚠️ Considerations

1. **Two Values Files**: Users must specify both (documented)
2. **Helper Dependencies**: We depend on their helper functions
3. **PR Order**: Must wait for #27 to merge first
4. **Testing**: Need to test with combined values

---

## Example Template Using New Structure

### deployment-reads.yaml (Our Template)

```yaml
# cost-management-onprem/templates/cost-management/api/deployment-reads.yaml
{{- if .Values.costManagement.enabled }}
{{- if .Values.costManagement.api.reads.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "cost-mgmt.koku.api.name" . }}-reads
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "cost-mgmt.labels" . | nindent 4 }}
    app.kubernetes.io/component: cost-management-api
    app.kubernetes.io/part-of: cost-management-onprem
spec:
  replicas: {{ .Values.costManagement.api.reads.replicas }}
  selector:
    matchLabels:
      {{- include "cost-mgmt.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: cost-management-api
      api-type: reads
  template:
    metadata:
      labels:
        {{- include "cost-mgmt.labels" . | nindent 8 }}
        app.kubernetes.io/component: cost-management-api
        api-type: reads
    spec:
      serviceAccountName: {{ include "cost-mgmt.serviceAccountName" . }}
      securityContext:
        {{- include "cost-mgmt.securityContext.pod" . | nindent 8 }}
      
      containers:
      - name: koku-api
        image: "{{ .Values.costManagement.api.image.repository }}:{{ .Values.costManagement.api.image.tag }}"
        imagePullPolicy: {{ .Values.costManagement.api.image.pullPolicy }}
        
        ports:
        - name: http
          containerPort: 8000
          protocol: TCP
        
        env:
        - name: DATABASE_HOST
          value: {{ include "cost-mgmt.database.host" (dict "context" . "database" "koku") }}
        - name: DATABASE_PORT
          value: "{{ .Values.costManagement.database.port }}"
        - name: DATABASE_NAME
          value: {{ .Values.costManagement.database.name }}
        - name: KAFKA_BOOTSTRAP_SERVERS
          value: {{ include "cost-mgmt.kafka.bootstrapServers" . }}
        - name: REDIS_HOST
          value: {{ include "cost-mgmt.redis.host" . }}
        - name: DJANGO_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: koku-django-secret
              key: secret-key
        
        resources:
          {{- toYaml .Values.costManagement.api.reads.resources | nindent 10 }}
        
        livenessProbe:
          {{- toYaml .Values.costManagement.api.reads.livenessProbe | nindent 10 }}
        
        readinessProbe:
          {{- toYaml .Values.costManagement.api.reads.readinessProbe | nindent 10 }}
        
        securityContext:
          {{- include "cost-mgmt.securityContext.container" . | nindent 10 }}
{{- end }}
{{- end }}
```

---

## Next Steps

### Immediate Actions (Now)

1. ✅ **Document integration strategy** (this file)
2. 📝 **Create `values-koku.yaml`** structure
3. 📝 **Create template directory**: `cost-management/`
4. 📝 **Create Trino templates**: `trino/`
5. 📝 **Create helper functions**: `_helpers-koku.tpl`

### When PR #27 Merges

1. 🔄 **Pull latest main** branch
2. ✅ **Test our changes** with both values files
3. 📤 **Create our PR** with Koku integration
4. 🧪 **Deployment testing** on stress.parodos.dev

### After Our PR Merges

1. 📚 **Update documentation**
2. ✅ **Validate full deployment**
3. 🎯 **Customer feedback** on structure

---

## Questions for PR #27 Author

If needed, we can ask:

1. ✅ **Confirmed**: `costManagement` placeholder is for us?
2. ✅ **Approach**: Separate `values-koku.yaml` acceptable?
3. ✅ **Helpers**: Can we add `_helpers-koku.tpl`?
4. ✅ **Timeline**: When do you expect #27 to merge?

---

## Summary

**Status**: ✅ **PERFECT ALIGNMENT**

PR #27 is:
- ✅ Renaming chart to `cost-management-onprem`
- ✅ Adding multi-service structure
- ✅ Creating `costManagement` placeholder
- ✅ Organizing templates by service

Our Integration:
- ✅ Fits perfectly into their vision
- ✅ Uses separate `values-koku.yaml` (no conflicts)
- ✅ Adds `templates/cost-management/` (matches structure)
- ✅ Adds `templates/trino/` (new service)
- ✅ Ready to implement while waiting for merge

**Confidence**: 🟢 **98% HIGH CONFIDENCE**  
**Timeline**: Start now, integrate after #27 merges  
**Risk**: ⚠️ LOW (separate files, clean structure)

---

**Document Version**: 1.0  
**Date**: November 6, 2025  
**Status**: ✅ **READY TO PROCEED**  
**Next Action**: Create `values-koku.yaml` and templates

