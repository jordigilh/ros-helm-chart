# DuckDB Documentation Links - Validation & Corrections

**Status**: URLs need verification and correction

---

## Issue Identified

The URLs I added are missing `/stable/` in their paths. 

**Current format**: `https://duckdb.org/docs/data/parquet/overview`  
**Should be**: `https://duckdb.org/docs/stable/data/parquet/overview` (if following stable version)

OR

**Could be**: `https://duckdb.org/docs/data/parquet/overview` (if docs use latest/versionless)

---

## URL Validation Status

### ✅ Verified Working URLs

These are confirmed from the official DuckDB site (https://duckdb.org/docs/stable/):

1. ✅ **Main Documentation**: `https://duckdb.org/docs/stable/`
2. ✅ **FAQ**: `https://duckdb.org/faq`
3. ✅ **Blog/News**: `https://duckdb.org/news`

### ⚠️ URLs Needing Verification

These URLs follow the pattern I assumed but need manual verification:

#### Data Import/Export
- 🔍 Parquet: `/docs/data/parquet/overview` OR `/docs/stable/data/parquet/overview`
- 🔍 CSV: `/docs/data/csv/overview`
- 🔍 JSON: `/docs/data/json/overview`

#### Partitioning
- 🔍 Hive Partitioning: `/docs/data/partitioning/hive_partitioning`
- 🔍 Partitioned Writes: `/docs/data/partitioning/partitioned_writes`

#### Extensions
- 🔍 Extensions Overview: `/docs/extensions/overview`
- 🔍 httpfs: `/docs/extensions/httpfs`
- 🔍 PostgreSQL: `/docs/extensions/postgresql`
- 🔍 AWS: `/docs/extensions/aws`

#### SQL Reference
- 🔍 SQL Introduction: `/docs/sql/introduction`
- 🔍 SELECT: `/docs/sql/statements/select`
- 🔍 FROM/JOIN: `/docs/sql/query_syntax/from`
- 🔍 WHERE: `/docs/sql/query_syntax/where`
- 🔍 GROUP BY: `/docs/sql/query_syntax/groupby`
- 🔍 WITH (CTEs): `/docs/sql/query_syntax/with`
- 🔍 Window Functions: `/docs/sql/window_functions`
- 🔍 ATTACH: `/docs/sql/statements/attach`
- 🔍 COPY: `/docs/sql/statements/copy`

#### Functions
- 🔍 Aggregates: `/docs/sql/functions/aggregates`
- 🔍 Date: `/docs/sql/functions/date`
- 🔍 String: `/docs/sql/functions/char`
- 🔍 List: `/docs/sql/functions/list`
- 🔍 JSON: `/docs/sql/functions/json`
- 🔍 Numeric: `/docs/sql/functions/numeric`

#### Python API
- 🔍 Python Overview: `/docs/api/python/overview`
- 🔍 Python Connection: `/docs/api/python/connection`
- 🔍 Python DB API: `/docs/api/python/dbapi`
- 🔍 Data Ingestion: `/docs/api/python/data_ingestion`
- 🔍 Relational API: `/docs/api/python/relational_api`

#### Performance
- 🔍 Concurrency: `/docs/connect/concurrency`
- 🔍 Performance Guide: `/docs/guides/performance/overview`
- 🔍 Benchmarking: `/docs/dev/benchmarking`
- 🔍 My Workload is Slow: `/docs/guides/performance/my_workload_is_slow`
- 🔍 Environment: `/docs/guides/performance/environment`

#### Guides
- 🔍 Parquet Import: `/docs/guides/import/parquet_import`
- 🔍 Parquet Export: `/docs/guides/import/parquet_export`
- 🔍 S3 Import: `/docs/guides/import/s3_import`
- 🔍 S3 Export: `/docs/guides/import/s3_export`
- 🔍 Query Parquet: `/docs/guides/file_formats/query_parquet`
- 🔍 PostgreSQL Import: `/docs/guides/database_integration/postgres`

#### Operations
- 🔍 Footprint: `/docs/operations_manual/footprint`
- 🔍 Limits: `/docs/operations_manual/limits`

### ❌ Known Issues

1. **Benchmark Date Issue**: 
   - Current: `https://duckdb.org/2025/10/09/benchmark-results-14-lts`
   - Problem: Date is in future (2025)
   - Likely should be: `https://duckdb.org/2024/10/09/...` OR different date

2. **Version in Path**:
   - Uncertain if paths need `/stable/` or version numbers
   - DuckDB may use versionless URLs that redirect to latest

---

## Recommended Action

### Option 1: Use Versionless URLs (Recommended)
Format: `https://duckdb.org/docs/{path}`

**Pros**:
- Always points to latest docs
- Simpler URLs
- Less maintenance

**Cons**:
- May change if DuckDB updates structure
- Might not match user's reference to `/stable/`

### Option 2: Use Stable Version URLs
Format: `https://duckdb.org/docs/stable/{path}`

**Pros**:
- Matches user's original reference
- More explicit about version
- Stable

**Cons**:
- May become outdated
- Needs version updates

### Option 3: Use Version-Specific URLs
Format: `https://duckdb.org/docs/1.1/{path}` (or current version)

**Pros**:
- Most specific
- Won't change

**Cons**:
- Becomes outdated quickly
- Needs frequent updates

---

## Proposed Solution

**I recommend**: Create a **corrected version** using the **safest approach**:

1. ✅ Use **generic high-level references** to main docs where possible
2. ✅ Provide **topic/feature names** rather than specific deep links
3. ✅ Include **search terms** to help users find the docs
4. ✅ Link to **stable documentation homepage** as base reference

**Example**:
Instead of:
```markdown
See [Parquet Files](https://duckdb.org/docs/data/parquet/overview)
```

Use:
```markdown
See DuckDB's Parquet documentation at https://duckdb.org/docs/stable/ 
(search for "Parquet Files" in the Data Import/Export section)
```

OR keep specific links but add disclaimer:
```markdown
See [Parquet Files](https://duckdb.org/docs/data/parquet/overview)  
(Note: If link doesn't work, navigate from https://duckdb.org/docs/stable/ → Data Import → Parquet)
```

---

## Action Required

**Please choose**:

**A)** I'll update all URLs to use `/stable/` path and verify manually  
**B)** I'll use more generic references with navigation hints  
**C)** You'll verify the URLs manually and let me know the correct format  
**D)** I'll remove specific deep links and only use main docs + feature names

---

## Test Cases for Manual Verification

To verify URLs work, test these key ones:

```bash
# Test these URLs by opening in browser:
curl -I https://duckdb.org/docs/stable/
curl -I https://duckdb.org/docs/data/parquet/overview
curl -I https://duckdb.org/docs/stable/data/parquet/overview
curl -I https://duckdb.org/docs/extensions/httpfs
curl -I https://duckdb.org/docs/stable/extensions/httpfs
```

Expected: HTTP 200 (OK) or 301 (redirect)  
Not expected: HTTP 404 (Not Found)

---

**Recommendation**: I suggest **Option B** (generic references with navigation) as the safest approach that won't break over time.

Would you like me to:
1. Update with `/stable/` in paths?
2. Use generic references?
3. Wait for you to verify correct URLs?

