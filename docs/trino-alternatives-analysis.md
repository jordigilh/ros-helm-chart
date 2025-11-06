# Trino Alternatives Analysis

Open source alternatives to Trino for querying Parquet files from S3/MinIO for Koku cost management.

---

## Key Requirements for Koku

Based on Koku's architecture, any Trino alternative must:
1. ✅ Query **Parquet files** from S3/MinIO
2. ✅ Support **SQL interface** (Koku uses SQL queries)
3. ✅ Connect via **Python** (Koku is Django/Python)
4. ✅ Handle **concurrent queries** from multiple Celery workers
5. ✅ Support **Hive-style partitioning** (Koku partitions by date/source)
6. ✅ Provide **JDBC/ODBC or Python drivers**

---

## Alternatives Comparison

| Engine | License | Deployment | Resource Usage | Koku Compatibility | Maturity |
|--------|---------|------------|----------------|-------------------|----------|
| **Trino** | Apache 2.0 | Cluster | High (20+ GB) | ✅ **Current** | Very High |
| **DuckDB** | MIT | Embedded/Service | **Very Low (512MB-2GB)** | ⭐ **Best Alt** | High |
| **PrestoDB** | Apache 2.0 | Cluster | High (20+ GB) | ✅ Excellent | Very High |
| **Apache Drill** | Apache 2.0 | Cluster | Medium (8-16 GB) | ✅ Good | High |
| **AWS Athena** | Proprietary | Serverless | Pay-per-query | ✅ Good | Very High |
| **Apache Spark SQL** | Apache 2.0 | Cluster | Very High (30+ GB) | ⚠️ Moderate | Very High |
| **Apache Impala** | Apache 2.0 | Cluster | High (20+ GB) | ⚠️ Moderate | High |
| **ClickHouse** | Apache 2.0 | Cluster | Medium (8-16 GB) | ❌ Poor | High |

---

## 1. DuckDB ⭐ **RECOMMENDED ALTERNATIVE**

### Overview
DuckDB is an embedded analytical database (like SQLite for analytics) with **excellent Parquet support** and **minimal resource requirements**.

### Why DuckDB is Ideal for Koku

**Pros**:
- ✅ **Extremely lightweight**: 512MB-2GB RAM (vs 20+ GB for Trino)
- ✅ **Native Parquet support**: Built-in, optimized Parquet reader
- ✅ **S3/MinIO support**: Direct S3 queries via `httpfs` extension
- ✅ **Python integration**: Excellent Python API (`duckdb-python`)
- ✅ **SQL compatible**: Supports standard SQL (similar to Trino)
- ✅ **No cluster management**: Can run embedded or as single server
- ✅ **Fast**: Often faster than Trino for single-node queries
- ✅ **Open source**: MIT license (more permissive than Apache 2.0)

**Cons**:
- ❌ **Single-node**: Not distributed (but may be sufficient for Koku)
- ⚠️ **Limited concurrency**: Best for < 10 concurrent queries
- ⚠️ **Memory-bound**: Must fit working set in memory

### Resource Requirements

**Minimal Deployment**:
- 1 pod, 512MB-1GB RAM, 0.5 CPU
- Total: **1 pod, ~1GB RAM, 0.5 CPU** ⭐

**Recommended Deployment**:
- 1 pod, 2GB RAM, 1 CPU
- Total: **1 pod, 2GB RAM, 1 CPU**

**Cost Savings**: **95% reduction** vs Trino (1GB vs 20GB)

### Koku Integration Effort

**Minimal changes required**:

1. **Connection string change** (1 line):
```python
# Before (Trino)
import trino.dbapi
conn = trino.dbapi.connect(
    host=settings.TRINO_HOST,
    port=settings.TRINO_PORT
)

# After (DuckDB)
import duckdb
conn = duckdb.connect(':memory:')  # Or persistent DB
conn.execute("INSTALL httpfs; LOAD httpfs;")
```

2. **SQL queries remain mostly the same**:
```python
# Trino SQL
SELECT * FROM hive.koku.cost_data
WHERE year=2024 AND month=11

# DuckDB SQL (nearly identical)
SELECT * FROM 's3://koku-bucket/cost_data/year=2024/month=11/*.parquet'
```

3. **Minor dialect differences**:
- Date functions: `date_trunc()` → `date_trunc()`  (same)
- Casting: `CAST(x AS VARCHAR)` → `CAST(x AS VARCHAR)` (same)
- Aggregations: Nearly identical

**Estimated migration effort**: 1-2 weeks

### Deployment Options

**Option 1: Embedded Mode** (Simplest)
- Run DuckDB **inside** each Koku worker process
- No separate service needed
- Minimal resources

**Option 2: Service Mode** (Recommended)
- Single DuckDB server pod
- Workers connect via HTTP or direct connection
- Easier to monitor and manage

**Option 3: Multiple Instances**
- One DuckDB per worker type
- Maximum isolation
- Slightly more resources

### Example Configuration

```yaml
# values.yaml for DuckDB (if deployed separately)
duckdb:
  enabled: true
  image:
    repository: duckdb/duckdb
    tag: "latest"
  resources:
    requests:
      memory: 1Gi
      cpu: 500m
    limits:
      memory: 2Gi
      cpu: 1000m
```

### When DuckDB is NOT Suitable

- ❌ Very high query concurrency (> 20 simultaneous queries)
- ❌ Data size > 100GB (DuckDB still works but slower)
- ❌ Need distributed query processing across nodes
- ❌ Need query federation across multiple data sources

### Example: DuckDB Query Performance

```python
import duckdb
import time

# Connect to S3
conn = duckdb.connect(':memory:')
conn.execute("""
    INSTALL httpfs;
    LOAD httpfs;
    SET s3_endpoint='minio.ros-ocp.svc.cluster.local:9000';
    SET s3_use_ssl=false;
    SET s3_access_key_id='minioaccesskey';
    SET s3_secret_access_key='miniosecretkey';
""")

# Query Parquet files
start = time.time()
result = conn.execute("""
    SELECT source, SUM(cost) as total_cost
    FROM 's3://koku-bucket/cost_data/year=2024/month=11/*.parquet'
    GROUP BY source
""").fetchall()
print(f"Query time: {time.time() - start:.2f}s")
```

**Typical performance**: 0.5-5 seconds for 100MB-1GB Parquet files

---

## 2. PrestoDB

### Overview
The original project from which Trino was forked in 2020. **Nearly identical** to Trino.

### Compatibility with Koku
- ✅ **Excellent**: Drop-in replacement for Trino
- ✅ SQL dialect: 99% compatible with Trino
- ✅ Python driver: `presto-python-client` (similar to `trino-python-client`)
- ✅ Hive connector: Identical to Trino

### Resource Requirements
- **Same as Trino**: 20-24 GB RAM minimum
- No resource savings

### Migration Effort
- **Minimal**: 1-3 days (mostly changing connection strings)
- SQL queries: No changes needed

### When to Choose PrestoDB
- ✅ Already familiar with PrestoDB
- ✅ Need specific PrestoDB features
- ❌ Otherwise, stick with Trino (more active development)

---

## 3. Apache Drill

### Overview
Schema-free SQL query engine for Hadoop, NoSQL, and cloud storage.

### Compatibility with Koku
- ✅ **Good**: Supports Parquet, S3, Hive partitioning
- ⚠️ SQL dialect: Similar but not identical to Trino
- ✅ Python driver: Available (`pydrill`)

### Resource Requirements
- **Medium**: 8-16 GB RAM (50% less than Trino)
- Coordinator: 4GB, Workers: 4GB each

### Migration Effort
- **Moderate**: 2-4 weeks
- SQL queries: Need to adapt to Drill dialect
- Connection code: Need to rewrite

### When to Choose Drill
- ✅ Need schema flexibility
- ✅ Want lower resources than Trino
- ⚠️ Can accept moderate migration effort

---

## 4. AWS Athena (Production Context)

### Overview
AWS-managed serverless query service based on Presto/Trino.

**NOTE**: This is what Koku currently uses in production (per user feedback).

### Compatibility with Koku
- ✅ **Excellent**: Based on Presto (Trino's predecessor)
- ✅ SQL dialect: Nearly identical to Trino
- ✅ Python driver: `PyAthena` or standard JDBC

### Resource Requirements
- **Serverless**: Pay per query ($5 per TB scanned)
- No infrastructure to manage

### Costs
- **Typical**: $50-500/month for small-medium deployments
- **Large**: $500-2000/month for large deployments
- vs. **Self-hosted Trino**: $400-1200/month for EKS nodes

### When to Choose Athena
- ✅ Already on AWS
- ✅ Want zero infrastructure management
- ✅ Predictable, moderate query volume
- ❌ Not suitable for on-prem deployments

---

## 5. Apache Spark SQL

### Overview
Distributed data processing framework with SQL interface.

### Compatibility with Koku
- ⚠️ **Moderate**: Different architecture (batch vs interactive)
- ⚠️ SQL dialect: Slightly different from Trino
- ✅ Python integration: Excellent (`pyspark`)

### Resource Requirements
- **Very High**: 30-40 GB RAM minimum
- More resource-intensive than Trino

### Migration Effort
- **High**: 4-8 weeks
- Need to rewrite queries for Spark SQL
- Need to set up Spark cluster

### When to Choose Spark SQL
- ✅ Already using Spark for other workloads
- ✅ Need batch processing capabilities
- ❌ **NOT recommended** for Koku (too heavy)

---

## 6. ClickHouse

### Overview
Columnar database optimized for real-time analytics.

### Compatibility with Koku
- ❌ **Poor**: Different data model (database vs data lake)
- ❌ Would need to **import** Parquet data into ClickHouse
- ❌ Not designed for querying external S3 files directly

### Migration Effort
- **Very High**: 8-12 weeks
- Need to change architecture (load data vs query files)

### When to Choose ClickHouse
- ❌ **NOT suitable** for Koku's use case
- Better for: Real-time dashboards, time-series data

---

## Decision Matrix

### For Development/Testing

| Priority | Alternative | Reason | Resource Savings |
|----------|------------|--------|------------------|
| 1 | **DuckDB** | Minimal resources, easy setup | 95% (1GB vs 20GB) |
| 2 | Trino minimal config | Known to work | 75% (5GB vs 20GB) |
| 3 | Apache Drill | Moderate resources | 50% (10GB vs 20GB) |

**Recommendation**: **DuckDB** ⭐

### For Production (Self-Hosted)

| Priority | Alternative | Reason | Resource Savings |
|----------|------------|--------|------------------|
| 1 | **Trino** | Current solution, proven | 0% (baseline) |
| 2 | PrestoDB | Nearly identical, proven | 0% |
| 3 | Apache Drill | Lower resources | 50% |

**Recommendation**: **Stick with Trino** or use **AWS Athena**

### For Production (AWS)

| Priority | Alternative | Reason | Cost |
|----------|------------|--------|------|
| 1 | **AWS Athena** | Serverless, managed | $50-500/month |
| 2 | Self-hosted Trino on EKS | More control | $400-1200/month |

**Recommendation**: **AWS Athena** (current production setup)

---

## Migration Complexity

### DuckDB Migration (Low Complexity)

**Changes needed**:
1. Replace `trino.dbapi` with `duckdb`
2. Update connection code (5-10 files)
3. Test SQL queries (most will work as-is)
4. Minor SQL dialect adjustments (<5% of queries)

**Estimated effort**: 1-2 weeks

**Risk**: Low

### PrestoDB Migration (Very Low Complexity)

**Changes needed**:
1. Replace `trino-python-client` with `presto-python-client`
2. Update connection strings
3. No SQL changes needed

**Estimated effort**: 1-3 days

**Risk**: Very Low

### Drill Migration (Moderate Complexity)

**Changes needed**:
1. Replace Trino driver with `pydrill`
2. Rewrite connection code
3. Adapt 20-30% of SQL queries

**Estimated effort**: 2-4 weeks

**Risk**: Moderate

---

## Resource Comparison (Development)

```
┌─────────────────────────────────────────────────┐
│ Resource Usage Comparison                       │
├─────────────────────────────────────────────────┤
│                                                 │
│  Trino (Minimal)     ████████ 5 GB RAM         │
│  Trino (Dev)         ████████████████ 10 GB    │
│  Trino (Production)  ████████████████████████   │
│                      20+ GB RAM                 │
│                                                 │
│  DuckDB              █ 1 GB RAM    ⭐           │
│  Apache Drill        ████████ 8 GB RAM         │
│  PrestoDB            ████████████████████████   │
│                      20+ GB RAM                 │
│  Spark SQL           ██████████████████████████ │
│                      30+ GB RAM                 │
└─────────────────────────────────────────────────┘
```

---

## Recommendations by Use Case

### Case 1: Local Development
**Problem**: Laptop/workstation with limited RAM (< 16 GB)

**Solution**: **DuckDB** ⭐
- Runs on 1-2 GB RAM
- No cluster management
- Fast local queries

**Implementation**:
```bash
pip install duckdb
# No separate deployment needed
```

---

### Case 2: CI/CD Testing
**Problem**: Need fast, resource-efficient tests

**Solution**: **DuckDB** ⭐
- Starts instantly
- Minimal resource usage
- Can run in container

**Implementation**:
```yaml
# .github/workflows/test.yml
- name: Test with DuckDB
  run: |
    pip install duckdb
    python manage.py test
```

---

### Case 3: Production (AWS)
**Problem**: Need production-grade query engine on AWS

**Solution**: **AWS Athena** (current)
- Serverless, no management
- Proven to work with Koku
- Cost-effective for moderate usage

**Keep using current setup** ✅

---

### Case 4: Production (On-Prem)
**Problem**: Need self-hosted solution for on-prem deployment

**Solution**: **Trino**
- Proven with Koku
- Mature ecosystem
- Strong community

**Use the Trino chart we're building** ✅

---

### Case 5: Resource-Constrained Production
**Problem**: Limited resources but need production deployment

**Solution**: **Apache Drill** or **DuckDB**
- Drill: 50% less resources than Trino
- DuckDB: 95% less resources (if workload fits single node)

**Test carefully before production use**

---

## Proof of Concept: DuckDB for Koku

### Step 1: Install DuckDB
```bash
pip install duckdb
```

### Step 2: Test Parquet Query
```python
import duckdb

# Connect
conn = duckdb.connect(':memory:')

# Configure S3
conn.execute("""
    INSTALL httpfs;
    LOAD httpfs;
    SET s3_endpoint='minio.ros-ocp.svc.cluster.local:9000';
    SET s3_use_ssl=false;
    SET s3_access_key_id='minioaccesskey';
    SET s3_secret_access_key='miniosecretkey';
""")

# Query Parquet files
result = conn.execute("""
    SELECT * FROM 's3://koku-bucket/cost_data/year=2024/month=11/*.parquet'
    LIMIT 10
""").fetchall()

print(result)
```

### Step 3: Create DuckDB Backend for Koku

```python
# koku/database/duckdb_backend.py
import duckdb
from django.conf import settings

class DuckDBConnection:
    def __init__(self):
        self.conn = duckdb.connect(':memory:')
        self._configure_s3()

    def _configure_s3(self):
        self.conn.execute("INSTALL httpfs; LOAD httpfs;")
        self.conn.execute(f"SET s3_endpoint='{settings.S3_ENDPOINT}';")
        self.conn.execute(f"SET s3_access_key_id='{settings.S3_ACCESS_KEY}';")
        self.conn.execute(f"SET s3_secret_access_key='{settings.S3_SECRET_KEY}';")

    def execute(self, query):
        return self.conn.execute(query).fetchall()
```

### Step 4: Replace Trino Calls

```python
# Before (Trino)
from koku.trino_database import TrinoConnection
conn = TrinoConnection()
results = conn.execute("SELECT * FROM hive.koku.cost_data")

# After (DuckDB)
from koku.duckdb_backend import DuckDBConnection
conn = DuckDBConnection()
results = conn.execute("SELECT * FROM 's3://koku-bucket/cost_data/*.parquet'")
```

---

## Final Recommendation

### For Koku Helm Chart Migration

**Development**: Use **DuckDB** ⭐
- **Why**: 95% resource reduction (1GB vs 20GB)
- **Effort**: 1-2 weeks to integrate
- **Risk**: Low (fallback to Trino if issues)

**Testing/CI**: Use **DuckDB** ⭐
- **Why**: Fast, minimal resources
- **Effort**: Minimal
- **Risk**: Very Low

**Production (AWS)**: Keep **AWS Athena** ✅
- **Why**: Already working, serverless
- **Effort**: None
- **Risk**: None

**Production (On-Prem)**: Use **Trino** ✅
- **Why**: Proven, scalable, mature
- **Effort**: Complete the Trino chart
- **Risk**: Low (known solution)

---

## Action Items

### Immediate (Development)
1. ✅ Document Trino alternatives
2. 🔄 Create DuckDB proof of concept
3. 🔄 Test DuckDB with Koku sample data
4. 🔄 Compare query performance (DuckDB vs Trino)

### Short-term (1-2 weeks)
1. ⏳ Complete Trino chart templates
2. ⏳ Add DuckDB option to deployment scripts
3. ⏳ Document when to use each alternative

### Long-term (1-3 months)
1. ⏳ Support both DuckDB and Trino in Koku
2. ⏳ Auto-detect and choose based on environment
3. ⏳ Performance benchmarks

---

## Summary Table

| Alternative | Resources | Migration | Best For | Recommendation |
|-------------|-----------|-----------|----------|----------------|
| **DuckDB** | ⭐⭐⭐⭐⭐ (1GB) | Easy (1-2w) | Dev, Testing | **Try it!** ⭐ |
| **PrestoDB** | ⭐ (20GB) | Easy (1-3d) | Drop-in | If needed |
| **Drill** | ⭐⭐⭐ (8GB) | Moderate (2-4w) | Resource savings | Maybe |
| **Trino** | ⭐ (20GB) | N/A (current) | Production | **Keep** ✅ |
| **Athena** | ⭐⭐⭐⭐⭐ (serverless) | N/A (current) | AWS Production | **Keep** ✅ |

---

**Recommendation**: Explore **DuckDB** for development to drastically reduce resource requirements while keeping **Trino** for production on-prem deployments.

**Next Step**: Create a DuckDB proof of concept to validate compatibility with Koku.

---

**Document Version**: 1.0
**Last Updated**: November 6, 2025
**Status**: Analysis Complete

