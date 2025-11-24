# Redis High Availability Deployment Guide

## Overview

This guide explains how to deploy Redis in High Availability (HA) mode for Cost Management on-prem deployments. HA Redis ensures reliable Celery chord callbacks and persistent result backend, matching the SaaS architecture.

## Why HA Redis?

### The Problem

In on-prem deployments with single Redis pod:
- ❌ Redis pod restarts lose chord state
- ❌ Celery chord callbacks fail to fire
- ❌ Manifests never complete
- ❌ Summary tables never populate
- ❌ No data in UI

### The Solution

In SaaS with HA Redis cluster:
- ✅ Redis state persists across restarts
- ✅ Celery chord callbacks fire reliably
- ✅ Manifests complete automatically
- ✅ Summary tables populate
- ✅ Data appears in UI

**HA Redis is the SaaS-aligned infrastructure solution - no code changes needed.**

## Architecture

### Sentinel Mode (Recommended for On-Prem)

```
┌─────────────────────────────────────────────────────┐
│                   Redis Sentinel                     │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │  Sentinel 1 │  │  Sentinel 2 │  │  Sentinel 3 │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘ │
│         │                 │                 │        │
│         └─────────────────┴─────────────────┘        │
│                           │                          │
│  ┌────────────────────────┴──────────────────────┐  │
│  │                                                 │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────┤  │
│  │  │   Master    │  │  Replica 1  │  │ Replica │  │
│  │  │  (Primary)  │──│   (Sync)    │──│   (Sync)│  │
│  │  └─────────────┘  └─────────────┘  └─────────┘  │
│  │        │                 │                │      │
│  │        └─────────────────┴────────────────┘      │
│  │                    PVC (Persistent)              │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Features:**
- **Automatic Failover**: Sentinels detect master failure and promote replica
- **3 Sentinels**: Quorum of 2 for failover decisions
- **2 Replicas**: 1 master + 2 replicas = 3 total Redis nodes
- **Persistence**: RDB + AOF on all nodes with PVCs
- **Anti-affinity**: Pods spread across different nodes

## Prerequisites

1. **OpenShift 4.10+** or **Kubernetes 1.21+**
2. **Storage Class** for persistent volumes:
   - ODF/OCS: `ocs-storagecluster-ceph-rbd`
   - NFS: `nfs-client`
   - Other: Adjust `storageClass` in values file
3. **Sufficient Resources**:
   - 3 worker nodes (for anti-affinity)
   - 1.5 CPU cores total (3 Redis pods × 0.5 CPU)
   - 3 GB memory total (3 Redis pods × 1 GB)
   - 30 GB storage total (3 PVCs × 10 GB)

## Deployment

### Step 1: Review Configuration

```bash
cd cost-management-infrastructure
cat values-redis-ha.yaml
```

**Key settings:**
- `architecture: sentinel` - HA mode
- `replica.replicaCount: 2` - Total 3 nodes (1 master + 2 replicas)
- `sentinel.replicaCount: 3` - 3 sentinels for quorum
- `sentinel.quorum: 2` - 2 sentinels must agree for failover
- `persistence.enabled: true` - RDB + AOF persistence
- `persistence.size: 10Gi` - 10GB per PVC

### Step 2: Deploy or Upgrade

**New Deployment:**

```bash
helm install cost-mgmt-infra ./cost-management-infrastructure \
  -f cost-management-infrastructure/values-redis-ha.yaml \
  -n cost-mgmt \
  --create-namespace
```

**Existing Deployment (Upgrade):**

```bash
# IMPORTANT: Upgrading from standalone to sentinel requires careful migration
# See "Migration from Standalone" section below

helm upgrade cost-mgmt-infra ./cost-management-infrastructure \
  -f cost-management-infrastructure/values-redis-ha.yaml \
  -n cost-mgmt
```

### Step 3: Verify Deployment

**Check Pods:**

```bash
kubectl get pods -n cost-mgmt -l app.kubernetes.io/name=redis

# Expected output (sentinel mode):
# redis-node-0           2/2     Running   0     5m  (master + sentinel)
# redis-node-1           2/2     Running   0     5m  (replica + sentinel)
# redis-node-2           2/2     Running   0     5m  (replica + sentinel)
```

**Check PVCs:**

```bash
kubectl get pvc -n cost-mgmt -l app.kubernetes.io/name=redis

# Expected output:
# redis-data-redis-node-0   Bound   10Gi   ocs-storagecluster-ceph-rbd
# redis-data-redis-node-1   Bound   10Gi   ocs-storagecluster-ceph-rbd
# redis-data-redis-node-2   Bound   10Gi   ocs-storagecluster-ceph-rbd
```

**Check Sentinel Status:**

```bash
kubectl exec -n cost-mgmt redis-node-0 -c redis -- \
  redis-cli -p 26379 sentinel masters

# Look for:
# name: mymaster
# status: ok
# num-slaves: 2
# num-other-sentinels: 2
```

**Check Replication Status:**

```bash
kubectl exec -n cost-mgmt redis-node-0 -c redis -- \
  redis-cli info replication

# Look for:
# role:master
# connected_slaves:2
# slave0:ip=...,port=6379,state=online
# slave1:ip=...,port=6379,state=online
```

## Configuration Details

### Persistence Settings

**RDB (Redis Database Snapshot):**
```
save 900 1      # Save if 1 key changed in 15 minutes
save 300 10     # Save if 10 keys changed in 5 minutes
save 60 10000   # Save if 10000 keys changed in 1 minute
```

**AOF (Append-Only File):**
```
appendonly yes         # Enable AOF
appendfsync everysec   # Sync every second (good balance)
```

This combination provides:
- ✅ Fast recovery (RDB snapshots)
- ✅ Minimal data loss (AOF with 1-second sync)
- ✅ Good performance (async AOF sync)

### Memory Management

```
maxmemory 768mb              # 75% of 1GB limit
maxmemory-policy allkeys-lru # Evict least recently used keys
```

**Why 768MB?**
- Container limit: 1GB
- Redis process: ~768MB usable
- System overhead: ~256MB buffer

### Replication Settings

```
min-replicas-to-write 1    # Require 1 replica before accepting writes
min-replicas-max-lag 10    # Replica must be < 10 seconds behind
```

This ensures:
- ✅ Data written to at least 2 nodes (master + 1 replica)
- ✅ Replicas stay synchronized
- ✅ Minimal data loss on failover

## Migration from Standalone

**⚠️ WARNING: This requires downtime and data migration.**

### Option 1: Clean Deployment (Recommended for Testing)

```bash
# 1. Scale down Celery workers
kubectl scale deployment -n cost-mgmt --replicas=0 \
  $(kubectl get deployment -n cost-mgmt -o name | grep celery-worker)

# 2. Delete old Redis
kubectl delete statefulset redis -n cost-mgmt
kubectl delete pvc redis-data-redis-0 -n cost-mgmt

# 3. Deploy HA Redis
helm upgrade cost-mgmt-infra ./cost-management-infrastructure \
  -f cost-management-infrastructure/values-redis-ha.yaml \
  -n cost-mgmt

# 4. Wait for HA Redis to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=redis -n cost-mgmt --timeout=5m

# 5. Scale up Celery workers
kubectl scale deployment -n cost-mgmt --replicas=1 \
  $(kubectl get deployment -n cost-mgmt -o name | grep celery-worker)
```

**Data Loss:** All queued Celery tasks and cached data lost (acceptable for testing).

### Option 2: Live Migration (For Production)

**NOT RECOMMENDED** - Complex and error-prone. Instead:
1. Schedule maintenance window
2. Complete all in-flight processing
3. Use Option 1 (clean deployment)
4. Re-trigger processing after upgrade

## Testing Failover

### Simulate Master Failure

```bash
# 1. Identify current master
kubectl exec -n cost-mgmt redis-node-0 -c redis -- \
  redis-cli info replication | grep role

# 2. Kill master pod (if node-0 is master)
kubectl delete pod redis-node-0 -n cost-mgmt

# 3. Watch sentinels elect new master (takes ~30 seconds)
watch kubectl exec -n cost-mgmt redis-node-1 -c redis -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster

# 4. Verify new master promoted
kubectl exec -n cost-mgmt redis-node-1 -c redis -- \
  redis-cli info replication
```

**Expected Behavior:**
- Sentinels detect failure within 30 seconds
- 2 sentinels (quorum) agree to failover
- One replica promoted to master
- Other replica switches to new master
- Old master rejoins as replica when it restarts

### Verify Celery Continues Working

```bash
# Check Celery workers still connected
kubectl logs -n cost-mgmt deployment/koku-celery-worker-default --tail=50 | grep -i redis

# Trigger a test task
kubectl exec -n cost-mgmt deployment/koku-masu -- \
  python manage.py shell -c "from celery import current_app; current_app.send_task('debug-task')"

# Verify task executed
kubectl logs -n cost-mgmt deployment/koku-celery-worker-default --tail=20 | grep debug-task
```

## Monitoring

### Prometheus Metrics

HA Redis deployment exposes Prometheus metrics:

```yaml
# ServiceMonitor automatically created
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: redis
  namespace: cost-mgmt
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: redis
  endpoints:
  - port: metrics
```

**Key Metrics:**
- `redis_up` - Redis availability
- `redis_master_repl_offset` - Replication lag
- `redis_connected_slaves` - Number of replicas
- `redis_sentinel_masters` - Sentinel health
- `redis_mem_fragmentation_ratio` - Memory efficiency

### Grafana Dashboard

Import the Redis Sentinel dashboard:
- Dashboard ID: 11835 (from grafana.com)
- Or create custom dashboard with key metrics above

### Alerts

Recommended alerts:

```yaml
- alert: RedisDown
  expr: redis_up == 0
  for: 1m
  annotations:
    summary: "Redis instance is down"

- alert: RedisReplicationBroken
  expr: redis_connected_slaves < 2
  for: 5m
  annotations:
    summary: "Redis replication is broken (< 2 replicas)"

- alert: RedisSentinelDown
  expr: redis_sentinel_masters < 1
  for: 1m
  annotations:
    summary: "Sentinel cannot find master"

- alert: RedisHighMemory
  expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
  for: 5m
  annotations:
    summary: "Redis memory usage > 90%"
```

## Troubleshooting

### Sentinel Can't Find Master

**Symptom:**
```
sentinel master mymaster: SDOWN
```

**Diagnosis:**
```bash
kubectl exec -n cost-mgmt redis-node-0 -c sentinel -- \
  redis-cli -p 26379 sentinel masters
```

**Solution:**
```bash
# Reset sentinel and force re-election
kubectl exec -n cost-mgmt redis-node-0 -c sentinel -- \
  redis-cli -p 26379 sentinel reset mymaster
```

### Replication Lag High

**Symptom:**
```
slave0:lag=100
```

**Diagnosis:**
```bash
kubectl exec -n cost-mgmt redis-node-0 -c redis -- \
  redis-cli info replication
```

**Possible Causes:**
- Network issues between pods
- Replica overloaded
- Slow storage I/O

**Solution:**
- Check pod resources and storage performance
- Increase replica resources if needed

### Split Brain (Multiple Masters)

**Symptom:** Multiple nodes think they're master

**Diagnosis:**
```bash
for i in 0 1 2; do
  echo "=== Node $i ==="
  kubectl exec -n cost-mgmt redis-node-$i -c redis -- \
    redis-cli info replication | grep role
done
```

**Solution:**
```bash
# This should NOT happen with quorum=2, but if it does:
# 1. Identify the true master (most recent data)
# 2. Force other nodes to become replicas
kubectl exec -n cost-mgmt redis-node-<REPLICA> -c redis -- \
  redis-cli REPLICAOF redis-node-<MASTER> 6379
```

## Performance Tuning

### For High-Volume Deployments

```yaml
# Increase resources
master:
  resources:
    limits:
      cpu: 1000m
      memory: 2Gi

# Increase persistence size
master:
  persistence:
    size: 20Gi

# Adjust memory policy
master:
  configuration: |-
    maxmemory 1536mb  # 75% of 2GB
    maxmemory-policy allkeys-lru
```

### For Low-Latency Requirements

```yaml
# Use faster storage class
master:
  persistence:
    storageClass: "premium-ssd"

# Adjust AOF sync
master:
  configuration: |-
    appendfsync always  # More durable, slower
    # OR
    appendfsync no      # Faster, less durable
```

## Cost Considerations

**Storage:**
- 3 PVCs × 10GB = 30GB total
- ODF: Replicated 3x = 90GB raw storage
- Monthly cost: ~$5-10 (cloud providers)

**Compute:**
- 3 pods × 0.5 CPU × 1GB RAM
- Monthly cost: ~$30-50 (cloud providers)

**Total:** ~$35-60/month for HA Redis

**Is it worth it?** Absolutely - manual intervention for every stuck manifest costs far more in operations time.

## References

- [Redis Sentinel Documentation](https://redis.io/topics/sentinel)
- [Bitnami Redis Helm Chart](https://github.com/bitnami/charts/tree/master/bitnami/redis)
- [Celery + Redis Best Practices](https://docs.celeryproject.org/en/stable/userguide/configuration.html#redis-backend-settings)

## Summary

HA Redis deployment provides:
- ✅ **Reliability**: Chord callbacks survive pod restarts
- ✅ **Persistence**: Data survives cluster maintenance
- ✅ **Failover**: Automatic master election (<30s downtime)
- ✅ **SaaS Parity**: Same architecture as production
- ✅ **No Code Changes**: Pure infrastructure solution

This is the recommended production configuration for Cost Management on-prem deployments.

