# Provider Management - Day 2 Operations

## Overview

This guide explains how to add cost providers to your Cost Management deployment after initial installation.

## Architecture

```
┌─────────────────┐
│  Sources API    │ ← Red Hat recommended way to manage providers
│                 │   (REST API for Day 2 operations)
└────────┬────────┘
         │
         ├─→ Creates "Source" (AWS account, Azure subscription, etc.)
         ├─→ Creates "Authentication" (credentials, ARNs)
         └─→ Creates "Application" (links source to Cost Management with S3 config)
                  │
                  ↓
         ┌────────────────┐
         │  Koku (API)    │
         │                │
         └────────┬───────┘
                  │
                  ↓
         ┌────────────────┐
         │  MASU          │ ← Processes cost data from S3
         │                │
         └────────────────┘
```

## Method 1: Sources API (Recommended)

The Sources API is the official Red Hat way to manage providers. It properly handles:
- Provider lifecycle management
- Authentication
- Integration with Cost Management

### Prerequisites

1. **Access to Sources API**:
   ```bash
   kubectl port-forward -n cost-mgmt svc/koku-sources-api 8001:8000
   ```

2. **Organization ID**: Your tenant org ID (e.g., `org1234567`)

### Example: Add AWS Provider

```bash
# Get source type ID
curl -X GET "http://localhost:8001/api/sources/v3.1/source_types" \
  -H "x-rh-sources-org-id: org1234567" \
  | jq '.data[] | select(.name=="amazon") | .id'

# Get Cost Management application type ID
curl -X GET "http://localhost:8001/api/sources/v3.1/application_types" \
  -H "x-rh-sources-org-id: org1234567" \
  | jq '.data[] | select(.name=="/insights/platform/cost-management") | .id'

# Create source
curl -X POST "http://localhost:8001/api/sources/v3.1/sources" \
  -H "Content-Type: application/json" \
  -H "x-rh-sources-org-id: org1234567" \
  -d '{
    "name": "My AWS Account",
    "source_type_id": "1"
  }'

# Save source_id from response

# Create authentication (optional for on-prem)
curl -X POST "http://localhost:8001/api/sources/v3.1/authentications" \
  -H "Content-Type: application/json" \
  -H "x-rh-sources-org-id: org1234567" \
  -d '{
    "resource_type": "Source",
    "resource_id": "<source_id>",
    "authtype": "cloud-meter-arn",
    "username": "arn:aws:iam::123456789012:role/CostManagementRole"
  }'

# Create Cost Management application with S3 config
curl -X POST "http://localhost:8001/api/sources/v3.1/applications" \
  -H "Content-Type: application/json" \
  -H "x-rh-sources-org-id: org1234567" \
  -d '{
    "source_id": "<source_id>",
    "application_type_id": "2",
    "extra": {
      "bucket": "my-cost-bucket",
      "report_name": "my-cost-report",
      "report_prefix": ""
    }
  }'
```

### Python Example

```python
from e2e_validator.clients.sources_api import SourcesAPIClient

# Initialize client
sources = SourcesAPIClient(
    base_url="http://localhost:8001",
    org_id="org1234567"
)

# Create complete AWS source
result = sources.create_aws_source_full(
    name="My AWS Account",
    bucket="my-cost-bucket",
    report_name="my-cost-report"
)

print(f"Source created: {result['source_id']}")
print(f"Application ID: {result['application_id']}")
```

## Method 2: E2E Validator (For Testing)

The E2E validator includes provider creation as part of its test flow:

```bash
# Run with provider creation
./scripts/e2e-validate.sh --namespace cost-mgmt

# Skip provider creation (use existing)
./scripts/e2e-validate.sh --namespace cost-mgmt --skip-provider
```

The validator will automatically:
1. Check for existing provider
2. Create via Sources API (if available)
3. Fallback to Django ORM (if Sources API unavailable)
4. Upload test data
5. Validate processing

## Method 3: Direct Database (NOT RECOMMENDED)

⚠️ **Not recommended for production use.** Direct database access bypasses:
- Sources API validation
- Proper tenant provisioning
- Event notifications
- Audit logging

Only use for:
- Emergency recovery
- Development/debugging
- When Sources API is unavailable

```sql
-- Connect to database
kubectl exec -n cost-mgmt koku-koku-db-0 -- psql -U postgres -d koku

-- Create customer (if not exists)
INSERT INTO api_customer (uuid, schema_name, date_created, date_updated)
VALUES (gen_random_uuid(), 'org1234567', NOW(), NOW())
ON CONFLICT (schema_name) DO NOTHING;

-- Create provider
INSERT INTO api_provider (uuid, name, type, setup_complete, active, paused, customer_id, created_timestamp, infrastructure_id, data_updated_timestamp, additional_context)
VALUES (
    gen_random_uuid(),
    'AWS Test Provider',
    'AWS',
    true,
    true,
    false,
    (SELECT id FROM api_customer WHERE schema_name = 'org1234567'),
    NOW(),
    gen_random_uuid(),
    NOW(),
    '{}'::jsonb
);

-- Create billing source
INSERT INTO api_providerbillingsource (uuid, data_source)
VALUES (
    gen_random_uuid(),
    '{"bucket": "my-bucket", "report_name": "my-report", "report_prefix": ""}'::jsonb
);

-- Link billing source to provider
UPDATE api_provider
SET billing_source_id = (
    SELECT id FROM api_providerbillingsource
    WHERE data_source->>'bucket' = 'my-bucket'
)
WHERE name = 'AWS Test Provider';
```

## Verification

After creating a provider, verify it's working:

```bash
# Check provider in database
kubectl exec -n cost-mgmt koku-koku-db-0 -- psql -U postgres -d koku -c "
SELECT p.uuid, p.name, p.type, p.active, p.setup_complete,
       bs.data_source->>'bucket' as bucket
FROM api_provider p
LEFT JOIN api_providerbillingsource bs ON p.billing_source_id = bs.id;
"

# Check MASU logs for provider discovery
kubectl logs -n cost-mgmt -l app.kubernetes.io/component=masu --tail=100 | grep "Provider"

# Upload test data to S3
aws s3 cp my-cur-file.csv.gz s3://my-bucket/my-report/20250101-20250131/ --endpoint-url https://s3-endpoint

# Force MASU to process
kubectl exec -n cost-mgmt $(kubectl get pods -n cost-mgmt -l app.kubernetes.io/component=masu -o name | head -1) -- \
  python /opt/koku/koku/manage.py download_report \
    --provider-uuid <provider-uuid> \
    --report-name my-report
```

## Troubleshooting

### Provider not processing data

1. **Check provider status**:
   ```sql
   SELECT uuid, name, active, paused, setup_complete
   FROM api_provider;
   ```

2. **Check billing source**:
   ```sql
   SELECT p.name, bs.data_source
   FROM api_provider p
   JOIN api_providerbillingsource bs ON p.billing_source_id = bs.id;
   ```

3. **Check MASU logs**:
   ```bash
   kubectl logs -n cost-mgmt -l app.kubernetes.io/component=masu --tail=500
   ```

4. **Verify S3 access**:
   ```bash
   # Test from MASU pod
   kubectl exec -n cost-mgmt $(kubectl get pods -n cost-mgmt -l app.kubernetes.io/component=masu -o name | head -1) -- \
     python3 -c "
import boto3
s3 = boto3.client('s3', endpoint_url='https://your-s3-endpoint', verify=False)
print(s3.list_buckets())
   "
   ```

### Sources API errors

1. **Check Sources API logs**:
   ```bash
   kubectl logs -n cost-mgmt -l app.kubernetes.io/component=sources-api --tail=200
   ```

2. **Verify API accessibility**:
   ```bash
   curl -v http://localhost:8001/api/sources/v3.1/source_types \
     -H "x-rh-sources-org-id: org1234567"
   ```

3. **Check Sources database**:
   ```bash
   kubectl exec -n cost-mgmt koku-sources-db-0 -- psql -U postgres -d sources_api_development -c "\dt"
   ```

## References

- [Sources API OpenAPI Spec](http://localhost:8001/api/sources/v3.1/openapi.json)
- [Koku Provider Models](https://github.com/project-koku/koku/blob/main/koku/api/models.py)
- [E2E Validator Usage](./QUICK_START.md)

