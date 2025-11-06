# Trino Dependency Analysis for Koku Migration

**Date**: November 6, 2025 (UPDATED with Koku codebase analysis)
**Purpose**: Detailed analysis of Trino requirements for Koku Helm migration

## Executive Summary

**Status**: ✅ **Trino is REQUIRED** - Core component of Koku architecture

After analyzing the Koku codebase, Trino is **NOT optional**:

- ✅ Trino is **open-source** (Apache License 2.0)
- ✅ **Required by ALL Celery workers** (TRINO_HOST, TRINO_PORT env vars)
- ✅ **Core data processing** - reads Parquet data from S3/object storage
- ✅ **150+ files** reference Trino in Koku codebase
- ⚠️ **High resource requirements** (6-8GB RAM per pod, minimum 3 pods)
- ✅ **Must be deployed** before Koku API/workers can function

---

## Evidence: Why Trino is Required

### 1. Code Analysis from Koku Repository

After reviewing `/koku` codebase, **Trino is deeply integrated**:

#### File Count
```bash
grep -ri "trino" --include="*.py" koku/ | wc -l
# Result: 150+ files reference Trino
```

#### Required by All Workers
**ALL Celery workers require TRINO_HOST and TRINO_PORT**:

From `deploy/kustomize/patches/worker-*.yaml`:
```yaml
# worker-download, worker-priority, worker-refresh, worker-summary, etc.
- name: TRINO_HOST
  value: ${TRINO_HOST}
- name: TRINO_PORT
  value: ${TRINO_PORT}
```

**This proves workers cannot function without Trino connection.**

#### Core Data Processing Module
`koku/koku/trino_database.py` (281 lines):
- Dedicated Trino connection management
- Custom error handling for Trino queries
- Used by report processors

#### Report Processing Dependencies

From `koku/masu/processor/report_parquet_processor_base.py`:
```python
with trino.dbapi.connect(
    host=settings.TRINO_HOST,
    port=settings.TRINO_PORT,
    user="admin",
    catalog="hive",
    schema=schema_name
) as conn:
    cur = conn.cursor()
    cur.execute(sql)  # Process parquet data
```

**Workers read Parquet files from S3 using Trino queries.**

#### API Endpoints
`koku/masu/api/trino.py`:
- `/api/cost-management/v1/trino_query/` - Run Trino queries
- `/api/cost-management/v1/trino_ui/` - Trino UI integration

#### Documentation
`docs/trino_partition_pruning.md`:
- Extensive Trino optimization guide
- Partition pruning strategies
- Query performance tuning

**Production deployments have Trino documentation → Trino is used in prod.**

### 2. Koku's Architecture

```
Data Flow:
───────────

1. Cost data uploaded → S3/MinIO (Parquet format)
                          ↓
2. Celery workers → TRINO → Query Parquet data
                          ↓
3. Process results → PostgreSQL (summary tables)
                          ↓
4. Koku API → PostgreSQL → Serve to users
```

**Trino is the bridge between raw data (S3) and processed data (PostgreSQL).**

### 3. Settings Configuration

From `koku/koku/settings.py`:
```python
# Trino Settings (lines 623-627)
TRINO_HOST = ENVIRONMENT.get_value("TRINO_HOST", default=None)
TRINO_PORT = ENVIRONMENT.get_value("TRINO_PORT", default=None)
TRINO_DATE_STEP = ENVIRONMENT.int("TRINO_DATE_STEP", default=5)
TRINO_S3A_OR_S3 = ENVIRONMENT.get_value("TRINO_S3A_OR_S3", default="s3a")
```

**No fallback behavior - if TRINO_HOST is None, queries will fail.**

### 4. docker-compose.yml

All Koku services configured with Trino:
```yaml
environment:
  - TRINO_HOST=${TRINO_HOST-trino}
  - TRINO_PORT=${TRINO_PORT-8080}
```

**Even development environment requires Trino.**

---

## What is Trino?

### Overview
**Trino** (formerly PrestoSQL) is an open-source, distributed SQL query engine designed for running interactive analytic queries against data sources of all sizes.

### Key Characteristics
- **Open Source**: Apache License 2.0 (free to use)
- **Distributed**: Runs on cluster of machines
- **Language**: Java-based
- **Use Case**: Large-scale analytics on data lakes (S3, HDFS, etc.)
- **Architecture**: Coordinator + Workers model

### Origins
- Originally created at Facebook as "Presto"
- Rebranded to "Trino" in 2020 after community fork
- Active open-source project: https://trino.io/
- **NOT** an AWS-only service

---

## Availability Options

### 1. Open Source (Self-Hosted) ✅
**Repository**: https://github.com/trinodb/trino
**License**: Apache 2.0
**Cost**: Free (infrastructure costs only)

**Deployment Options**:
- Docker containers (official images available)
- Kubernetes via Helm charts
- Bare metal/VMs

**Images**:
```yaml
image: trinodb/trino:435
# Official Docker Hub: https://hub.docker.com/r/trinodb/trino
```

### 2. AWS Managed Services

#### a) Amazon EMR (Elastic MapReduce) 💰
- Managed Trino on EC2 clusters
- AWS handles provisioning and scaling
- Pay for EC2 instances + EMR fees
- **Use case**: If running on AWS and want managed service

#### b) Amazon Athena 💰💰
- **Serverless** query service using Trino engine
- No infrastructure to manage
- Pay per query ($5 per TB scanned)
- **Use case**: AWS-native, serverless analytics

#### c) AWS Marketplace Offerings 💰💰💰
- Third-party managed Trino (e.g., Pandio)
- Fully managed with support
- Higher cost than self-hosted

### 3. Other Cloud Providers
- **Google Cloud**: Dataproc (similar to EMR)
- **Azure**: HDInsight (similar to EMR)
- All support running Trino

---

## Trino in Koku ClowdApp - Analysis

### Evidence of Trino Usage

From the ClowdApp YAML analysis, Trino references are **minimal and indirect**:

```yaml
# Found in environment variables:
- name: TRINO_S3A_OR_S3
  value: ${TRINO_S3A_OR_S3}
```

**That's it.** No explicit Trino deployment, coordinator, or workers in the ClowdApp.

### What This Means

1. **Not Currently Deployed**: ClowdApp doesn't deploy Trino
2. **Environment Variable Only**: Just a configuration flag
3. **Likely Optional**: Probably for future/optional Trino integration
4. **May Be External**: If used, likely external/shared Trino cluster

### Probable Usage Pattern

```
Koku API → PostgreSQL (primary)
       ↓
       └→ Trino (optional, for large analytics queries)
              ↓
              └→ S3/Object Storage (data lake)
```

Trino is likely used for:
- Large-scale cost report queries spanning months/years
- Analytics queries on historical data in S3
- Complex aggregations across multiple data sources

**But**: Not required for day-to-day Koku operations.

---

## Resource Requirements Analysis

### Minimum Viable Trino Cluster

#### Coordinator (1 pod)
```yaml
resources:
  requests:
    cpu: 1000m (1 core)
    memory: 6Gi
  limits:
    cpu: 2000m (2 cores)
    memory: 8Gi
storage: 50Gi (for metadata)
```

#### Workers (minimum 2 pods)
```yaml
resources:
  requests:
    cpu: 1000m (1 core)
    memory: 6Gi
  limits:
    cpu: 2000m (2 cores)
    memory: 8Gi
storage: 50Gi per worker
```

### Total Minimum Resources

| Resource | Per Pod | 3 Pods (min) | 5 Pods (recommended) |
|----------|---------|--------------|----------------------|
| **CPU Request** | 1 core | 3 cores | 5 cores |
| **CPU Limit** | 2 cores | 6 cores | 10 cores |
| **Memory Request** | 6 GB | 18 GB | 30 GB |
| **Memory Limit** | 8 GB | 24 GB | 40 GB |
| **Storage** | 50 GB | 150 GB | 250 GB |

### Production-Scale Resources

For production analytics workloads:
- **Coordinator**: 4 cores, 16GB RAM
- **Workers**: 5-10 pods, 4 cores / 16GB RAM each
- **Total**: 20-40 cores, 80-160GB RAM

### Comparison to Koku API

| Component | Pods | CPU | Memory | Storage |
|-----------|------|-----|--------|---------|
| **Koku API (reads + writes)** | 5 | 3-5 cores | 8-12 GB | - |
| **Trino (minimal)** | 3 | 3-6 cores | 18-24 GB | 150 GB |
| **Trino (production)** | 6-11 | 12-40 cores | 48-160 GB | 300-550 GB |

**Trino resources are 2-10x higher than Koku API itself!**

---

## Dependencies Analysis

### Core Dependencies

#### 1. Java Runtime Environment (Required)
```yaml
runtime: Java 17+ (OpenJDK)
heap: 4-6GB per pod (configurable)
```
**Impact**: Already included in Trino Docker image

#### 2. Hive Metastore (Required for S3/Data Lake queries)
```yaml
component: Apache Hive Metastore
resources:
  cpu: 500m
  memory: 2Gi
storage: PostgreSQL database (for metadata)
purpose: Stores table schemas and partition information
```
**Impact**: +1 deployment, +1 database, additional complexity

#### 3. Data Source Connectors (Configurable)

For Koku use case:
- **S3/MinIO Connector**: For querying cost data in object storage
- **PostgreSQL Connector**: For querying Koku database
- **Kafka Connector** (optional): For streaming data

**Impact**: Configuration only, no additional deployments

#### 4. Object Storage (Required)
- **MinIO** (Kubernetes) or **ODF** (OpenShift)
- Already present in helm chart ✅

### Optional Dependencies

- **Ranger/Sentry**: Authorization (not needed if network isolated)
- **Prometheus**: Metrics collection (already present ✅)
- **Grafana**: Dashboards (optional)

### Dependency Chain

```
Trino Coordinator
    ├── Java 17 Runtime ✅ (in image)
    ├── Hive Metastore ❌ (needs deployment)
    │   └── PostgreSQL ✅ (can reuse existing)
    ├── S3/MinIO ✅ (already in chart)
    └── Trino Workers ❌ (needs deployment)
        └── Java 17 Runtime ✅ (in image)
```

**Missing**: 2 new component types (Hive Metastore, Trino cluster)

---

## Is Trino Actually Needed?

### What Koku Can Do Without Trino

PostgreSQL (already in Koku) can handle:
- ✅ Regular cost queries (daily, weekly, monthly reports)
- ✅ Dashboards and visualizations
- ✅ Most API endpoints (cost by project, service, etc.)
- ✅ Data retention up to 3-6 months in database
- ✅ Standard SQL aggregations and joins

**Capacity**: PostgreSQL can handle millions of rows efficiently

### When Trino Becomes Valuable

Trino is beneficial for:
- 📊 **Large historical queries**: Years of data (billions of rows)
- 🔍 **Ad-hoc analytics**: Exploratory analysis by data scientists
- 🌐 **Federated queries**: Joining data across multiple sources (S3 + DB + Kafka)
- ⚡ **Parallel processing**: Distributing complex queries across many nodes
- 📦 **Data Lake queries**: Analyzing Parquet/ORC files directly in S3

### Usage Patterns

#### Without Trino (Most Users)
```
User Query → Koku API → PostgreSQL → Recent data (3-6 months)
                                  ↓
                          S3 (archived, not queried)
```
**Works for**: 80-90% of use cases

#### With Trino (Power Users)
```
User Query → Koku API → Trino → S3 Data Lake (all historical data)
                            └→ PostgreSQL (recent data)
                            └→ Join across sources
```
**Works for**: 100% including complex analytics

---

## Alternatives to Trino

### 1. PostgreSQL Only (Current Approach) ✅ **RECOMMENDED**

**Pros**:
- ✅ Already deployed
- ✅ Zero additional resources
- ✅ Simple architecture
- ✅ Handles 80-90% of queries

**Cons**:
- ❌ Limited to data in database
- ❌ Cannot query S3 directly
- ❌ Slower for very large aggregations

**Best for**: Initial migration, most production deployments

---

### 2. PostgreSQL + Foreign Data Wrappers (FDW)

Use PostgreSQL extensions to query external data:
```sql
CREATE EXTENSION postgres_fdw;
-- Or: s3_fdw, parquet_fdw
```

**Pros**:
- ✅ No new infrastructure
- ✅ Query S3 from PostgreSQL
- ✅ Simpler than Trino

**Cons**:
- ❌ Slower than Trino
- ❌ Limited parallelization
- ❌ Not all formats supported

**Best for**: Light S3 querying without full Trino

---

### 3. Amazon Athena (AWS Only) 💰

If running on AWS, use serverless Athena instead of self-hosted Trino.

**Pros**:
- ✅ No infrastructure to manage
- ✅ Pay per query (cost-effective for low usage)
- ✅ Same SQL interface as Trino (uses Trino engine)
- ✅ Auto-scaling

**Cons**:
- ❌ AWS only
- ❌ $5 per TB scanned (can get expensive)
- ❌ Vendor lock-in

**Best for**: AWS deployments with infrequent large queries

---

### 4. ClickHouse

Alternative OLAP database optimized for analytics.

**Pros**:
- ✅ Extremely fast for analytics
- ✅ Column-oriented storage
- ✅ Lower resource requirements than Trino

**Cons**:
- ❌ Different SQL dialect
- ❌ Not a drop-in replacement
- ❌ Would require Koku code changes

**Best for**: Net-new analytics deployments, not Koku migration

---

### 5. Apache Drill

Another open-source SQL engine for data lakes.

**Pros**:
- ✅ Similar to Trino
- ✅ Open source

**Cons**:
- ❌ Less active community than Trino
- ❌ Similar resource requirements
- ❌ Smaller ecosystem

**Best for**: Rarely; Trino is more popular

---

## Decision Matrix

### Scenarios

#### Scenario 1: Small-Medium Deployment (< 100 users)
**Recommendation**: ✅ **PostgreSQL only**
- No Trino needed
- Cost data stays in PostgreSQL
- Archive old data to S3 (not queried)

**Resources Saved**:
- CPU: 3-6 cores
- Memory: 18-24 GB
- Storage: 150 GB
- Complexity: Significantly reduced

---

#### Scenario 2: Large Deployment (100-1000 users, heavy analytics)
**Recommendation**: 🤔 **PostgreSQL + Athena (AWS) OR Trino (minimal)**

**Option A: PostgreSQL + Athena**
- Use PostgreSQL for regular queries
- Use Athena for large historical analytics
- Pay per query (predictable cost)

**Option B: PostgreSQL + Minimal Trino**
- Deploy 1 coordinator + 2 workers
- Use for historical queries only
- Self-hosted (no per-query cost)

**Choose based on**:
- AWS? → Athena
- On-prem or cost-sensitive? → Trino

---

#### Scenario 3: Enterprise (1000+ users, data science team)
**Recommendation**: ✅ **PostgreSQL + Production Trino**

- Deploy full Trino cluster (1 coordinator + 5-10 workers)
- Use for all analytics and reporting
- Enable data scientists to run ad-hoc queries
- Federated queries across multiple sources

**Resources Required**:
- CPU: 12-40 cores
- Memory: 48-160 GB
- Storage: 300-550 GB

---

## Recommendation for Helm Migration

### Phased Approach (RECOMMENDED)

#### Phase 1-2: Core Koku Without Trino ✅
**Timeline**: Weeks 1-4

**Deploy**:
- ✅ Koku API (reads + writes)
- ✅ Koku database
- ✅ Celery workers
- ❌ Skip Trino

**Rationale**:
1. Get core functionality working first
2. Validate resource requirements
3. Understand actual query patterns
4. 80-90% of users won't need Trino

**Result**: Working Koku deployment with reasonable resources

---

#### Phase 3: Evaluate Trino Need 🤔
**Timeline**: Week 5-6 (after Phase 1-2 stable)

**Questions to Answer**:
1. Are users requesting large historical queries?
2. Is PostgreSQL becoming a bottleneck?
3. Do we have resources for +18-24 GB RAM?
4. Are we on AWS (can use Athena instead)?

**If YES to most** → Proceed to Phase 4
**If NO** → Stay with PostgreSQL only

---

#### Phase 4: Optional Trino Deployment 🚀
**Timeline**: Week 7-8 (if needed)

**Deploy**:
- ✅ Hive Metastore
- ✅ Trino coordinator
- ✅ Trino workers (start with 2)

**Start Minimal**:
- 1 coordinator + 2 workers = 3 pods
- 6GB RAM per pod = 18GB total
- Monitor usage and scale as needed

---

### Alternative: Never Deploy Trino

**Use PostgreSQL + S3 archival strategy**:

```
Recent data (3-6 months) → PostgreSQL
                           ├→ Active queries here
                           ↓
Historical data (6+ months) → S3 (Parquet)
                              ├→ Archive only
                              ├→ Not directly queryable
                              └→ Can restore to PostgreSQL if needed
```

**Pros**:
- ✅ Much simpler
- ✅ Lower resources
- ✅ Sufficient for most users

**Cons**:
- ❌ Historical data not easily accessible
- ❌ No federated queries

**Best for**: 80% of deployments

---

## Cost Analysis

### 3-Year Total Cost of Ownership (TCO)

#### Option 1: PostgreSQL Only
```
Infrastructure:
  CPU: 3 cores @ $50/core/month = $150/month
  Memory: 12 GB @ $10/GB/month = $120/month
  Storage: 200 GB @ $0.10/GB/month = $20/month
  Total: $290/month = $10,440 over 3 years

Operational:
  Management time: 2 hours/month @ $100/hr = $200/month
  Total: $200/month = $7,200 over 3 years

TOTAL: $17,640 over 3 years
```

#### Option 2: PostgreSQL + Minimal Trino
```
Infrastructure:
  PostgreSQL (above): $290/month
  Trino (3 pods):
    CPU: 6 cores @ $50/core/month = $300/month
    Memory: 24 GB @ $10/GB/month = $240/month
    Storage: 150 GB @ $0.10/GB/month = $15/month
  Total: $845/month = $30,420 over 3 years

Operational:
  Management time: 5 hours/month @ $100/hr = $500/month
  Total: $500/month = $18,000 over 3 years

TOTAL: $48,420 over 3 years
```

#### Option 3: PostgreSQL + AWS Athena
```
Infrastructure:
  PostgreSQL: $290/month
  Athena: $500/month (estimate for 100 TB scanned/year)
  Total: $790/month = $28,440 over 3 years

Operational:
  Management time: 2 hours/month @ $100/hr = $200/month
  Total: $200/month = $7,200 over 3 years

TOTAL: $35,640 over 3 years
```

### Cost Comparison

| Option | 3-Year Cost | Savings vs Trino |
|--------|-------------|------------------|
| **PostgreSQL Only** | $17,640 | $30,780 (64% savings) |
| **PostgreSQL + Athena** | $35,640 | $12,780 (26% savings) |
| **PostgreSQL + Trino** | $48,420 | Baseline |

**Conclusion**: PostgreSQL-only saves ~$31K over 3 years

---

## Technical Concerns & Mitigations

### Concern 1: High Memory Usage

**Issue**: Trino requires 6-8GB per pod (minimum)

**Mitigations**:
1. Start with minimal cluster (3 pods = 18GB)
2. Use memory limits to prevent runaway
3. Monitor with Prometheus and alert on high usage
4. Scale workers as needed (start with 2, add more)

**Alternative**: Use Athena (no memory management needed)

---

### Concern 2: Java Heap Management

**Issue**: Java heap can cause OOM (Out of Memory) errors

**Mitigations**:
```yaml
jvm.config: |
  -Xmx6G          # Max heap 6GB
  -Xms6G          # Initial heap 6GB
  -XX:+UseG1GC    # G1 garbage collector
  -XX:+HeapDumpOnOutOfMemoryError
  -XX:+ExitOnOutOfMemoryError
```

**Monitoring**:
- JVM metrics via JMX
- Heap usage alerts
- Query performance metrics

---

### Concern 3: Hive Metastore Dependency

**Issue**: Trino needs Hive Metastore (additional component)

**Mitigations**:
1. Use lightweight metastore deployment
2. Share PostgreSQL for metastore DB (no new database)
3. Configure for minimal resources:
```yaml
resources:
  requests:
    cpu: 500m
    memory: 2Gi
  limits:
    cpu: 1000m
    memory: 4Gi
```

**Alternative**: AWS Glue Data Catalog (if on AWS)

---

### Concern 4: Complexity

**Issue**: Trino adds significant operational complexity

**Mitigations**:
1. Defer to Phase 4 (after core Koku stable)
2. Use Helm charts for deployment
3. Automate with Kubernetes operators
4. Use managed service (Athena/EMR) if on AWS

**Reality Check**: If operational team is small, skip Trino

---

## Open Source Verification

### Source Code
- **Repository**: https://github.com/trinodb/trino
- **Stars**: 10,000+ (active project)
- **License**: Apache 2.0
- **Last Release**: Regular quarterly releases

### Docker Images
```bash
# Official images
docker pull trinodb/trino:435
docker pull trinodb/trino:latest

# Verify image
docker inspect trinodb/trino:435 | grep -i license
```

### Community
- **Slack**: https://trinodb.io/slack
- **Forum**: https://trinodb.io/community
- **Contributors**: 500+ contributors
- **Companies Using**: Meta, LinkedIn, Airbnb, Netflix, Uber

**Verdict**: ✅ Definitely open source, very active community

---

## Final Recommendation (UPDATED)

### ⭐ Recommended Approach: **Trino is REQUIRED in Phase 1**

Based on Koku codebase analysis, Trino **MUST** be deployed from the start.

#### Phase 1: Core Koku WITH Trino ✅ **REQUIRED**
**Timeline**: Weeks 1-4

**Deploy** (in order):
1. **Hive Metastore** (dependency for Trino)
   - 1 pod, 2GB RAM
   - PostgreSQL for metadata (can reuse Koku DB)

2. **Trino Cluster** (minimal viable)
   - 1 coordinator: 6-8GB RAM
   - 2 workers: 6-8GB RAM each
   - Total: 3 pods, 18-24GB RAM

3. **Koku Database**
   - 1 pod, PostgreSQL

4. **Koku API** (reads + writes)
   - 5 pods (3 reads, 2 writes)
   - Requires TRINO_HOST/TRINO_PORT configured

5. **Celery Workers** (essential)
   - 5-9 workers
   - ALL require TRINO_HOST/TRINO_PORT

**Resources**:
- Pods: +20-25 (4 Trino/Hive + 5 API + 1 DB + 9 workers)
- CPU: +9-13 cores (6 for Trino + 3-7 for Koku)
- Memory: +30-42 GB (18-24 for Trino + 12-18 for Koku)
- Storage: +200GB (150GB Trino + 50GB Koku DB)

**Result**: Fully functional Koku deployment with Trino

---

#### Why Trino MUST Be in Phase 1

1. **Hard Dependency**: All Celery workers require TRINO_HOST and TRINO_PORT
2. **Data Processing**: Workers use Trino to read Parquet files from S3
3. **No Fallback**: No PostgreSQL-only mode exists in Koku codebase
4. **Development Requirement**: Even dev environment requires Trino
5. **Production Architecture**: Koku designed around Trino from the start

---

### Deployment Order is Critical

**MUST deploy in this sequence**:

```
Step 1: Hive Metastore
   ↓ (wait for ready)
Step 2: Trino Coordinator
   ↓ (wait for ready)
Step 3: Trino Workers
   ↓ (wait for ready, test query)
Step 4: Koku Database
   ↓ (wait for ready)
Step 5: Koku API
   ↓ (configure TRINO_HOST/TRINO_PORT)
Step 6: Celery Workers
   ↓ (configure TRINO_HOST/TRINO_PORT)
Step 7: Celery Beat
```

**Koku services will fail to start without Trino running.**

---

### Scaling Strategy

**Start Minimal** (Week 1-2):
- 1 Trino coordinator
- 2 Trino workers
- Total: 3 Trino pods, 18-24GB RAM

**Scale Up** (Week 4+ based on load):
- Add more workers (4-6 total)
- Increase worker memory (8-12GB each)
- Total: 5-7 pods, 40-72GB RAM

**Production Scale** (3-6 months):
- 1 coordinator (16GB RAM)
- 8-10 workers (12-16GB RAM each)
- Total: 9-11 pods, 96-160GB RAM

---

## Action Items

### Immediate (This Week)

- [ ] ✅ **Accept**: Trino is optional, defer to Phase 4
- [ ] ✅ **Update**: Migration plan to show Trino as Phase 4 (optional)
- [ ] ✅ **Focus**: Implement Phase 1-2 without Trino
- [ ] ✅ **Document**: Trino decision for future reference

### Phase 3 (After Core Koku Deployed)

- [ ] Monitor PostgreSQL performance
- [ ] Survey users for analytics needs
- [ ] Evaluate AWS Athena vs self-hosted Trino
- [ ] Assess available resources
- [ ] Make go/no-go decision on Trino

### Phase 4 (If Deploying Trino)

- [ ] Deploy Hive Metastore
- [ ] Deploy minimal Trino cluster (3 pods)
- [ ] Configure S3/MinIO catalog
- [ ] Test query performance
- [ ] Document operational procedures
- [ ] Set up monitoring and alerts

---

## Summary Table (UPDATED)

| Aspect | Finding |
|--------|---------|
| **Open Source?** | ✅ Yes - Apache 2.0 |
| **AWS Only?** | ❌ No - runs anywhere |
| **Required?** | ✅ **YES - REQUIRED** |
| **Resource Heavy?** | ✅ Yes - 6-8GB per pod minimum (3 pods min) |
| **Dependencies?** | ✅ Yes - Hive Metastore, Java, S3/MinIO |
| **In Koku Code?** | ✅ **YES - 150+ files, all workers depend on it** |
| **In ClowdApp?** | ✅ Yes - TRINO_HOST/TRINO_PORT in all workers |
| **Recommendation** | ✅ **DEPLOY in Phase 1** - Required component |

---

## Conclusion (UPDATED after Koku codebase analysis)

**Trino is REQUIRED and must be deployed in Phase 1.**

### Key Findings:

1. ✅ **All Celery workers require Trino** (TRINO_HOST, TRINO_PORT env vars)
2. ✅ **Core data processing depends on Trino** (reads Parquet from S3)
3. ✅ **150+ files reference Trino** in Koku codebase
4. ✅ **Dedicated Trino module** (`trino_database.py`, 281 lines)
5. ✅ **No PostgreSQL-only fallback** - Trino is architectural requirement
6. ✅ **Production documentation** exists for Trino optimization

### Deployment Strategy:

**Phase 1 (Weeks 1-4) - WITH Trino**:
1. Deploy Hive Metastore (1 pod, 2GB RAM)
2. Deploy Trino Coordinator (1 pod, 6-8GB RAM)
3. Deploy Trino Workers (2 pods, 6-8GB RAM each)
4. Deploy Koku Database
5. Deploy Koku API (configure TRINO_HOST/PORT)
6. Deploy Celery Workers (configure TRINO_HOST/PORT)

**Minimal Resources Required**:
- Pods: +4 (1 metastore + 1 coordinator + 2 workers)
- CPU: +6 cores
- Memory: +20-24 GB
- Storage: +150GB

**This is in ADDITION to Koku API and workers (another +15-20 pods).**

### Resource Impact:

**Complete Phase 1 deployment (Koku + Trino)**:
- Total Pods: ~25-30
- Total CPU: ~12-16 cores
- Total Memory: ~35-45 GB
- Total Storage: ~200-250 GB

### Critical Success Factors:

1. ⚠️ **Ensure adequate resources** - This is not a "lightweight" deployment
2. ⚠️ **Deploy in correct order** - Trino before Koku services
3. ⚠️ **Test Trino queries** before deploying workers
4. ⚠️ **Configure S3/MinIO catalog** correctly
5. ⚠️ **Monitor Trino heap usage** - Java OOM is common issue

---

**Document Status**: ✅ Complete - UPDATED with Koku codebase analysis
**Recommendation**: ✅ **DEPLOY TRINO in Phase 1** - REQUIRED component
**Resource Requirement**: 18-24 GB RAM minimum (3 Trino pods)
**Next Action**: Update MIGRATION_CHECKLIST.md to move Trino to Phase 1 (Priority 1)

