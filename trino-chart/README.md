# Trino Helm Chart

Helm chart for deploying Trino distributed SQL query engine for Koku cost management.

## Overview

This chart deploys a minimal Trino cluster consisting of:
- **Trino Coordinator** (1 pod) - Query planning and orchestration
- **Trino Workers** (2+ pods) - Query execution
- **Hive Metastore** (1 pod) - Metadata storage for Trino catalogs
- **PostgreSQL** (1 pod) - Database for Hive Metastore

## Why Trino?

Trino is **required** by Koku for querying cost data stored in Parquet format on S3/MinIO.
Koku's Celery workers use Trino to:
- Read raw cost data from object storage
- Process and transform data
- Load into PostgreSQL for API serving

**Trino is NOT optional** - all Koku workers require `TRINO_HOST` and `TRINO_PORT` environment variables.

## Prerequisites

- Kubernetes 1.21+ or OpenShift 4.10+
- Helm 3.0+
- S3-compatible object storage (MinIO or ODF)
- 20-24GB RAM available
- 6+ CPU cores available
- 150+ GB storage

## Quick Start

### Using Deployment Script (Recommended)

```bash
# Deploy with defaults
./scripts/deploy-trino.sh

# Custom configuration
TRINO_WORKER_REPLICAS=4 \
TRINO_WORKER_MEMORY=8Gi \
./scripts/deploy-trino.sh

# Validate deployment
./scripts/deploy-trino.sh validate

# Check status
./scripts/deploy-trino.sh status

# Cleanup
./scripts/deploy-trino.sh cleanup
```

### Using Helm Directly

```bash
# Install
helm install trino ./trino-chart \
  --namespace trino \
  --create-namespace

# Upgrade
helm upgrade trino ./trino-chart \
  --namespace trino

# Uninstall
helm uninstall trino --namespace trino
```

## Configuration

### Key Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `coordinator.replicas` | Number of coordinator pods (always 1) | `1` |
| `coordinator.resources.requests.memory` | Coordinator memory request | `6Gi` |
| `coordinator.resources.limits.memory` | Coordinator memory limit | `8Gi` |
| `worker.replicas` | Number of worker pods | `2` |
| `worker.resources.requests.memory` | Worker memory request | `6Gi` |
| `worker.resources.limits.memory` | Worker memory limit | `8Gi` |
| `metastore.enabled` | Deploy Hive Metastore | `true` |
| `catalogs.hive.enabled` | Enable Hive catalog | `true` |
| `catalogs.hive.s3.endpoint` | S3 endpoint URL | auto-detected |
| `catalogs.hive.s3.accessKey` | S3 access key | `minioaccesskey` |
| `catalogs.hive.s3.secretKey` | S3 secret key | `miniosecretkey` |

### Example: Custom Resources

```yaml
# custom-values.yaml
coordinator:
  resources:
    requests:
      memory: 8Gi
      cpu: 2000m
    limits:
      memory: 12Gi
      cpu: 4000m

worker:
  replicas: 4
  resources:
    requests:
      memory: 8Gi
      cpu: 2000m
    limits:
      memory: 12Gi
      cpu: 4000m
```

```bash
helm install trino ./trino-chart \
  --namespace trino \
  --values custom-values.yaml
```

## Resource Requirements

### Minimal (Testing)
- **Coordinator**: 1 pod, 6-8GB RAM, 1-2 CPU
- **Workers**: 2 pods, 12-16GB RAM, 2-4 CPU
- **Metastore**: 1 pod, 2GB RAM, 0.5 CPU
- **Metastore DB**: 1 pod, 0.5GB RAM, 0.25 CPU
- **Total**: 5 pods, 20-24GB RAM, 6-8 CPU

### Production
- **Coordinator**: 1 pod, 12-16GB RAM, 4 CPU
- **Workers**: 4-8 pods, 32-64GB RAM, 8-16 CPU
- **Metastore**: 1 pod, 4GB RAM, 1 CPU
- **Metastore DB**: 1 pod, 1GB RAM, 0.5 CPU
- **Total**: 7-11 pods, 49-85GB RAM, 13.5-21.5 CPU

## Connecting from Koku

Once Trino is deployed, configure Koku services with:

```yaml
# In ros-ocp chart values.yaml or Koku deployment
koku:
  env:
    - name: TRINO_HOST
      value: "trino-coordinator.trino.svc.cluster.local"
    - name: TRINO_PORT
      value: "8080"
```

Or use environment variables:

```bash
export TRINO_HOST=trino-coordinator.trino.svc.cluster.local
export TRINO_PORT=8080
```

## Testing Trino

### From Inside Cluster

```bash
# Get coordinator pod
COORDINATOR_POD=$(kubectl get pods -n trino \
  -l app.kubernetes.io/component=coordinator \
  -o jsonpath='{.items[0].metadata.name}')

# Run test query
kubectl exec -n trino $COORDINATOR_POD -- \
  trino --execute "SHOW CATALOGS"

# Expected output:
# hive
# system
```

### From Koku Pod

```bash
# Get Koku API pod
KOKU_POD=$(kubectl get pods -n ros-ocp \
  -l app.kubernetes.io/name=koku-api-reads \
  -o jsonpath='{.items[0].metadata.name}')

# Test Trino connectivity
kubectl exec -n ros-ocp $KOKU_POD -- \
  curl -s http://trino-coordinator.trino.svc.cluster.local:8080/v1/info

# Should return JSON with Trino version info
```

## Architecture

```
┌─────────────────────────────────────────┐
│  Trino Cluster (trino namespace)        │
│                                          │
│  ┌────────────────────────────────┐    │
│  │  Trino Coordinator             │    │
│  │  - Query planning              │    │
│  │  - Task scheduling             │    │
│  │  Port: 8080                    │    │
│  └────────────┬───────────────────┘    │
│               │                         │
│  ┌────────────▼───────────────────┐    │
│  │  Trino Workers (2-8 pods)      │    │
│  │  - Query execution             │    │
│  │  - Data processing             │    │
│  └────────────┬───────────────────┘    │
│               │                         │
│  ┌────────────▼───────────────────┐    │
│  │  Hive Metastore                │    │
│  │  - Table schemas               │    │
│  │  - Partition metadata          │    │
│  │  Port: 9083                    │    │
│  └────────────┬───────────────────┘    │
│               │                         │
│  ┌────────────▼───────────────────┐    │
│  │  PostgreSQL (Metastore DB)     │    │
│  │  - Metadata storage            │    │
│  └────────────────────────────────┘    │
└──────────────┬──────────────────────────┘
               │
               ├──> S3/MinIO (data files)
               └──> Koku Workers (query data)
```

## Scaling

### Horizontal Scaling

Add more workers:

```bash
helm upgrade trino ./trino-chart \
  --namespace trino \
  --set worker.replicas=4
```

### Vertical Scaling

Increase memory:

```bash
helm upgrade trino ./trino-chart \
  --namespace trino \
  --set worker.resources.requests.memory=8Gi \
  --set worker.resources.limits.memory=10Gi
```

### Auto-Scaling (Optional)

Enable HPA:

```yaml
worker:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70
```

## Monitoring

### Check Pod Status

```bash
kubectl get pods -n trino
```

### Check Logs

```bash
# Coordinator logs
kubectl logs -n trino -l app.kubernetes.io/component=coordinator

# Worker logs
kubectl logs -n trino -l app.kubernetes.io/component=worker

# Metastore logs
kubectl logs -n trino -l app.kubernetes.io/component=metastore
```

### Trino Web UI

Port-forward to access Trino UI:

```bash
kubectl port-forward -n trino svc/trino-coordinator 8080:8080
```

Then open: http://localhost:8080

## Troubleshooting

### Coordinator Won't Start

Check logs:
```bash
kubectl logs -n trino -l app.kubernetes.io/component=coordinator
```

Common issues:
- Out of memory (increase JVM heap)
- Cannot connect to Metastore
- Configuration errors

### Workers Not Connecting

Check coordinator logs for worker registration:
```bash
kubectl logs -n trino -l app.kubernetes.io/component=coordinator | grep -i worker
```

### Metastore Errors

Check metastore logs:
```bash
kubectl logs -n trino -l app.kubernetes.io/component=metastore
```

Check database connectivity:
```bash
kubectl exec -n trino <metastore-pod> -- \
  nc -zv trino-metastore-db 5432
```

### Query Failures

Check catalog configuration:
```bash
COORDINATOR_POD=$(kubectl get pods -n trino \
  -l app.kubernetes.io/component=coordinator \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n trino $COORDINATOR_POD -- \
  cat /etc/trino/catalog/hive.properties
```

## Upgrading

### Chart Version Upgrade

```bash
# Pull latest chart
git pull origin main

# Upgrade release
helm upgrade trino ./trino-chart \
  --namespace trino
```

### Trino Version Upgrade

```bash
helm upgrade trino ./trino-chart \
  --namespace trino \
  --set coordinator.image.tag=436 \
  --set worker.image.tag=436
```

## Uninstall

### Keep Data

```bash
helm uninstall trino --namespace trino
# PVCs remain for future use
```

### Complete Removal

```bash
# Uninstall release
helm uninstall trino --namespace trino

# Delete PVCs
kubectl delete pvc -n trino --all

# Delete namespace
kubectl delete namespace trino
```

## References

- [Trino Documentation](https://trino.io/docs/current/)
- [Trino GitHub](https://github.com/trinodb/trino)
- [Hive Metastore](https://cwiki.apache.org/confluence/display/hive/design)
- [Koku Repository](https://github.com/project-koku/koku)

## Support

For issues or questions:
- GitHub Issues: https://github.com/insights-onprem/ros-helm-chart/issues
- Trino Slack: https://trinodb.io/slack

