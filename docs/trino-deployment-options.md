# Trino Deployment Options for Koku Helm Migration

**Date**: November 6, 2025
**Context**: Current Koku production uses AWS-managed Trino (not self-hosted)

## Current Production Architecture

### Why Trino Isn't in ClowdApp Manifest

**Current Setup**:
```
Koku in AWS (ClowdApp)
├── Koku API pods
├── Celery Worker pods
│   └── TRINO_HOST=<aws-athena-endpoint>
│   └── TRINO_PORT=443
├── PostgreSQL (RDS)
└── S3 buckets
    └── Queried via AWS Athena/EMR (managed Trino)
```

**Why no Trino deployment in ClowdApp**:
- ✅ Using **Amazon Athena** (serverless Trino) OR
- ✅ Using **Amazon EMR** (managed Trino cluster)
- ✅ AWS manages infrastructure, scaling, updates
- ✅ No need to deploy Trino pods in ClowdApp

**Environment Variables Point to AWS Service**:
```yaml
env:
  - name: TRINO_HOST
    value: "athena.us-east-1.amazonaws.com"  # or EMR endpoint
  - name: TRINO_PORT
    value: "443"
```

---

## Options for Helm Chart Deployment

### Decision Matrix

| Deployment Scenario | Trino Option | Pros | Cons |
|---------------------|--------------|------|------|
| **AWS Deployment** | Amazon Athena | No infra, serverless, AWS-managed | AWS-only, $5/TB scanned, vendor lock-in |
| **AWS Deployment** | Amazon EMR | Managed, optimized for AWS | AWS-only, higher cost than Athena |
| **On-Premises** | Self-hosted Trino | Full control, no vendor lock-in | High resources, operational overhead |
| **OpenShift on AWS** | Hybrid (self-hosted or Athena) | Flexibility | Must choose and configure |
| **Non-AWS Cloud** | Self-hosted Trino | Cloud-agnostic | High resources required |

---

## Option 1: Amazon Athena (AWS-Managed) ⭐ **RECOMMENDED FOR AWS**

### What is Athena?

**Amazon Athena** is a serverless query service that uses Trino (formerly Presto) under the hood.

### Architecture

```
Koku Helm Chart (on AWS/EKS)
├── Koku API pods
├── Celery Worker pods
│   └── TRINO_HOST=athena.us-east-1.amazonaws.com
│   └── TRINO_PORT=443
├── PostgreSQL (RDS or in-cluster)
└── S3 buckets
    └── Queried via Amazon Athena (serverless Trino)
```

### Pros

✅ **Zero infrastructure** - No Trino pods to manage
✅ **Serverless** - Auto-scales, no capacity planning
✅ **AWS-optimized** - 2.7x faster than open-source Trino
✅ **Cost-effective for low/medium usage** - Pay per query
✅ **No operational overhead** - AWS manages everything
✅ **Same SQL interface** - Uses Trino engine

### Cons

❌ **AWS-only** - Cannot use on-prem or other clouds
❌ **Cost can be high** - $5 per TB scanned
❌ **Vendor lock-in** - Tied to AWS
❌ **Network latency** - If pods in different region

### Configuration

**values.yaml**:
```yaml
trino:
  enabled: false  # Don't deploy Trino pods
  external: true  # Use external Trino service
  host: "athena.us-east-1.amazonaws.com"
  port: 443
  catalog: "awsdatacatalog"
  schema: "default"

# Koku workers will use external Trino
koku:
  env:
    trinoHost: "athena.us-east-1.amazonaws.com"
    trinoPort: "443"
```

**Required AWS Resources**:
- S3 buckets for data storage
- AWS Glue Data Catalog (for table metadata)
- IAM roles for Athena access

### Cost Estimate

**Low Usage** (10 TB/month scanned):
- Athena: $50/month
- S3 storage: $230/month (10TB)
- **Total**: ~$280/month

**Medium Usage** (100 TB/month scanned):
- Athena: $500/month
- S3 storage: $2,300/month (100TB)
- **Total**: ~$2,800/month

**High Usage** (500 TB/month scanned):
- Athena: $2,500/month
- S3 storage: $11,500/month (500TB)
- **Total**: ~$14,000/month

### When to Use Athena

Use Athena if:
- ✅ Deploying on AWS (EKS)
- ✅ Data is in S3
- ✅ Query volume is low-medium (< 100 TB/month)
- ✅ Team prefers managed services
- ✅ Want zero operational overhead

---

## Option 2: Amazon EMR (AWS-Managed Trino Cluster)

### What is EMR?

**Amazon EMR** (Elastic MapReduce) provides managed Trino clusters on EC2 instances.

### Architecture

```
Koku Helm Chart (on AWS/EKS)
├── Koku API pods
├── Celery Worker pods
│   └── TRINO_HOST=<emr-master-node>.amazonaws.com
│   └── TRINO_PORT=8080
├── PostgreSQL
└── S3 buckets
    └── Queried via EMR Trino cluster
        ├── Master node (coordinator)
        └── Core nodes (workers)
```

### Pros

✅ **Managed infrastructure** - AWS handles provisioning
✅ **Optimized performance** - 2.7x faster than open-source
✅ **Flexible sizing** - Choose instance types
✅ **Lower per-query cost** - Flat EC2 pricing
✅ **AWS-integrated** - Works with Glue, S3, IAM

### Cons

❌ **AWS-only** - Cannot use elsewhere
❌ **Always-on cost** - Pay for EC2 even when idle
❌ **Some operational overhead** - Cluster management
❌ **Vendor lock-in** - Tied to AWS

### Configuration

**values.yaml**:
```yaml
trino:
  enabled: false  # Don't deploy Trino pods
  external: true
  host: "emr-master-1234567890.us-east-1.amazonaws.com"
  port: 8080
  catalog: "hive"
  schema: "default"
```

**Required AWS Resources**:
- EMR cluster (1 master + 2+ core nodes)
- S3 buckets
- AWS Glue or Hive Metastore
- VPC peering (if EKS and EMR in different VPCs)

### Cost Estimate

**Small EMR Cluster**:
- 1x m5.xlarge master: $140/month
- 2x m5.xlarge workers: $280/month
- EMR fees (30%): $126/month
- S3 storage: $230/month (10TB)
- **Total**: ~$776/month

**Medium EMR Cluster**:
- 1x m5.2xlarge master: $280/month
- 4x m5.2xlarge workers: $1,120/month
- EMR fees (30%): $420/month
- S3 storage: $2,300/month (100TB)
- **Total**: ~$4,120/month

### When to Use EMR

Use EMR if:
- ✅ Deploying on AWS (EKS)
- ✅ High query volume (> 100 TB/month scanned)
- ✅ Need predictable costs
- ✅ Want better performance than Athena
- ✅ Prefer managed service over self-hosted

---

## Option 3: Self-Hosted Trino (Open Source) ⭐ **REQUIRED FOR NON-AWS**

### Architecture

```
Koku Helm Chart (anywhere)
├── Trino Infrastructure (in Helm chart)
│   ├── Hive Metastore (1 pod, 2GB)
│   ├── Trino Coordinator (1 pod, 6-8GB)
│   └── Trino Workers (2+ pods, 6-8GB each)
├── Koku API pods
│   └── TRINO_HOST=<helm-release>-trino-coordinator
│   └── TRINO_PORT=8080
├── Celery Worker pods
├── PostgreSQL
└── MinIO/ODF (object storage)
    └── Queried via self-hosted Trino
```

### Pros

✅ **Cloud-agnostic** - Works anywhere (AWS, GCP, Azure, on-prem)
✅ **Full control** - Complete configurability
✅ **No vendor lock-in** - Open source Apache 2.0
✅ **Predictable costs** - Only infrastructure costs
✅ **No per-query charges** - Flat infrastructure cost

### Cons

❌ **High resource requirements** - 18-24GB RAM minimum
❌ **Operational overhead** - Must manage, monitor, scale
❌ **Complex deployment** - Multiple components
❌ **Performance tuning required** - Java heap, GC, etc.
❌ **HA complexity** - Coordinator is single point of failure

### Components Required

**Mandatory**:
1. **Hive Metastore** (1 pod)
   - Stores table schemas and metadata
   - Connects to PostgreSQL
   - 2GB RAM, 0.5 CPU

2. **Trino Coordinator** (1 pod)
   - Query planning and orchestration
   - Single point of failure (scale with HA later)
   - 6-8GB RAM, 2 CPU

3. **Trino Workers** (2+ pods)
   - Query execution
   - Horizontally scalable
   - 6-8GB RAM per pod, 2 CPU per pod

### Configuration

**values.yaml**:
```yaml
trino:
  enabled: true  # Deploy Trino in Helm chart

  coordinator:
    replicas: 1
    resources:
      requests:
        memory: 6Gi
        cpu: 1000m
      limits:
        memory: 8Gi
        cpu: 2000m

  worker:
    replicas: 2
    resources:
      requests:
        memory: 6Gi
        cpu: 1000m
      limits:
        memory: 8Gi
        cpu: 2000m

  metastore:
    enabled: true
    resources:
      requests:
        memory: 2Gi
        cpu: 500m
      limits:
        memory: 4Gi
        cpu: 1000m

# Koku workers will use in-cluster Trino
koku:
  env:
    trinoHost: "{{ .Release.Name }}-trino-coordinator"
    trinoPort: "8080"
```

### Resource Requirements

**Minimal** (testing):
- Pods: 4 (1 metastore + 1 coordinator + 2 workers)
- CPU: 6 cores
- Memory: 20-24 GB
- Storage: 150 GB

**Production**:
- Pods: 10 (1 metastore + 1 coordinator + 8 workers)
- CPU: 18 cores
- Memory: 60-72 GB
- Storage: 400 GB

### Cost Estimate (Self-Hosted on AWS EC2)

**Small Cluster** (4 pods):
- Infrastructure: $400/month (EC2/EKS)
- Storage: $230/month (10TB S3)
- **Total**: ~$630/month

**Medium Cluster** (6 pods):
- Infrastructure: $800/month
- Storage: $2,300/month (100TB S3)
- **Total**: ~$3,100/month

**Large Cluster** (10 pods):
- Infrastructure: $1,400/month
- Storage: $11,500/month (500TB S3)
- **Total**: ~$12,900/month

### When to Use Self-Hosted

Use self-hosted if:
- ✅ Deploying on-premises
- ✅ Deploying on non-AWS cloud (GCP, Azure)
- ✅ Need full control and customization
- ✅ Have operational expertise
- ✅ Want to avoid vendor lock-in
- ✅ High query volume (cheaper than Athena at scale)

---

## Recommendation by Deployment Scenario

### Scenario 1: AWS EKS Deployment (Cloud-Native)

**Recommendation**: Amazon Athena ⭐

**Why**:
- Zero infrastructure to manage
- Cost-effective for low-medium usage
- AWS-optimized performance
- Matches current production architecture

**Configuration**:
```yaml
trino:
  enabled: false
  external: true
  host: "athena.us-east-1.amazonaws.com"
  port: 443
```

**When to switch to EMR**: If query volume exceeds 100 TB/month

---

### Scenario 2: AWS EKS with High Query Volume

**Recommendation**: Amazon EMR

**Why**:
- Better performance than Athena
- Predictable flat costs
- Still AWS-managed

**Configuration**:
```yaml
trino:
  enabled: false
  external: true
  host: "<emr-master>.amazonaws.com"
  port: 8080
```

---

### Scenario 3: OpenShift on AWS (Hybrid)

**Recommendation**: Amazon Athena OR Self-Hosted (choose one)

**Why**:
- Athena: If prefer AWS-managed, low query volume
- Self-hosted: If need on-cluster Trino, predictable costs

**Configuration** (Athena):
```yaml
trino:
  enabled: false
  external: true
  host: "athena.us-east-1.amazonaws.com"
```

**Configuration** (Self-hosted):
```yaml
trino:
  enabled: true
  coordinator:
    replicas: 1
  worker:
    replicas: 2
```

---

### Scenario 4: On-Premises or Non-AWS Cloud

**Recommendation**: Self-Hosted Trino ✅ **REQUIRED**

**Why**:
- Only option for non-AWS environments
- Full control and customization
- Works with MinIO/ODF

**Configuration**:
```yaml
trino:
  enabled: true
  coordinator:
    replicas: 1
  worker:
    replicas: 2

# Must also deploy Hive Metastore
trino:
  metastore:
    enabled: true
```

---

## Helm Chart Implementation Strategy

### Support All Three Options

**Make Trino deployment optional and configurable**:

```yaml
# values.yaml
trino:
  # Option 1: Deploy self-hosted Trino
  enabled: true  # Set to true for self-hosted

  # Option 2: Use external Trino (Athena/EMR)
  external:
    enabled: false  # Set to true for external
    host: "athena.us-east-1.amazonaws.com"
    port: 443
    catalog: "awsdatacatalog"

  # Coordinator configuration (if enabled=true)
  coordinator:
    replicas: 1
    resources:
      requests:
        memory: 6Gi
        cpu: 1000m
      limits:
        memory: 8Gi
        cpu: 2000m

  # Worker configuration (if enabled=true)
  worker:
    replicas: 2
    resources:
      requests:
        memory: 6Gi
        cpu: 1000m
      limits:
        memory: 8Gi
        cpu: 2000m

  # Hive Metastore (if enabled=true)
  metastore:
    enabled: true
    resources:
      requests:
        memory: 2Gi
        cpu: 500m
```

### Helm Template Logic

```yaml
{{- if .Values.trino.enabled }}
# Deploy Hive Metastore
# Deploy Trino Coordinator
# Deploy Trino Workers
# Set TRINO_HOST to in-cluster service
{{- else if .Values.trino.external.enabled }}
# Don't deploy Trino
# Set TRINO_HOST to external endpoint
{{- else }}
{{- fail "Either trino.enabled or trino.external.enabled must be true" }}
{{- end }}
```

### Environment Variable Configuration

```yaml
# In Koku API/Worker deployments
env:
  - name: TRINO_HOST
    value: {{ if .Values.trino.enabled }}
             {{ include "ros-ocp.fullname" . }}-trino-coordinator
           {{ else }}
             {{ .Values.trino.external.host }}
           {{ end }}
  - name: TRINO_PORT
    value: {{ if .Values.trino.enabled }}"8080"{{ else }}"{{ .Values.trino.external.port }}"{{ end }}
```

---

## Migration Path for Each Option

### Path 1: AWS with Athena

**Setup Steps**:
1. Create S3 buckets for cost data
2. Set up AWS Glue Data Catalog
3. Configure IAM roles for Athena access
4. Deploy Helm chart with:
   ```yaml
   trino:
     enabled: false
     external:
       enabled: true
       host: "athena.us-east-1.amazonaws.com"
   ```
5. Test Athena connectivity from pods
6. Deploy Koku API/workers

**Validation**:
```bash
# From Koku pod
curl -X POST http://koku-api:8000/api/cost-management/v1/trino_query/ \
  -d '{"query": "SHOW CATALOGS", "schema": "default"}'
```

---

### Path 2: Self-Hosted on Kubernetes/OpenShift

**Setup Steps**:
1. Deploy Hive Metastore
2. Deploy Trino Coordinator
3. Deploy Trino Workers
4. Configure S3/MinIO catalog
5. Test Trino queries
6. Deploy Koku with:
   ```yaml
   trino:
     enabled: true
     coordinator:
       replicas: 1
     worker:
       replicas: 2
   ```
7. Deploy Koku API/workers

**Validation**:
```bash
# Test Trino directly
kubectl exec -it trino-coordinator -- trino --execute "SHOW CATALOGS"

# Test from Koku
curl -X POST http://koku-api:8000/api/cost-management/v1/trino_query/ \
  -d '{"query": "SHOW CATALOGS", "schema": "default"}'
```

---

## Decision Framework

### Questions to Answer

1. **Where are you deploying?**
   - AWS → Consider Athena or EMR
   - On-prem → Self-hosted required
   - Other cloud → Self-hosted required

2. **What is your expected query volume?**
   - Low (< 10 TB/month) → Athena
   - Medium (10-100 TB/month) → Athena or self-hosted
   - High (> 100 TB/month) → EMR or self-hosted

3. **Do you have Kubernetes operational expertise?**
   - Yes → Self-hosted is viable
   - No → Prefer managed (Athena/EMR)

4. **What is your budget?**
   - Variable/pay-per-query okay → Athena
   - Prefer predictable costs → Self-hosted or EMR

5. **Do you need vendor lock-in avoidance?**
   - Yes → Self-hosted
   - No → Athena/EMR fine

### Decision Tree

```
Where deploying?
├─ AWS
│  ├─ Query volume?
│  │  ├─ Low → Athena ⭐
│  │  ├─ Medium → Athena or EMR
│  │  └─ High → EMR or Self-hosted
│  └─ Prefer managed? → Yes → Athena/EMR
│                      → No → Self-hosted
│
└─ Not AWS
   └─ Self-hosted ✅ (only option)
```

---

## Summary

| Option | Best For | Pros | Cons | Cost (est.) |
|--------|----------|------|------|-------------|
| **Amazon Athena** | AWS, low-medium usage | Serverless, zero ops | AWS-only, $5/TB | $50-500/month |
| **Amazon EMR** | AWS, high usage | Managed, predictable cost | AWS-only, always-on | $800-4000/month |
| **Self-Hosted** | On-prem, non-AWS, control | Cloud-agnostic, no lock-in | High resources, ops overhead | $600-3000/month |

---

## Recommended Helm Chart Approach

### Default Configuration (Self-Hosted)

```yaml
# values.yaml (default for on-prem/non-AWS)
trino:
  enabled: true  # Deploy Trino by default
  external:
    enabled: false
  coordinator:
    replicas: 1
  worker:
    replicas: 2
```

### AWS Override (External Athena)

```yaml
# values-aws-athena.yaml
trino:
  enabled: false  # Don't deploy Trino
  external:
    enabled: true
    host: "athena.us-east-1.amazonaws.com"
    port: 443
    catalog: "awsdatacatalog"
```

**Usage**:
```bash
# On-prem/self-hosted
helm install koku ./ros-ocp

# AWS with Athena
helm install koku ./ros-ocp -f values-aws-athena.yaml
```

---

**Document Status**: ✅ Complete
**Recommendation**: Flexible Helm chart supporting all 3 options
**Default**: Self-hosted (for maximum compatibility)
**AWS Users**: Provide override for Athena/EMR
**Next Action**: Implement conditional Trino deployment in Helm templates

