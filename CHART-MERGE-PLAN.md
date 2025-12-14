# Chart Merge Plan: cost-management-onprem → cost-onprem

## Overview

This document describes the plan to merge the `cost-management-onprem` Helm chart into the `cost-onprem` chart, consolidating all Cost Management on-premise components into a single authoritative chart.

## Current Architecture

The on-premise deployment consists of three separate Helm charts deployed in sequence:

```
┌─────────────────────────────────────────────────────────┐
│ PHASE 1: cost-onprem-infra                 │
│                                                         │
│  PostgreSQL ──┬── koku_db (Koku/Django data)            │
│               └── metastore_db (Hive metadata)          │
│                                                         │
│  Trino Coordinator ◄──► Hive Metastore                  │
│  Trino Workers                                          │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│ PHASE 2: cost-onprem                                    │
│                                                         │
│  PostgreSQL ──┬── ros_db                                │
│               ├── kruize_db                             │
│               └── sources_db                            │
│                                                         │
│  ROS API, Processor, Recommendation Poller              │
│  Kruize (optimization engine)                           │
│  Sources API                                            │
│  UI + OAuth Proxy                                       │
│  Ingress (Envoy + JWT validation)                       │
│  Redis/Valkey (cache)                                   │
│  MinIO (vanilla K8s) / ODF (OpenShift)                  │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│ PHASE 3: cost-management-onprem                         │
│                                                         │
│  Koku API (reads + writes deployments)                  │
│  Celery Beat + 18 Worker deployments                    │
│  Masu (data processing)                                 │
│  Kafka Listener                                         │
│                                                         │
│  Connects to:                                           │
│   - Infrastructure chart's PostgreSQL (koku_db)         │
│   - Infrastructure chart's Trino                        │
│   - cost-onprem's Kafka, Redis, S3                      │
└─────────────────────────────────────────────────────────┘
```

## Target Architecture (Post-Merge)

After this merge, we consolidate to **two charts**:

```
┌─────────────────────────────────────────────────────────┐
│ PHASE 1: cost-onprem-infra (unchanged)     │
│                                                         │
│  PostgreSQL ──┬── koku_db                               │
│               └── metastore_db                          │
│  Trino + Hive Metastore                                 │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│ PHASE 2: cost-onprem (MERGED)                           │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │ Existing Components                             │    │
│  │  PostgreSQL (ros_db, kruize_db, sources_db)     │    │
│  │  ROS, Kruize, Sources API                       │    │
│  │  UI, Ingress, Redis/Valkey, MinIO/ODF           │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │ NEW: Merged from cost-management-onprem         │    │
│  │  Koku API (reads + writes)                      │    │
│  │  Celery Beat + Workers                          │    │
│  │  Masu + Listener                                │    │
│  │  (connects to infra chart's PostgreSQL/Trino)   │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

## Database Architecture

**Important**: This merge does NOT consolidate PostgreSQL instances.

| Component | PostgreSQL Instance | Database | Rationale |
|-----------|---------------------|----------|-----------|
| ROS | cost-onprem | `ros_db` | Existing |
| Kruize | cost-onprem | `kruize_db` | Existing |
| Sources | cost-onprem | `sources_db` | Existing |
| **Koku** | **infrastructure** | `koku_db` | Trino federation requires co-located DB |
| **Hive Metastore** | **infrastructure** | `metastore_db` | Must init before Trino starts |

**Future**: When Trino is removed (PostgreSQL-only migration), Koku will migrate to cost-onprem's unified PostgreSQL.

## Merge Actions

### Templates to Add

| Source (cost-management-onprem) | Destination (cost-onprem) |
|--------------------------------|---------------------------|
| `templates/cost-management/api/*` | `templates/cost-management/api/` |
| `templates/cost-management/celery/*` | `templates/cost-management/celery/` |
| `templates/cost-management/masu/*` | `templates/cost-management/masu/` |
| `templates/cost-management/serviceaccount.yaml` | `templates/cost-management/` |
| `templates/cost-management/monitoring/servicemonitor.yaml` | Append to `templates/monitoring/servicemonitor.yaml` |
| `templates/cost-management/configmap-ca-combine.yaml` | `templates/cost-management/` |
| `templates/cost-management/configmap-service-ca.yaml` | Already exists in `templates/shared/` |
| `templates/_helpers-koku.tpl` | `templates/_helpers-koku.tpl` (rename prefixes) |

### Templates to Skip (Already Covered)

| File | Reason |
|------|--------|
| `templates/sources/*` | cost-onprem has complete Sources API implementation |
| `templates/infrastructure/service-kafka-alias.yaml` | cost-onprem has dynamic version |

### Templates to Delete (Secrets)

| File | Action |
|------|--------|
| `secret-django.yaml` | Move to `install-helm-chart.sh` |
| `secret-sources-credentials.yaml` | Move to `install-helm-chart.sh` |
| `secret-storage-credentials.yaml` | Keep (uses Helm lookup for ODF) |

### Helper Functions

The `_helpers-koku.tpl` file will be copied with the following changes:

| Original Prefix | New Prefix |
|-----------------|------------|
| `cost-mgmt.*` | `cost-onprem.*` |
| `cost-management-onprem.*` | `cost-onprem.*` |

Duplicated helpers (already in cost-onprem's `_helpers.tpl`) will be removed:
- `isOpenShift` → use `cost-onprem.platform.isOpenShift`
- `cache.name` → use `cost-onprem.cache.name`
- `kafkaHost/kafkaPort` → use `cost-onprem.kafka.host/port`

### Values.yaml Changes

Add these sections from cost-management-onprem to cost-onprem:

```yaml
# Cost Management (Koku) Configuration
costManagement:
  api:
    enabled: true
    image: ...
    reads: ...
    writes: ...
  celery:
    beat: ...
    workers: ...
  masu: ...
  listener: ...
  kafka: ...
  database:
    host: "postgres"  # Infrastructure chart's PostgreSQL
    ...

# Trino Configuration (for Koku connection)
trino:
  coordinator:
    host: "trino-coordinator"
    ...

# Mock RBAC Service
mockRbac:
  enabled: true
  ...
```

### Environment Variables

All Koku manifests will include:

```yaml
env:
  - name: KOKU_ONPREM_DEPLOYMENT
    value: "true"
```

This enables the `DisabledUnleashClient` from [PR #5](https://github.com/insights-onprem/koku/pull/5), which:
- Makes zero network calls to Unleash
- Uses fallback functions for feature flags
- Eliminates need for Unleash server in on-prem deployments

**Note**: This is hardcoded (not a values.yaml option) to make it explicit that this chart is for on-prem only.

## Secrets Strategy

Secrets will NOT be generated in Helm templates. Instead, they are created by `install-helm-chart.sh`:

| Secret | Created By |
|--------|------------|
| `cost-onprem-django-secret` | `install-helm-chart.sh` |
| `cost-onprem-sources-credentials` | `install-helm-chart.sh` |
| `cost-onprem-ui-oauth-client` | `install-helm-chart.sh` |
| `cost-onprem-ui-cookie-secret` | `install-helm-chart.sh` |
| `keycloak-ca-cert` | `install-helm-chart.sh` |
| `cost-onprem-storage-credentials` | Helm template (uses `lookup` for ODF) |

## Directory Structure (Post-Merge)

```
cost-onprem/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── _helpers.tpl
│   ├── _helpers-koku.tpl          # NEW (from cost-management-onprem)
│   ├── _helpers-init-containers.tpl
│   ├── _helpers-security.tpl
│   ├── NOTES.txt
│   │
│   ├── cost-management/           # NEW (from cost-management-onprem)
│   │   ├── api/
│   │   │   ├── deployment-reads.yaml
│   │   │   ├── deployment-writes.yaml
│   │   │   ├── service-reads.yaml
│   │   │   ├── service-writes.yaml
│   │   │   └── service.yaml
│   │   ├── celery/
│   │   │   ├── deployment-beat.yaml
│   │   │   └── deployment-worker-*.yaml (17 files)
│   │   ├── masu/
│   │   │   ├── deployment-listener.yaml
│   │   │   ├── deployment.yaml
│   │   │   └── service.yaml
│   │   ├── configmap-ca-combine.yaml
│   │   └── serviceaccount.yaml
│   │
│   ├── auth/                      # Existing
│   ├── infrastructure/            # Existing
│   ├── ingress/                   # Existing
│   ├── kruize/                    # Existing
│   ├── monitoring/                # Existing (ServiceMonitor updated)
│   ├── ros/                       # Existing
│   ├── shared/                    # Existing
│   ├── sources-api/               # Existing
│   └── ui/                        # Existing
```

## Migration Path

### Immediate (This PR)
1. Merge templates from cost-management-onprem
2. Update values.yaml with Koku configuration
3. Hardcode `KOKU_ONPREM_DEPLOYMENT=true`
4. Update install-helm-chart.sh for secrets

### Future (Post Trino Removal)
1. Migrate Koku to cost-onprem's PostgreSQL
2. Add `koku_db` to unified database model
3. Deprecate cost-onprem-infra chart
4. Single chart deployment

## Testing Checklist

- [ ] `helm template` succeeds with no errors
- [ ] All Koku pods start successfully
- [ ] Koku connects to infrastructure chart's PostgreSQL
- [ ] Koku connects to infrastructure chart's Trino
- [ ] Celery workers process tasks
- [ ] Feature flags work via DisabledUnleashClient
- [ ] Secrets created by install-helm-chart.sh
- [ ] No secrets in Helm template output

## Files to Delete After Merge

Once merged and validated, the `cost-management-onprem/` directory can be removed:

```bash
rm -rf cost-management-onprem/
```
