# Trino Resource Profiles

Three resource configurations are available depending on your use case.

## Profile Comparison

| Profile | Use Case | Total Pods | Total RAM | Total CPU | Total Storage |
|---------|----------|------------|-----------|-----------|---------------|
| **Minimal** | Quick testing, CI/CD | 4 | **4-6 GB** | **1.5-2 cores** | 12 GB |
| **Development** | Local development | 4 | **8-10 GB** | **3-4 cores** | 25 GB |
| **Production** | Production workloads | 5+ | 20-24+ GB | 6-8+ cores | 150+ GB |

---

## 1. Minimal Profile (`values-minimal.yaml`)

### Use Cases
- ✅ Quick testing and validation
- ✅ CI/CD pipelines
- ✅ Learning Trino basics
- ✅ Resource-constrained environments (laptops)

### ⚠️ Limitations
- ❌ **Not suitable for production**
- ❌ May fail with large queries
- ❌ Slow query performance
- ❌ Limited concurrent query capacity (1-2 queries max)

### Resource Breakdown

| Component | Pods | CPU Request | Memory Request | CPU Limit | Memory Limit | Storage |
|-----------|------|-------------|----------------|-----------|--------------|---------|
| Coordinator | 1 | 250m | 1Gi | 500m | 2Gi | 5Gi |
| Worker | 1 | 250m | 1Gi | 500m | 2Gi | 5Gi |
| Metastore | 1 | 100m | 256Mi | 250m | 512Mi | - |
| Metastore DB | 1 | 50m | 128Mi | 100m | 256Mi | 2Gi |
| **TOTAL** | **4** | **0.65 cores** | **~2.5 GB** | **1.35 cores** | **~5 GB** | **12 GB** |

### JVM Configuration
- Coordinator Heap: 1GB
- Worker Heap: 1GB

### Installation

```bash
# Using deployment script
TRINO_PROFILE=minimal ./scripts/deploy-trino.sh

# Or using Helm directly
helm install trino ./trino-chart \
  --namespace trino \
  --create-namespace \
  --values ./trino-chart/values-minimal.yaml
```

### Expected Performance
- Query latency: 5-30 seconds (small queries)
- Concurrent queries: 1-2 max
- Data scan: Up to 100MB per query
- Suitable for: Sample data testing

---

## 2. Development Profile (`values-dev.yaml`) ⭐ **RECOMMENDED FOR DEV**

### Use Cases
- ✅ Local development environment
- ✅ Testing Koku integration
- ✅ Feature development
- ✅ Small-scale data testing

### ⚠️ Limitations
- ❌ Not suitable for production
- ⚠️ May struggle with large datasets (> 1GB)
- ⚠️ Limited concurrent queries (2-4)

### Resource Breakdown

| Component | Pods | CPU Request | Memory Request | CPU Limit | Memory Limit | Storage |
|-----------|------|-------------|----------------|-----------|--------------|---------|
| Coordinator | 1 | 500m | 2Gi | 1000m | 3Gi | 10Gi |
| Worker | 1 | 500m | 2Gi | 1000m | 3Gi | 10Gi |
| Metastore | 1 | 250m | 512Mi | 500m | 1Gi | - |
| Metastore DB | 1 | 100m | 256Mi | 250m | 512Mi | 5Gi |
| **TOTAL** | **4** | **1.35 cores** | **~5 GB** | **2.75 cores** | **~8 GB** | **25 GB** |

### JVM Configuration
- Coordinator Heap: 2GB
- Worker Heap: 2GB

### Installation

```bash
# Using deployment script (default for dev)
./scripts/deploy-trino.sh

# Or with explicit profile
TRINO_PROFILE=dev ./scripts/deploy-trino.sh

# Or using Helm directly
helm install trino ./trino-chart \
  --namespace trino \
  --create-namespace \
  --values ./trino-chart/values-dev.yaml
```

### Expected Performance
- Query latency: 2-10 seconds (typical queries)
- Concurrent queries: 2-4
- Data scan: Up to 500MB per query
- Suitable for: Development workflows, small datasets

---

## 3. Production Profile (`values.yaml`) - Default

### Use Cases
- ✅ Production workloads
- ✅ Large datasets (10GB+)
- ✅ Multiple concurrent users
- ✅ Performance-critical applications

### Resource Breakdown

| Component | Pods | CPU Request | Memory Request | CPU Limit | Memory Limit | Storage |
|-----------|------|-------------|----------------|-----------|--------------|---------|
| Coordinator | 1 | 1000m | 6Gi | 2000m | 8Gi | 50Gi |
| Workers | 2 | 2000m | 12Gi | 4000m | 16Gi | 100Gi |
| Metastore | 1 | 500m | 2Gi | 1000m | 4Gi | - |
| Metastore DB | 1 | 250m | 512Mi | 500m | 1Gi | 10Gi |
| **TOTAL** | **5** | **3.75 cores** | **~20 GB** | **7.5 cores** | **~29 GB** | **160 GB** |

### JVM Configuration
- Coordinator Heap: 6GB
- Worker Heap: 6GB (per worker)

### Installation

```bash
# Using deployment script with production profile
TRINO_PROFILE=production ./scripts/deploy-trino.sh

# Or using Helm directly (default values)
helm install trino ./trino-chart \
  --namespace trino \
  --create-namespace
```

### Expected Performance
- Query latency: < 5 seconds (typical queries)
- Concurrent queries: 10-20
- Data scan: Up to 10GB per query
- Suitable for: Production workloads, large datasets

### Scaling Production

Add more workers:
```bash
helm upgrade trino ./trino-chart \
  --namespace trino \
  --set worker.replicas=4
```

Increase memory:
```bash
helm upgrade trino ./trino-chart \
  --namespace trino \
  --set worker.jvm.maxHeapSize=8G \
  --set worker.resources.limits.memory=10Gi
```

---

## Profile Selection Guide

### Decision Tree

```
What's your use case?
│
├─ Just testing Trino basics?
│  └─ Use: Minimal (4-6 GB RAM)
│
├─ Developing locally with Koku?
│  └─ Use: Development (8-10 GB RAM) ⭐
│
├─ CI/CD pipeline?
│  └─ Use: Minimal (4-6 GB RAM)
│
└─ Production deployment?
   └─ Use: Production (20+ GB RAM)
```

### By Available Resources

| Available RAM | Recommended Profile | Notes |
|---------------|---------------------|-------|
| < 8 GB | Minimal | Basic testing only |
| 8-16 GB | Development | Good for local dev |
| 16-32 GB | Production (2 workers) | Small production |
| 32+ GB | Production (4+ workers) | Full production |

### By Query Volume

| Queries/Hour | Data Size | Profile | Workers |
|--------------|-----------|---------|---------|
| < 10 | < 100MB | Minimal | 1 |
| 10-100 | < 1GB | Development | 1 |
| 100-1000 | < 10GB | Production | 2-4 |
| 1000+ | 10GB+ | Production | 4-8+ |

---

## Switching Profiles

### Upgrade from Minimal to Development

```bash
helm upgrade trino ./trino-chart \
  --namespace trino \
  --values ./trino-chart/values-dev.yaml \
  --reuse-values=false
```

### Upgrade from Development to Production

```bash
helm upgrade trino ./trino-chart \
  --namespace trino \
  --reuse-values=false
```

### Downgrade (with caution)

```bash
# This may cause pod evictions if memory is reduced
helm upgrade trino ./trino-chart \
  --namespace trino \
  --values ./trino-chart/values-minimal.yaml \
  --reuse-values=false
```

---

## Resource Requirements by Koku Usage

### Koku Development (Recommended: Development Profile)

**Scenario**: Local Koku development with sample data
- Workers processing: 10-50 cost uploads/day
- Query volume: Low
- Data size: < 500MB

**Profile**: Development
- Resources: 8-10 GB RAM, 3-4 CPU
- Worker count: 1
- Performance: Adequate

---

### Koku Testing (Recommended: Development Profile)

**Scenario**: Integration testing, CI/CD pipelines
- Workers processing: 100-500 cost uploads/day
- Query volume: Medium
- Data size: < 2GB

**Profile**: Development
- Resources: 8-10 GB RAM, 3-4 CPU
- Worker count: 1-2
- Performance: Good for testing

---

### Koku Production - Small (Recommended: Production Profile)

**Scenario**: Small deployment (< 100 clusters)
- Workers processing: 1000-5000 cost uploads/day
- Query volume: High
- Data size: 5-20GB

**Profile**: Production (2 workers)
- Resources: 20-24 GB RAM, 6-8 CPU
- Worker count: 2
- Performance: Good

---

### Koku Production - Large (Recommended: Production Profile)

**Scenario**: Large deployment (100+ clusters)
- Workers processing: 5000+ cost uploads/day
- Query volume: Very high
- Data size: 20GB+

**Profile**: Production (4-8 workers)
- Resources: 40-60 GB RAM, 12-18 CPU
- Worker count: 4-8
- Performance: Excellent

---

## Cost Estimates (AWS)

### Minimal Profile
- **On-prem/KIND**: Free (laptop resources)
- **AWS EKS**: ~$100/month (t3.medium nodes)

### Development Profile
- **On-prem/KIND**: Free (workstation resources)
- **AWS EKS**: ~$200/month (t3.large nodes)

### Production Profile (2 workers)
- **AWS EKS**: ~$400-600/month (m5.xlarge nodes)
- **AWS Athena**: $50-500/month (pay per query)

### Production Profile (4 workers)
- **AWS EKS**: ~$800-1200/month (m5.xlarge nodes)
- **AWS Athena**: $500-2000/month (pay per query)

---

## Performance Benchmarks

### Query Performance (SELECT on 1M rows)

| Profile | Simple Query | Aggregation | JOIN | Complex Analytics |
|---------|-------------|-------------|------|-------------------|
| Minimal | 10-30s | 30-60s | 60-120s | May fail |
| Development | 5-15s | 15-30s | 30-60s | 60-300s |
| Production (2w) | 2-5s | 5-10s | 10-20s | 20-60s |
| Production (4w) | 1-3s | 3-6s | 6-12s | 12-30s |

---

## Troubleshooting by Profile

### Minimal Profile Issues

**Symptom**: OutOfMemoryError
```
Solution: Upgrade to Development profile
```

**Symptom**: Query timeout
```
Solution: Reduce query complexity or upgrade profile
```

### Development Profile Issues

**Symptom**: Slow queries
```
Solution:
1. Optimize query (add partition filters)
2. Upgrade to Production profile
3. Add more workers
```

**Symptom**: Coordinator OOM
```
Solution: Increase coordinator heap or upgrade profile
```

### Production Profile Issues

**Symptom**: Still slow
```
Solution:
1. Add more workers
2. Increase worker memory
3. Optimize data partitioning
```

---

## Recommendations

### For Koku ClowdApp → Helm Migration Validation ⭐ **YOUR USE CASE**

**Goal**: Validate that Koku works with Helm-deployed Trino (not performance testing)

**Recommended**: Minimal Profile (values-minimal.yaml)
- ✅ **Lowest resource requirements** (4-6 GB RAM, 12 GB storage)
- ✅ Fast deployment and iteration
- ✅ Sufficient to validate functional correctness
- ✅ Easy to test on laptops or small clusters
- ⚠️ Not for performance testing (but that's not your goal)

```bash
TRINO_PROFILE=minimal ./scripts/deploy-trino.sh
```

**Validation Checklist**:
1. ✅ Trino pods start successfully
2. ✅ Koku workers can connect to Trino
3. ✅ Koku can query Parquet files from S3/MinIO
4. ✅ Cost data processing completes (doesn't need to be fast)
5. ✅ No connection errors in Koku logs

**Alternative for Even Faster Validation**: Consider **DuckDB**
- Only 1-2 GB RAM (vs 4-6 GB for Trino)
- Much faster to deploy and test
- See `docs/trino-alternatives-analysis.md` for details

---

### For Koku Feature Development

**Start with**: Development Profile (values-dev.yaml)
- ✅ Adequate for Koku development
- ✅ Reasonable resource usage (8-10 GB)
- ✅ Good development experience
- ✅ Can handle typical test data

```bash
./scripts/deploy-trino.sh  # Uses dev profile by default
```

### For CI/CD Pipelines

**Use**: Minimal Profile (values-minimal.yaml)
- ✅ Fast deployment
- ✅ Minimal resource usage
- ✅ Sufficient for automated tests

```bash
TRINO_PROFILE=minimal ./scripts/deploy-trino.sh
```

### For Production

**Start with**: Production Profile with 2 workers
- ✅ Monitor usage for 1-2 weeks
- ✅ Scale workers based on actual load
- ✅ Consider Athena if on AWS

---

## Summary Table

| Aspect | Minimal ⭐ | Development | Production |
|--------|------------|-------------|------------|
| **RAM** | **4-6 GB** | 8-10 GB | 20+ GB |
| **CPU** | **1.5-2 cores** | 3-4 cores | 6+ cores |
| **Workers** | 1 | 1 | 2-8 |
| **Storage** | **12 GB** | 25 GB | 150+ GB |
| **Use Case** | **Migration validation** | Dev & testing | Production |
| **Query Latency** | 10-30s | 5-15s | 2-5s |
| **Data Size** | < 100MB | < 1GB | 10+ GB |
| **Cost (AWS)** | $100/mo | $200/mo | $400+/mo |

**⭐ Recommended for Koku ClowdApp → Helm migration validation**: Minimal Profile
**Recommended for Koku feature development**: Development Profile

---

**Document Version**: 1.0
**Last Updated**: November 6, 2025
**Default Profile**: Development (for local/testing)

