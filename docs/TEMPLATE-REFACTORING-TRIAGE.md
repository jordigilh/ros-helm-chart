# Template Refactoring Triage

**Date**: November 6, 2025
**Purpose**: Identify and refactor hardcoded values in templates

---

## Executive Summary

**Found**: 12 categories of hardcoded values that should be moved to `values.yaml`
**Impact**: Medium - Affects flexibility and portability
**Priority**: P2 - Should be fixed before production use

---

## Hardcoded Values Found

### 1. Image Registry (HIGH PRIORITY) ⚠️

**Location**: `templates/_helpers-koku.tpl:525`

```yaml
{{- printf "image-registry.openshift-image-registry.svc:5000/%s/%s:%s" .Release.Namespace ...
```

**Issue**:
- Hardcoded OpenShift internal registry address
- Not portable to other Kubernetes distributions
- **User specifically requested this be dynamically discovered**

**Impact**: Chart only works on OpenShift with standard registry setup

**Fix**: Move to values.yaml, auto-discover from cluster, or allow override

---

### 2. Database Service Name

**Location**: `templates/_helpers-koku.tpl:476`

```yaml
- name: DATABASE_SERVICE_NAME
  value: "database"
```

**Issue**: Hardcoded to `"database"`

**Impact**: Cannot customize if using external database with different naming

**Fix**: Add to values.yaml: `costManagement.database.serviceName`

---

### 3. Database Engine

**Location**: `templates/_helpers-koku.tpl:478`

```yaml
- name: DATABASE_ENGINE
  value: "postgresql"
```

**Issue**: Hardcoded to PostgreSQL

**Impact**: None (Koku only supports PostgreSQL), but should still be configurable

**Fix**: Add to values.yaml: `costManagement.database.engine`

---

### 4. Redis Host

**Location**: `templates/_helpers.tpl:69`

```yaml
{{- define "cost-mgmt.redis.host" -}}
{{- printf "redis" -}}
{{- end -}}
```

**Issue**: Hardcoded to `"redis"`

**Impact**: Cannot use external Redis or different service name

**Fix**: Add to values.yaml: `redis.host` or `redis.service.name`

---

### 5. Redis Port

**Location**: `templates/_helpers.tpl:76`

```yaml
{{- define "cost-mgmt.redis.port" -}}
{{- 6379 -}}
{{- end -}}
```

**Issue**: Hardcoded to `6379`

**Impact**: Cannot use non-standard Redis port

**Fix**: Add to values.yaml: `redis.port` or `redis.service.port`

---

### 6. Kafka Bootstrap Servers

**Location**: `templates/_helpers.tpl:83`

```yaml
{{- define "cost-mgmt.kafka.bootstrapServers" -}}
{{- printf "kafka:29092" -}}
{{- end -}}
```

**Issue**: Hardcoded to `kafka:29092`

**Impact**: Cannot use external Kafka or different service name/port

**Fix**: Add to values.yaml: `kafka.bootstrapServers` or separate `kafka.host` and `kafka.port`

---

### 7. Kafka Port (Duplicate)

**Location**: `templates/_helpers-koku.tpl:212`

```yaml
{{- define "cost-mgmt.koku.kafka.port" -}}
{{- 29092 -}}
{{- end -}}
```

**Issue**: Hardcoded to `29092`

**Impact**: Duplicate of #6, inconsistent with bootstrap servers

**Fix**: Use port from `kafka.bootstrapServers` or separate config

---

### 8. S3 Credentials Secret Name

**Location**: `templates/trino/coordinator/statefulset.yaml:40,45`
**Location**: `templates/trino/worker/deployment.yaml` (same lines)

```yaml
secretKeyRef:
  name: noobaa-admin
  key: AWS_ACCESS_KEY_ID
```

**Issue**: Hardcoded to `noobaa-admin` (OpenShift Data Foundation specific)

**Impact**:
- Only works with ODF
- Cannot use external S3 or different secret name

**Fix**: Add to values.yaml: `trino.s3.credentials.secretName`

---

### 9. Default Port Numbers

**Locations**: Multiple helpers with `| default 5432`, `| default 8080`, `| default 9083`

**Issue**: While these are defaults (good!), they should be explicit in values.yaml

**Impact**: Low - defaults are appropriate, but hidden from users

**Fix**: Make explicit in values.yaml instead of inline defaults

---

### 10. Default Database Names

**Locations**:
- `_helpers-koku.tpl:120` - `default "koku"`
- `_helpers-koku.tpl:161` - `default "metastore"`

**Issue**: Same as #9

**Fix**: Make explicit in values.yaml

---

### 11. Default Bucket Names

**Locations**:
- `_helpers-koku.tpl:232` - `default "koku-report"`
- `_helpers-koku.tpl:239` - `default "ros-report"`

**Issue**: Currently reading from env vars with defaults (better than pure hardcode)

**Impact**: Low - already somewhat configurable

**Fix**: Ensure these are properly documented in values.yaml

---

### 12. S3 Endpoint Discovery

**Location**: `templates/_helpers.tpl` (missing!)

```yaml
{{- define "cost-mgmt.storage.endpoint" -}}
{{- /* TODO: Should be configurable */ -}}
{{- end -}}
```

**Issue**: S3 endpoint discovery is incomplete

**Impact**: HIGH - referenced by Koku helpers but not defined

**Fix**: Add proper S3/MinIO endpoint configuration to values.yaml

---

## Refactoring Priority

### P0 - Critical (Must Fix)
1. ✅ S3 Endpoint Discovery (currently broken reference)

### P1 - High Priority (Should Fix)
2. ⚠️ Image Registry Discovery (user requested)
3. ⚠️ S3 Credentials Secret Name (portability)
4. ⚠️ Kafka Bootstrap Servers (infrastructure dependency)
5. ⚠️ Redis Host/Port (infrastructure dependency)

### P2 - Medium Priority (Nice to Have)
6. Database Service Name
7. Database Engine
8. Kafka Port (cleanup duplicate)

### P3 - Low Priority (Documentation)
9. Default Port Numbers (make explicit)
10. Default Database Names (make explicit)
11. Default Bucket Names (already configurable)

---

## Proposed values.yaml Structure

```yaml
# Infrastructure dependencies
infrastructure:
  redis:
    host: "redis"
    port: 6379

  kafka:
    bootstrapServers: "kafka:29092"
    # Alternative split format:
    # host: "kafka"
    # port: 29092

  storage:
    # S3/MinIO endpoint
    endpoint: "http://s3.openshift-storage.svc:80"
    # Credentials secret (ODF/external S3)
    credentialsSecret:
      name: "noobaa-admin"
      accessKeyKey: "AWS_ACCESS_KEY_ID"
      secretKeyKey: "AWS_SECRET_ACCESS_KEY"

# Cluster-specific settings
cluster:
  # OpenShift internal image registry
  imageRegistry:
    # Auto-discover: use cluster's internal registry
    autoDiscover: true
    # Or specify explicitly:
    host: "image-registry.openshift-image-registry.svc"
    port: 5000

# Cost Management specific
costManagement:
  database:
    serviceName: "database"
    engine: "postgresql"
    host: ""  # Auto-resolved if empty
    port: 5432
    name: "koku"
    user: "koku"

  api:
    image:
      useImageStream: true
      repository: "quay.io/project-koku/koku"
      tag: "latest"

# Trino specific
trino:
  coordinator:
    service:
      port: 8080

  metastore:
    service:
      port: 9083
    database:
      port: 5432
      name: "metastore"
      user: "metastore"
```

---

## Image Registry Auto-Discovery

For OpenShift, we can auto-discover the internal registry:

**Option 1**: Use well-known address (current)
```yaml
image-registry.openshift-image-registry.svc:5000
```

**Option 2**: Allow override in values.yaml
```yaml
cluster:
  imageRegistry:
    enabled: true
    host: ""  # Auto-discover if empty
    port: 5000
```

**Option 3**: Query from cluster (not possible in Helm templates)

**Recommendation**: Option 2 - allow override but default to OpenShift standard

---

## Migration Strategy

### Phase 1: Add values.yaml entries (No Breaking Changes)
1. Add all new configuration to values.yaml with current hardcoded values as defaults
2. Update templates to read from values.yaml but keep fallbacks
3. Test that nothing breaks

### Phase 2: Remove hardcoded fallbacks
1. Remove inline defaults from templates
2. Rely solely on values.yaml
3. Update documentation

### Phase 3: Cleanup
1. Remove duplicate helper definitions
2. Consolidate infrastructure helpers
3. Add validation

---

## Estimated Effort

| Task | Time | Files Changed |
|------|------|---------------|
| Add values.yaml entries | 30 min | 1 file |
| Update _helpers.tpl | 30 min | 1 file |
| Update _helpers-koku.tpl | 45 min | 1 file |
| Update Trino templates | 30 min | 2 files |
| Testing | 30 min | - |
| Documentation | 30 min | 1 file |
| **Total** | **3-4 hours** | **6 files** |

---

## Benefits of Refactoring

1. ✅ **Portability**: Chart works on any Kubernetes distribution
2. ✅ **Flexibility**: Users can customize infrastructure dependencies
3. ✅ **Transparency**: All configuration visible in values.yaml
4. ✅ **Maintainability**: Easier to update and test
5. ✅ **Best Practice**: Follows Helm chart conventions

---

## Testing Checklist

After refactoring, verify:

- [ ] Chart installs successfully on OpenShift
- [ ] All pods start and become Ready
- [ ] Koku API can connect to Redis
- [ ] Koku API can connect to Kafka
- [ ] Koku API can connect to PostgreSQL
- [ ] Trino can connect to Hive Metastore
- [ ] Trino can access S3/MinIO
- [ ] Image builds work (if using ImageStream)
- [ ] All environment variables are correctly set

---

## Recommendations

1. **Start with P1 items**: Fix high-priority hardcoded values first
2. **Maintain backward compatibility**: Use current values as defaults
3. **Document changes**: Update README with new configuration options
4. **Add validation**: Use Helm's fail function for required values
5. **Test thoroughly**: Especially infrastructure connections

---

**Status**: Ready for refactoring ✅
**Next Step**: Implement Phase 1 changes

