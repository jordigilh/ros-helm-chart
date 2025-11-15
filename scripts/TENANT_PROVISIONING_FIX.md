# Tenant Provisioning Fix

## Problem Summary

The Cost Management Helm chart was deploying successfully, but **tenant provisioning was incomplete**, causing E2E tests and Day 2 provider operations to fail.

## Root Cause Analysis

### What Was Broken

1. **Migration Job Incomplete**:
   - `job-db-migrate.yaml` only ran `python manage.py migrate --noinput`
   - This only migrated the **PUBLIC schema** (shared tables)
   - Did NOT create tenant schemas or tenant-specific tables
   - Failed on `pg_stat_statements` extension (requires superuser)

2. **No Tenant Bootstrap**:
   - No Helm hook/job to create default tenant
   - Users had to manually create tenants after installation
   - Multi-tenant architecture requires:
     - `api_tenant` entry
     - `api_domain` entry (missing!)
     - PostgreSQL schema (`org1234567`)
     - Tenant-specific migrations (217 reporting tables)

3. **Provider Creation Confusion**:
   - E2E tests were using direct SQL/Django ORM
   - This bypassed the proper Red Hat workflow (Sources API)
   - Made it unclear how Day 2 operations should work

### Why Tests Used To Work

The bash script **never created new tenants** - it used `get_or_create()` and found a **pre-existing tenant** that was:
- Fully provisioned with schema + tables
- Created during initial setup (manually? bootstrap script? old deployment?)
- UUID: `d216ab69-1676-44a1-87b5-7e1995911bca`

When we cleaned up the database (`DROP SCHEMA org1234567 CASCADE`), we destroyed the tenant tables, exposing the fact that tenant provisioning was broken.

## Solution

### 1. Added Tenant Bootstrap Job

Created `templates/cost-management/job-tenant-bootstrap.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: koku-koku-api-tenant-bootstrap-{{ .Release.Revision }}
  annotations:
    helm.sh/hook: post-install
    helm.sh/hook-weight: "5"  # After migrations
```

**What it does**:
1. ✅ Creates `api_tenant` entry
2. ✅ Creates `api_domain` entry (was missing!)
3. ✅ Creates PostgreSQL schema
4. ✅ Runs tenant-specific migrations (217 tables)
5. ✅ Creates `api_customer` entry

**What it does NOT do**:
- ❌ Create providers (Day 2 operation via Sources API)

### 2. Fixed Migration Job

Updated `job-db-migrate.yaml` to:
- Create `pg_stat_statements` extension as postgres superuser first
- Fake-apply migration `0055_install_pg_stat_statements`
- Continue with remaining migrations

### 3. Added Sources API Client

Created `clients/sources_api.py`:
- REST API client for Sources API
- Proper Day 2 operations workflow
- Methods to create sources, authentication, applications

Updated `phases/provider.py`:
- Priority: Sources API > Django ORM > Direct SQL
- Use Sources API for provider creation in tests

### 4. Documentation

Created:
- `PROVIDER_MANAGEMENT.md` - Day 2 operations guide
- `TENANT_PROVISIONING_FIX.md` - This document
- Updated `values-koku.yaml` with `defaultOrgId` setting

## Verification

After applying fixes, the Helm chart now properly provisions tenants:

```bash
# 1. Install Helm chart
./scripts/install-cost-helm-chart.sh

# 2. Verify tenant bootstrap
kubectl logs -n cost-mgmt -l app.kubernetes.io/component=tenant-bootstrap

# 3. Check tenant tables
kubectl exec -n cost-mgmt koku-koku-db-0 -- psql -U postgres -d koku -c "
SELECT COUNT(*) FROM pg_tables
WHERE schemaname = 'org1234567' AND tablename LIKE 'reporting%';
"
# Expected: 217 tables

# 4. Verify tenant entries
kubectl exec -n cost-mgmt koku-koku-db-0 -- psql -U postgres -d koku -c "
SELECT t.schema_name, d.domain, d.is_primary
FROM api_tenant t
LEFT JOIN api_domain d ON t.id = d.tenant_id;
"
# Expected:
#  schema_name |      domain       | is_primary
# -------------+-------------------+------------
#  public      |                   |
#  org1234567  | org1234567.local  | t

# 5. Run E2E validation
./scripts/e2e-validate.sh --namespace cost-mgmt
```

## Key Learnings

### Multi-Tenant Architecture

Django-tenants requires:
1. **Shared tables** (PUBLIC schema):
   - `api_tenant` - List of all tenants
   - `api_domain` - Domain-to-tenant mapping (REQUIRED!)
   - `api_customer` - Customer/tenant metadata
   - `api_provider` - Provider definitions
   - `django_migrations` - Migration history

2. **Tenant tables** (per-tenant schema, e.g., `org1234567`):
   - 217 `reporting_*` tables
   - `django_migrations` - Tenant migration history
   - `cost_models_*` tables

3. **Migration Process**:
   - `migrate --noinput` → Migrates PUBLIC schema (shared apps)
   - `migrate_schemas --schema=<org_id>` → Migrates tenant schema (tenant apps)

### Sources API Workflow

Proper Day 2 provider creation:

```
User → Sources API → Source → Authentication → Application
                                                    ↓
                                          Cost Management
                                                    ↓
                                           Provider in Koku
                                                    ↓
                                                  MASU
                                                    ↓
                                          Processes S3 data
```

### E2E Testing Best Practices

1. **Use Sources API** for provider creation (matches production)
2. **Don't rely on manual setup** (bootstrap everything in Helm)
3. **Test from clean slate** (ensure new deployments work)
4. **Separate concerns**:
   - Helm chart: Infrastructure provisioning
   - Sources API: Day 2 operations (providers)
   - E2E tests: Validation

## Migration Path

For existing deployments with broken tenant provisioning:

### Option A: Manual Fix (Current Deployment)

```bash
# 1. Create missing domain entry
kubectl exec -n cost-mgmt koku-koku-db-0 -- psql -U postgres -d koku << EOF
INSERT INTO api_domain (domain, is_primary, tenant_id)
VALUES ('org1234567.local', true,
        (SELECT id FROM api_tenant WHERE schema_name = 'org1234567'));
EOF

# 2. Create schema
kubectl exec -n cost-mgmt koku-koku-db-0 -- psql -U postgres -d koku << EOF
CREATE SCHEMA IF NOT EXISTS org1234567;
GRANT ALL ON SCHEMA org1234567 TO koku;
EOF

# 3. Run tenant migrations
kubectl exec -n cost-mgmt $(kubectl get pods -n cost-mgmt -l app.kubernetes.io/component=masu -o jsonpath='{.items[0].metadata.name}') -- \
  python /opt/koku/koku/manage.py migrate_schemas --schema=org1234567

# 4. Create provider via Sources API or Django shell
```

### Option B: Redeploy with Fixed Chart

```bash
# 1. Backup important data (if any)
kubectl exec -n cost-mgmt koku-koku-db-0 -- pg_dump -U postgres koku > /tmp/koku-backup.sql

# 2. Uninstall and delete namespace
helm uninstall cost-mgmt -n cost-mgmt
kubectl delete namespace cost-mgmt

# 3. Install with fixed chart
./scripts/install-cost-helm-chart.sh

# 4. Tenant bootstrap will run automatically
# 5. Add providers via Sources API
```

## Future Improvements

1. **Add `pg_stat_statements` pre-creation**:
   - Init container or StatefulSet init command
   - Create extension before Django migrations

2. **Multi-tenant support**:
   - Allow creating multiple tenants via values.yaml
   - Helm value: `costManagement.tenants: [org1, org2, org3]`

3. **Sources API integration**:
   - Pre-create default provider via Sources API?
   - Or leave it to Day 2 operations (current approach)

4. **Monitoring**:
   - Add readiness probe that checks tenant provisioning
   - Pod should not be "Ready" until tenant exists

5. **Documentation**:
   - Include Day 2 operations in main README
   - Add troubleshooting guide
   - Document all API endpoints

## References

- [Django-tenants Documentation](https://django-tenants.readthedocs.io/)
- [Sources API OpenAPI Spec](http://localhost:8001/api/sources/v3.1/openapi.json)
- [Koku Multi-tenancy](https://github.com/project-koku/koku/blob/main/docs/multi-tenancy.md)
- [Provider Management Guide](./PROVIDER_MANAGEMENT.md)

