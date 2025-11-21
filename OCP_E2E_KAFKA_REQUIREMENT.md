# OCP E2E Test Kafka Requirement Analysis

**Date:** 2025-11-19
**Issue:** OCP E2E validation times out during processing phase
**Root Cause:** OCP providers require Kafka messages to trigger processing, not S3 polling

---

## Statement Verification ✅

**Evaluated Statement:**
> "So the create table for all providers happens inside convert_csv_to_parquet we actually have an additional create for Google cloud because some files contain multiple months and this means we create tables for both months."

**Verdict:** **CORRECT**

### Evidence from Koku Code

1. **Table Creation in `convert_csv_to_parquet`** (`parquet_report_processor.py:557-558`):
   ```python
   if self.create_table and not self.trino_table_exists.get(self.trino_table_exists_key):
       self.create_parquet_table(parquet_filepath)
   ```

2. **GCP Additional Table Creation** (`parquet_report_processor.py:466-468`):
   ```python
   if self.provider_type in [Provider.PROVIDER_GCP, Provider.PROVIDER_GCP_LOCAL]:
       # Sync partitions on each file to create partitions that cross month boundaries
       self.create_parquet_table(parquet_base_filename)
   ```

3. **Provider-Specific Table Creation Strategy** (`orchestrator.py:314-326`):
   ```python
   if (
       provider_type in [Provider.PROVIDER_OCP, Provider.PROVIDER_GCP,]
       or i == last_report_index
   ):
       report_context["create_table"] = True
   ```

---

## Provider Table Creation Strategies

| Provider | Frequency | Reason |
|----------|-----------|--------|
| **AWS** | Last file only | Optimization - reduce Trino/Hive table existence checks |
| **Azure** | Last file only | Same as AWS |
| **GCP** | Every file | Files can span multiple invoice months - need partition sync per file |
| **OCP** | Every file | Daily operator files - need immediate table availability |

**Key Insight:** OCP and GCP are more aggressive with table creation because:
- GCP: Invoice months can cross boundaries within a single CSV export
- OCP: Daily files arrive continuously from the operator, tables must be immediately available

---

## OCP Processing Architecture

### Critical Difference: Kafka-Driven vs S3-Polling

| Provider Type | Trigger Mechanism | S3 Polling | Kafka Messages |
|---------------|-------------------|------------|----------------|
| **AWS** | S3 Polling | ✅ Yes | ❌ No |
| **Azure** | S3 Polling | ✅ Yes | ❌ No |
| **GCP** | S3 Polling | ✅ Yes | ❌ No |
| **OCP** | Kafka Only | ❌ No | ✅ Yes (required!) |

### Why OCP is Different

From `kafka_msg_handler.py:459-475`:
```python
# Handle's messages with topics: 'platform.upload.announce',
# and 'platform.upload.available'.
#
# The OCP cost usage payload will land on topic hccm.
# These messages will be extracted into the local report
# directory structure.  Once the file has been verified
# (successfully extracted) we will report the status to
# the Insights Upload Service so the file can be made available
# to other apps on the service.
```

**OCP files come from koku-metrics-operator**, not from customer-managed S3 buckets:
1. Operator collects usage metrics from OpenShift
2. Operator creates CSV files (pod_usage, storage_usage, etc.)
3. Operator sends Kafka message to `platform.upload.announce`
4. MASU Kafka listener receives message
5. MASU downloads from operator's payload URL
6. MASU processes CSV → Parquet → Trino tables → PostgreSQL summaries

**For E2E testing:** We're simulating the operator by manually uploading CSV files to S3, but we still need to send the Kafka message to trigger processing!

---

## Current E2E Flow (BROKEN for OCP)

```
┌─────────────────────────────────────────────────────────┐
│ Phase 4: Data Upload                                    │
├─────────────────────────────────────────────────────────┤
│ 1. Generate OCP CSV files (pod_usage.csv, storage_usage.csv) │
│ 2. Upload to S3: s3://cost-data/reports/test-report/   │
│ 3. Reset provider timestamps                            │
│    - data_updated_timestamp = NOW()                     │
│    - polling_timestamp = NOW() - 10 minutes             │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ Phase 5-6: Processing (FAILS!)                          │
├─────────────────────────────────────────────────────────┤
│ 1. Trigger check_report_updates Celery task ✅          │
│ 2. MASU polls S3 for AWS/Azure/GCP providers ✅         │
│ 3. MASU SKIPS OCP provider (no S3 polling) ❌           │
│ 4. Wait 600 seconds... no manifests created ❌          │
│ 5. Timeout! Processing phase FAILED ❌                  │
└─────────────────────────────────────────────────────────┘
```

**Result:** 0 manifests created, no processing happens, E2E test fails

---

## Required E2E Flow (FIXED for OCP)

```
┌─────────────────────────────────────────────────────────┐
│ Phase 4: Data Upload                                    │
├─────────────────────────────────────────────────────────┤
│ 1. Generate OCP CSV files                               │
│ 2. Upload to S3                                         │
│ 3. Send Kafka message to 'platform.upload.announce' ✅  │  ← NEW!
│    - provider_uuid, cluster_id, org_id                  │
│    - file paths: pod_usage.csv, storage_usage.csv       │
│    - report_type for each file                          │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ Phase 5-6: Processing (SUCCESS!)                        │
├─────────────────────────────────────────────────────────┤
│ 1. Kafka listener receives message ✅                   │
│ 2. MASU creates manifest and file status records ✅     │
│ 3. MASU downloads CSV from S3 ✅                        │
│ 4. MASU converts CSV → Parquet ✅                       │
│ 5. MASU creates Trino tables ✅                         │
│ 6. MASU populates PostgreSQL summary tables ✅          │
│ 7. Manifest marked complete ✅                          │
└─────────────────────────────────────────────────────────┘
```

---

## Required Kafka Message Format

Based on `kafka_msg_handler.py:handle_message()`:

```json
{
  "request_id": "e2e-test-{uuid}",
  "account": "10001",
  "org_id": "org1234567",
  "b64_identity": "<base64-encoded-identity>",
  "service": "hccm",
  "files": [
    {
      "file": "https://s3-openshift-storage.apps.cluster/cost-data/reports/test-report/pod_usage.csv",
      "split_files": [],
      "report_type": "pod_usage"
    },
    {
      "file": "https://s3-openshift-storage.apps.cluster/cost-data/reports/test-report/storage_usage.csv",
      "split_files": [],
      "report_type": "storage_usage"
    }
  ],
  "provider_uuid": "b8241066-7048-4657-9603-6062891b5110",
  "provider_type": "OCP",
  "cluster_id": "test-cluster-123",
  "cluster_alias": "smoke-test-cluster",
  "schema_name": "org1234567",
  "start_date": "2025-11-01",
  "manifest_id": null
}
```

**Key Fields:**
- `service`: Must be `"hccm"` (Hybrid Cloud Cost Management) to route to cost management
- `b64_identity`: Base64-encoded x-rh-identity header for RBAC
- `files`: Array of file objects with S3 URLs and report types
- `provider_uuid`: The OCP provider UUID from E2E setup
- `cluster_id`: OCP cluster identifier
- `schema_name`: Tenant schema (org_id)

---

## Implementation Plan

### 1. Create Kafka Producer Client

**File:** `/scripts/e2e_validator/clients/kafka_producer.py`

```python
from confluent_kafka import Producer
import json
import base64
import uuid

class KafkaProducerClient:
    def __init__(self, kafka_bootstrap_servers):
        self.producer = Producer({
            'bootstrap.servers': kafka_bootstrap_servers,
            'client.id': 'e2e-validator'
        })

    def send_ocp_report_message(self, provider_uuid, org_id, cluster_id, files, s3_endpoint):
        """Send OCP report announcement to Kafka"""
        message = {
            "request_id": f"e2e-test-{uuid.uuid4()}",
            "account": "10001",
            "org_id": org_id,
            "service": "hccm",
            "files": [
                {
                    "file": f"{s3_endpoint}/cost-data/reports/test-report/{file}",
                    "split_files": [],
                    "report_type": file.replace(".csv", "").replace("_usage", "_usage")
                }
                for file in files
            ],
            "provider_uuid": provider_uuid,
            "provider_type": "OCP",
            "cluster_id": cluster_id,
            "schema_name": org_id
        }

        self.producer.produce(
            'platform.upload.announce',
            key=provider_uuid.encode('utf-8'),
            value=json.dumps(message).encode('utf-8')
        )
        self.producer.flush()
```

### 2. Update Data Upload Phase

**File:** `/scripts/e2e_validator/phases/data_upload.py`

Add Kafka message sending after S3 upload for OCP:

```python
def upload_ocp_format(self, ...):
    # ... existing upload code ...

    # For OCP, send Kafka message to trigger processing
    if self.kafka_producer:
        print(f"\n📨 Sending Kafka message to trigger OCP processing...")
        self.kafka_producer.send_ocp_report_message(
            provider_uuid=self.provider_uuid,
            org_id=self.org_id,
            cluster_id='test-cluster-123',
            files=['pod_usage.csv', 'storage_usage.csv'],
            s3_endpoint=s3_endpoint
        )
        print(f"  ✅ Kafka message sent")
```

### 3. Update Processing Phase

**File:** `/scripts/e2e_validator/phases/processing.py`

Skip the polling trigger for OCP (already triggered by Kafka):

```python
def trigger_processing(self, provider_type='AWS'):
    if provider_type == 'OCP':
        print("\n📨 OCP processing triggered via Kafka message (not polling)")
        return {'success': True, 'method': 'kafka'}

    # Existing polling trigger for AWS/Azure/GCP
    # ...
```

---

## Testing Strategy

### Unit Test: Kafka Message Format
```python
def test_kafka_message_format():
    """Verify Kafka message matches expected schema"""
    kafka_client = KafkaProducerClient('localhost:9092')
    message = kafka_client.build_ocp_message(...)

    assert message['service'] == 'hccm'
    assert message['provider_type'] == 'OCP'
    assert len(message['files']) == 2
    assert all('report_type' in f for f in message['files'])
```

### Integration Test: E2E with Kafka
```bash
# Run OCP smoke test
./scripts/ocp-e2e-validate.sh --smoke-test --force --timeout 600

# Expected: Processing completes within 60-120 seconds
# - 2 manifests created (pod_usage, storage_usage)
# - Parquet files in S3
# - Trino tables created
# - PostgreSQL summaries populated
```

---

## Success Criteria

- [ ] Kafka producer client implemented
- [ ] Data upload phase sends Kafka messages for OCP
- [ ] Processing phase recognizes OCP as Kafka-driven
- [ ] Manifests are created within 30 seconds of Kafka message
- [ ] Parquet conversion completes successfully
- [ ] Trino tables are created (openshift_pod_usage_line_items, openshift_storage_usage_line_items)
- [ ] PostgreSQL summary tables are populated
- [ ] E2E test passes within 2 minutes

---

## Summary

**OCP E2E testing requires Kafka integration** - this is not optional. The current approach of uploading to S3 and resetting timestamps will never work for OCP because MASU's OCP processing path is exclusively Kafka-driven.

This architectural difference exists because:
1. OCP reports come from an operator running inside the cluster, not from customer S3
2. The operator announces reports via Kafka, not via S3 bucket notifications
3. MASU's download logic for OCP expects Kafka message metadata to find the files

**Without Kafka messages, OCP providers are essentially invisible to MASU.**

