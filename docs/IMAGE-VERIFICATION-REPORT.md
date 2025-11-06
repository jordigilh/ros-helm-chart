# Image Verification Report

**Generated**: 2025-11-06

## Summary

| Component | Current Image | Status | Action Needed |
|-----------|--------------|--------|---------------|
| PostgreSQL (Koku DB) | `quay.io/sclorg/postgresql-13-c9s:latest` | ✅ **VERIFIED PUBLIC** | None - Use as-is |
| PostgreSQL (Metastore DB) | `quay.io/sclorg/postgresql-13-c9s:latest` | ✅ **VERIFIED PUBLIC** | None - Use as-is |
| Trino Coordinator | `docker.io/trinodb/trino:latest` | ⚠️ **DOCKER HUB ONLY** | **MIRROR TO QUAY** |
| Trino Worker | `docker.io/trinodb/trino:latest` | ⚠️ **DOCKER HUB ONLY** | **MIRROR TO QUAY** |
| Hive Metastore | `docker.io/apache/hive:3.1.3` | ⚠️ **DOCKER HUB ONLY** | **MIRROR TO QUAY** |
| Koku API | `image-registry.openshift-image-registry.svc:5000/cost-mgmt/...` | ✅ **IN-CLUSTER BUILD** | None - Built from source |

## Verified Images (No Action Needed)

### ✅ PostgreSQL - `quay.io/sclorg/postgresql-13-c9s:latest`
- **Registry**: Quay.io (Red Hat Software Collections)
- **Digest**: `sha256:7f19bb0d2e5553e5d766572bd522d5a02767e75adf35dc4455f22ae980738b8e`
- **Status**: Public, no rate limits, OpenShift-optimized
- **Reason**: SCLorg (Software Collections) is Red Hat's official community project, widely used in OpenShift
- **Action**: ✅ Use as-is

## Images Requiring Migration

### ⚠️ Trino - `docker.io/trinodb/trino:latest`
- **Current Location**: Docker Hub
- **Digest**: `sha256:177bda76e5e6caf235de4502e10020a029d06dd2625709fbf5adf264b6295a1d`
- **Issue**: Docker Hub rate limits (100 pulls/6 hours for unauthenticated)
- **Target**: `quay.io/insights-onprem/trino:latest` (or your org name)
- **Action**: 🔄 **MIRROR REQUIRED**
- **Priority**: HIGH (used by Coordinator + Worker = 2 pods)

### ⚠️ Hive Metastore - `docker.io/apache/hive:3.1.3`
- **Current Location**: Docker Hub
- **Digest**: `sha256:d102ba29ad07e93c303894896203a80b903c0001d80221f1cb9fea92dcac06e4`
- **Issue**: Docker Hub rate limits
- **Target**: `quay.io/insights-onprem/hive:3.1.3` (or your org name)
- **Action**: 🔄 **MIRROR REQUIRED**
- **Priority**: MEDIUM (used by Metastore = 1 pod)

## Migration Plan

### Phase 1: Immediate (Use Docker Hub for Testing)
**Status**: Ready to deploy for testing
- Update `values-koku.yaml` to use Docker Hub images
- Document rate limit risk
- Deploy and validate functionality
- **Timeline**: Now

### Phase 2: Mirror to Quay.io (Avoid Rate Limits)
**Status**: Requires Quay.io credentials
- Pull images from Docker Hub
- Push to `quay.io/insights-onprem/` (or your org)
- Update `values-koku.yaml` to use mirrored images
- **Timeline**: Before production deployment

### Phase 3: Automate Updates (Optional)
**Status**: Post-production
- Set up image mirroring pipeline (e.g., GitHub Actions, Tekton)
- Schedule weekly/monthly syncs from Docker Hub
- Monitor for security updates
- **Timeline**: After initial production deployment

## Rate Limit Impact Analysis

### Current Risk
- **3 images** from Docker Hub (Trino x2, Hive x1)
- **Max deployments per 6 hours**: ~33 (100 pulls / 3 images)
- **Risk Level**: 
  - Development/Testing: LOW (infrequent deployments)
  - CI/CD Pipeline: MEDIUM (frequent deployments)
  - Multi-tenant/Multi-cluster: HIGH (parallel deployments)

### After Mirroring
- **0 images** from Docker Hub
- **Max deployments**: UNLIMITED
- **Risk Level**: NONE

## Next Steps

1. **Immediate**: Revert values-koku.yaml to use Docker Hub
   ```bash
   # Update trino images
   trinodb/trino:latest  # Not ghcr.io or quay.io
   
   # Update hive image
   apache/hive:3.1.3     # Not quay.io/apache/hive
   ```

2. **Before Production**: Run the mirror script (see below)
   ```bash
   ./scripts/mirror-images-to-quay.sh
   ```

3. **After Mirroring**: Update values-koku.yaml to use quay.io

## Mirror Script

See: `scripts/mirror-images-to-quay.sh`

This script will:
- Pull images from Docker Hub
- Authenticate to your Quay.io registry
- Push images with proper tags
- Verify successful mirror
- Output updated values.yaml snippets

