# Chart Merger Decision: Cost Management + ROS

**Date**: November 7, 2025
**Status**: 🤔 **DECISION REQUIRED**
**Context**: Two charts need to be merged into one unified deployment

---

## Executive Summary

**Current State**:
- ✅ `ros-ocp` chart: 57 templates, mature, includes infrastructure (Redis, DBs, MinIO)
- ✅ `cost-management-onprem` chart: 37 templates, new, Koku + Trino components
- ✅ Kafka: Deployed externally via `scripts/deploy-kafka.sh` ✅
- ✅ S3: Fixed to use ODF NooBaa (not MinIO) ✅

**Problem**:
- Redis exists in `ros-ocp`, not in `cost-management-onprem`
- Koku needs Redis to function
- Charts were developed in parallel, now need to merge

**Decision Required**: Which approach to take?

---

## Option A: Merge Koku INTO ros-ocp (Recommended ⭐)

### Approach
Add Cost Management components to the existing `ros-ocp` chart.

### Pros ✅
1. **Infrastructure already exists**: Redis, databases, MinIO patterns
2. **Mature chart structure**: 57 templates, proven deployment scripts
3. **Less disruption**: ROS continues to work as-is
4. **Natural namespace**: Already called "ros-ocp", can rename to "platform"
5. **Values organization**: Already has `ros`, `kruize`, `sources` sections - just add `costManagement`
6. **Helper functions**: Can reuse existing helpers for storage, cache, etc.
7. **PR #27 alignment**: `ros-ocp` was just refactored, ready for extension

### Cons ❌
1. Chart becomes larger (57 + 37 = ~94 templates)
2. Need to adapt Koku templates to use `ros-ocp` helpers
3. `ros-ocp` name may be misleading if it includes Cost Management

### Implementation Effort
**Estimated Time**: 2-3 hours

**Steps**:
1. Copy `cost-management-onprem/templates/cost-management/` → `ros-ocp/templates/cost-management/`
2. Copy `cost-management-onprem/templates/trino/` → `ros-ocp/templates/trino/`
3. Merge `values-koku.yaml` into `ros-ocp/values.yaml` (or keep as overlay)
4. Update Koku templates to use `ros-ocp` helper functions
5. Test deployment

---

## Option B: Merge ros-ocp INTO cost-management-onprem

### Approach
Add ROS components to the new `cost-management-onprem` chart.

### Pros ✅
1. **Future-focused**: Aligns with PR #27 naming ("cost-management-onprem")
2. **Clean slate**: Can reorganize structure optimally
3. **Name alignment**: Chart name matches primary purpose

### Cons ❌
1. **Must copy infrastructure**: Redis, MinIO, all database templates
2. **Risky**: Breaks existing `ros-ocp` deployments
3. **More work**: Need to ensure ROS components work with new helpers
4. **Loss of maturity**: `ros-ocp` has proven deployment patterns
5. **Helper adaptation**: `ros-ocp` templates expect `ros-ocp.*` helpers

### Implementation Effort
**Estimated Time**: 4-6 hours

**Steps**:
1. Copy all `ros-ocp/templates/` → `cost-management-onprem/templates/ros/`
2. Copy infrastructure templates (Redis, DBs, MinIO)
3. Merge all helper functions
4. Update all ROS templates to use `cost-mgmt` helpers
5. Extensive testing (may break ROS)

---

## Option C: Keep Separate, Reference Infrastructure

### Approach
Deploy `ros-ocp` first (includes Redis), then `cost-management-onprem` references it.

### Pros ✅
1. **Separation of concerns**: Clear boundaries
2. **Independent updates**: Update Koku without touching ROS
3. **No refactoring**: Use charts as-is

### Cons ❌
1. **Complex deployment**: Two-step process (ros-ocp → cost-management-onprem)
2. **Shared resources**: Redis/Kafka accessed across namespaces (complex)
3. **Dependency management**: Must ensure ros-ocp deployed first
4. **Namespace issues**: ExternalName services across namespaces
5. **User confusion**: "I deployed cost-management, why isn't it working?"

### Implementation Effort
**Estimated Time**: 1 hour

**Steps**:
1. Update `cost-management-onprem` to expect external Redis
2. Document deployment order
3. Create wrapper script

---

## Comparison Matrix

| Criteria | Option A: Koku → ros-ocp | Option B: ROS → cost-mgmt | Option C: Separate |
|----------|-------------------------|---------------------------|-------------------|
| **Complexity** | ⭐⭐⭐ Medium | ⭐⭐⭐⭐⭐ High | ⭐⭐ Low |
| **Risk** | ⭐⭐ Low | ⭐⭐⭐⭐ High | ⭐⭐⭐ Medium |
| **Time to Implement** | 2-3 hours | 4-6 hours | 1 hour |
| **Future Maintainability** | ⭐⭐⭐⭐ Good | ⭐⭐⭐⭐⭐ Excellent | ⭐⭐ Poor |
| **User Experience** | ⭐⭐⭐⭐⭐ Single command | ⭐⭐⭐⭐⭐ Single command | ⭐⭐ Two commands |
| **Infrastructure Reuse** | ⭐⭐⭐⭐⭐ Excellent | ⭐⭐⭐ Medium | ⭐⭐⭐⭐ Good |
| **Aligns with PR #27** | ⭐⭐⭐ Partial | ⭐⭐⭐⭐⭐ Perfect | ⭐⭐ No |
| **Backwards Compatible** | ⭐⭐⭐⭐ Yes (ros-ocp exists) | ⭐ No (breaks ros-ocp) | ⭐⭐⭐⭐⭐ Yes |

---

## Recommendation: Option A ⭐

**Merge Koku INTO ros-ocp chart**

### Rationale

1. **Fastest path to working deployment**: Infrastructure already exists
2. **Lowest risk**: Doesn't break existing ROS deployments
3. **Proven foundation**: ros-ocp chart is mature and tested
4. **Natural evolution**: Extending existing platform chart
5. **Simple for users**: Single `helm install` command

### Naming Consideration

If concerned about "ros-ocp" name being misleading:

**Option A1**: Keep name, update description
```yaml
# ros-ocp/Chart.yaml
name: ros-ocp
description: Resource Optimization Service and Cost Management platform for OpenShift
```

**Option A2**: Rename chart (breaking change, needs migration)
```yaml
# Chart.yaml
name: platform-services
# OR
name: insights-platform
# OR
name: cost-management-platform
```

---

## Current Deployment Status

### Working Components ✅
- Trino Coordinator + Worker
- Hive Metastore + DB
- Koku DB
- Koku API (waiting for Redis)
- All Celery workers (waiting for Redis)
- S3 access (ODF NooBaa) **FIXED**

### Blocked Components ❌
- Koku API: Needs Redis
- Celery workers: Need Redis + Kafka alias
- Celery Beat: Needs Redis

### External Dependencies (Already Deployed) ✅
- Kafka (via `scripts/deploy-kafka.sh`)
- ODF S3 (`s3.openshift-storage.svc:80`)

---

## What's Already Fixed (Keep Regardless) ✅

These fixes are valid for any option:

1. **S3 Endpoint Configuration**
   - Changed from `minio:9000` to `s3.openshift-storage.svc:80`
   - Made configurable via `infrastructure.storage.endpoint`
   - Deployed and tested ✅

2. **Koku Database Configuration**
   - Fixed environment variables for `EnvConfigurator`
   - Database migrations working ✅

3. **Celery Worker Commands**
   - Corrected startup commands for all 13 workers
   - All workers running (waiting for Redis/Kafka) ✅

4. **Security Context**
   - All pods comply with OpenShift PodSecurity
   - `seccompProfile` configured ✅

5. **Trino Configuration**
   - Fixed JVM configuration
   - Removed deprecated properties
   - Hadoop S3A environment variables ✅

6. **Hive Metastore**
   - Persistent storage (PVC)
   - No AWS dependencies ✅

---

## Implementation Plan (Option A - Recommended)

### Phase 1: Prepare ros-ocp Chart (30 mins)
```bash
# 1. Create cost-management section in ros-ocp/values.yaml
# 2. Update ros-ocp/Chart.yaml description
# 3. Create ros-ocp/templates/cost-management/ directory
```

### Phase 2: Copy Koku Templates (45 mins)
```bash
# Copy all cost-management templates
cp -r cost-management-onprem/templates/cost-management/ \
      ros-ocp/templates/cost-management/

# Copy all trino templates
cp -r cost-management-onprem/templates/trino/ \
      ros-ocp/templates/trino/

# Copy helper functions
# Merge cost-management-onprem/templates/_helpers-koku.tpl into ros-ocp/templates/_helpers.tpl
```

### Phase 3: Adapt Templates (60 mins)
```bash
# Update templates to use ros-ocp helpers:
# - ros-ocp.fullname → ros-ocp.fullname
# - ros-ocp.labels → ros-ocp.labels
# - ros-ocp.selectorLabels → ros-ocp.selectorLabels
# - ros-ocp.securityContext.* → ros-ocp.securityContext.*

# Update Redis/Kafka references:
# - Use existing ros-ocp.cache.* helpers for Redis
# - Use existing ros-ocp.kafka.* helpers for Kafka
```

### Phase 4: Test Deployment (30 mins)
```bash
# Deploy unified chart
helm install unified-platform ./ros-ocp \
  --namespace platform \
  --create-namespace \
  -f ros-ocp/openshift-values.yaml

# Verify all pods
oc get pods -n platform

# Test connectivity
# - Koku → Redis
# - Koku → Kafka
# - Koku → S3
# - Koku → Trino
```

---

## Implementation Plan (Option B - If Chosen)

### Phase 1: Copy Infrastructure (90 mins)
```bash
# Copy infrastructure templates from ros-ocp
cp ros-ocp/templates/deployment-redis.yaml cost-management-onprem/templates/infrastructure/
cp ros-ocp/templates/service-redis.yaml cost-management-onprem/templates/infrastructure/
cp ros-ocp/templates/service-kafka-alias.yaml cost-management-onprem/templates/infrastructure/
# ... (all other infrastructure)
```

### Phase 2: Copy ROS Components (90 mins)
```bash
# Copy all ROS application templates
cp -r ros-ocp/templates/ cost-management-onprem/templates/ros/
# (Exclude infrastructure already copied)
```

### Phase 3: Merge Helpers (60 mins)
```bash
# Merge ros-ocp/templates/_helpers.tpl into cost-management-onprem/templates/_helpers.tpl
# Resolve naming conflicts
# Ensure all helpers work for both ROS and Koku
```

### Phase 4: Update All Templates (90 mins)
```bash
# Update ALL ROS templates to use cost-mgmt.* helpers
# Update values references
# Test each component
```

### Phase 5: Extensive Testing (60 mins)
```bash
# Test ROS components still work
# Test Koku components work
# Test integration between components
```

---

## Files Changed (Regardless of Option)

### Already Committed ✅
- `cost-management-onprem/templates/_helpers.tpl` - S3 endpoint fix
- `cost-management-onprem/values-koku.yaml` - Infrastructure config

### Documentation Created ✅
- `docs/S3-STORAGE-CONFIGURATION.md` - S3/ODF/MinIO analysis
- `docs/DEPLOYMENT-TRIAGE-REPORT.md` - Infrastructure gaps identified
- `docs/CHART-MERGER-DECISION.md` - This document

---

## Questions to Consider

1. **Chart naming**: Keep "ros-ocp" or rename to reflect both services?
2. **Values structure**: Separate files (`-f ros-values.yaml -f koku-values.yaml`) or single unified file?
3. **Backwards compatibility**: Do existing ros-ocp deployments need to continue working?
4. **Namespace strategy**: Single namespace or multiple?
5. **Release cadence**: Will ROS and Koku be updated together or independently?

---

## Recommended Next Steps (Tomorrow)

### Morning ☕
1. **Review this document**
2. **Decide on Option A, B, or C**
3. **Answer questions above**
4. **Approve implementation plan**

### Implementation 🚀
1. **Execute chosen option** (2-6 hours depending on choice)
2. **Test deployment** (full stack)
3. **Run integration test** (upload payload → verify processing)
4. **Document** (update README, deployment guide)
5. **Commit and push** (create PR if needed)

---

## Current Git Status

```bash
$ git status
On branch: feature/koku-integration-post-pr27
Last commit: fa14c37 "fix: Configure S3 endpoint for ODF NooBaa (not MinIO)"

Modified files:
- cost-management-onprem/templates/_helpers.tpl (S3 fix)
- cost-management-onprem/values-koku.yaml (infrastructure config)

New files:
- docs/S3-STORAGE-CONFIGURATION.md
- docs/DEPLOYMENT-TRIAGE-REPORT.md
- docs/CHART-MERGER-DECISION.md
```

---

## Summary for Tomorrow

**What I discovered today**:
- ✅ S3 was pointing to non-existent MinIO → Fixed to use ODF NooBaa
- ❌ Redis is in `ros-ocp` chart, not `cost-management-onprem`
- ❌ Kafka alias is in `ros-ocp` chart, not `cost-management-onprem`
- ✅ All other components are working
- 🤔 Need to merge the two charts

**What needs to be decided**:
- Which chart becomes the base?
- What should the final chart be named?
- Single values file or multiple overlays?

**My recommendation**:
- ⭐ **Option A**: Merge Koku INTO ros-ocp (fastest, lowest risk, 2-3 hours)

**Alternative**:
- Option B: Merge ROS INTO cost-management-onprem (cleaner long-term, higher risk, 4-6 hours)

**Not recommended**:
- Option C: Keep separate charts (complex for users, maintenance burden)

---

**Good night! 🌙**
**Everything is documented and ready for your decision tomorrow.**

