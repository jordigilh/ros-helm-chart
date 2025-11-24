# Kafka Integration for Cost Management On-Prem

## Overview

This document describes the Kafka-based event-driven processing architecture for Cost Management on-prem deployments. This approach eliminates the reliability issues associated with Celery chords by routing all provider types through Kafka.

## Architecture

### Traditional SaaS Approach (Mixed)

**OCP Workloads:**
```
koku-metrics-operator → insights-ingress → Kafka → Listener → Processing → ✅ Reliable
```

**Cloud Providers (AWS/Azure/GCP):**
```
Orchestrator → Polls S3/Azure/GCS → Creates Chord → ❌ Unreliable callback
```

### On-Prem Approach (Kafka for All)

**All Providers (OCP, AWS, Azure, GCP):**
```
Orchestrator → Discovers files → Publishes to Kafka → Listener → Processing → ✅ Reliable
```

## Why Kafka?

The Kafka listener pattern provides several advantages:

1. **Event-Driven**: No dependency on Celery chord callbacks
2. **Stateless**: Manifest completion check happens synchronously after file processing
3. **Reliable**: Kafka provides message persistence and replay
4. **Observable**: Messages in Kafka topic show processing flow
5. **Unified**: Single code path for all provider types

## Component Architecture

### 1. Kafka Cluster

**Deployment**: Strimzi operator in `kafka` namespace

```yaml
# Already deployed via Strimzi
Namespace: kafka
Pods:
  - ros-ocp-kafka-kafka-0
  - ros-ocp-kafka-kafka-1
  - ros-ocp-kafka-kafka-2
Service: ros-ocp-kafka-kafka-bootstrap:9092
```

### 2. Kafka Listener

**Deployment**: `koku-listener` pod in `cost-mgmt` namespace

```yaml
Template: cost-management-onprem/templates/cost-management/masu/deployment-listener.yaml
Command: python manage.py listener
Environment:
  - KAFKA_CONNECT: "true"
  - INSIGHTS_KAFKA_HOST: ros-ocp-kafka-kafka-bootstrap.kafka.svc.cluster.local
  - INSIGHTS_KAFKA_PORT: "9092"
  - KAFKA_CONSUMER_GROUP_ID: cost-mgmt-listener-group
```

**Responsibilities:**
- Consume messages from `platform.upload.announce` topic
- Download report files (if not already local)
- Process files (convert to parquet)
- Check if manifest is complete
- Trigger summary tables if all files processed

### 3. Orchestrator (Modified)

**Current Behavior** (Chord-based):
```python
# orchestrator.py:388
async_id = chord(report_tasks, group(summary_task, hcs_task, subs_task))()
```

**Proposed Behavior** (Kafka-based):
```python
# Publish message to Kafka instead of creating chord
kafka_producer.produce(
    topic='platform.upload.announce',
    value=json.dumps({
        'provider_uuid': provider_uuid,
        'provider_type': provider_type,
        'manifest_id': manifest_id,
        'files': report_files,
        'schema': schema_name,
        ...
    })
)
```

## Message Format

### Cloud Provider Report Message

```json
{
  "request_id": "uuid",
  "provider_uuid": "uuid",
  "provider_type": "AWS|Azure|GCP",
  "schema": "org1234567",
  "manifest_id": 123,
  "assembly_id": "assembly-uuid",
  "files": [
    {
      "file": "/path/to/report.csv",
      "manifest_id": 123,
      "provider_uuid": "uuid",
      "start_date": "2024-01-01",
      "end_date": "2024-02-01"
    }
  ],
  "service": "cost-mgmt"
}
```

### OCP Report Message (Existing)

```json
{
  "request_id": "uuid",
  "b64_identity": "base64-encoded-identity",
  "url": "https://insights-upload/payload.tar.gz",
  "account": "account-id",
  "org_id": "org-id",
  "service": "hccm"
}
```

## Listener Processing Flow

```python
def process_messages(msg):
    """
    Process messages and send validation status.

    Processing involves:
    1. Extract message payload
    2. Download files (if needed)
    3. Process each file (convert to parquet)
    4. Check if all files for manifest are complete
    5. If complete, mark manifest and trigger summary
    """

    value = json.loads(msg.value().decode("utf-8"))
    provider_type = value.get("provider_type")

    if provider_type == "OCP":
        # Existing OCP flow (download from insights-ingress)
        report_metas, manifest_uuid = extract_payload(value["url"], ...)
    else:
        # New cloud provider flow (files already on disk from orchestrator)
        report_metas = value.get("files", [])

    # Process all files
    for report_meta in report_metas:
        report_meta["process_complete"] = process_report(request_id, report_meta)

    # Check if ALL files complete
    process_complete = report_metas_complete(report_metas)

    # If complete, trigger summary
    if process_complete:
        summarize_manifest(report_meta, tracing_id)

    # Commit message
    consumer.commit()
```

## Configuration

### Helm Values

```yaml
# cost-management-onprem/values-koku.yaml

costManagement:
  # Enable Kafka listener
  listener:
    enabled: true
    replicas: 1
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 500m
        memory: 1Gi
    env:
      KOKU_LOG_LEVEL: INFO
      DJANGO_LOG_LEVEL: INFO

  # Kafka configuration
  kafka:
    enabled: true
    host: ros-ocp-kafka-kafka-bootstrap.kafka.svc.cluster.local
    port: 9092
    consumerGroupId: cost-mgmt-listener-group
    topic: platform.upload.announce
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KAFKA_CONNECT` | Enable Kafka connectivity | `true` |
| `INSIGHTS_KAFKA_HOST` | Kafka bootstrap server host | `ros-ocp-kafka-kafka-bootstrap.kafka.svc.cluster.local` |
| `INSIGHTS_KAFKA_PORT` | Kafka bootstrap server port | `9092` |
| `KAFKA_CONSUMER_GROUP_ID` | Consumer group ID | `cost-mgmt-listener-group` |
| `KAFKA_TOPIC` | Topic to consume | `platform.upload.announce` |

## Deployment

### Prerequisites

1. ✅ Kafka cluster deployed (Strimzi in `kafka` namespace)
2. ✅ Kafka topic `platform.upload.announce` exists
3. ✅ Network policy allows cost-mgmt → kafka communication

### Deploy Listener

```bash
# Update Helm values to enable listener
helm upgrade cost-mgmt ./cost-management-onprem \
  -f cost-management-onprem/values-koku.yaml \
  -n cost-mgmt

# Verify listener pod
kubectl get pods -n cost-mgmt | grep listener
kubectl logs -n cost-mgmt deployment/koku-listener --tail=50

# Look for:
# "Kafka is running."
# "Consumer is listening for messages..."
```

### Verify Connectivity

```bash
# Check Kafka connection from listener pod
kubectl exec -n cost-mgmt deployment/koku-listener -- \
  python -c "from kafka_utils.utils import is_kafka_connected; print(is_kafka_connected())"

# Expected output: True
```

## E2E Validation

The E2E test suite includes Kafka validation as Phase 2.5:

```bash
cd /Users/jgil/go/src/github.com/insights-onprem/ros-helm-chart/scripts
python3 -m e2e_validator.cli --namespace cost-mgmt
```

**Validation checks:**
1. ✅ Kafka cluster is healthy (3 pods running)
2. ✅ Listener pod is deployed and ready
3. ✅ Listener can connect to Kafka
4. ✅ Required topic `platform.upload.announce` exists

## Monitoring

### Metrics

```python
# Prometheus metrics exposed by listener
kafka_consumer_messages_processed_total
kafka_consumer_messages_failed_total
kafka_consumer_lag_seconds
manifest_completion_check_total
manifest_completion_success_total
```

### Logs

```bash
# Listener logs
kubectl logs -n cost-mgmt deployment/koku-listener -f

# Look for:
# INFO Kafka is running
# INFO Consumer is listening for messages...
# INFO Processing message offset: 123 partition: 0
# INFO Processing: report.csv complete.
# INFO marked manifest complete via synchronous check
# INFO Summarization celery uuid: task-uuid
```

### Alerts

```yaml
- alert: KafkaListenerDown
  expr: up{job="koku-listener"} == 0
  for: 5m
  annotations:
    summary: "Kafka listener pod is down"

- alert: KafkaConsumerLag
  expr: kafka_consumer_lag_seconds > 300
  for: 10m
  annotations:
    summary: "Kafka consumer lag exceeds 5 minutes"
```

## Troubleshooting

### Listener Not Starting

**Symptom**: Pod in `CrashLoopBackOff`

**Check**:
```bash
kubectl logs -n cost-mgmt deployment/koku-listener
```

**Common Causes**:
- Kafka not reachable: Check network policy
- Topic doesn't exist: Create topic manually
- Credentials issue: Verify SASL config

### Messages Not Processing

**Symptom**: Messages in topic but not processed

**Check consumer group lag**:
```bash
kubectl exec -n kafka ros-ocp-kafka-kafka-0 -- \
  bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --group cost-mgmt-listener-group \
  --describe
```

**Look for**:
- High lag: Consumer too slow, scale replicas
- No offset: Consumer not connected to group

### Manifests Not Completing

**Symptom**: Files processed but manifest not marked complete

**Check listener logic**:
```bash
# Look for "marked manifest complete" in logs
kubectl logs -n cost-mgmt deployment/koku-listener | grep "manifest complete"
```

**Manual fix** (if needed):
```sql
UPDATE reporting_common_costusagereportmanifest
SET completed_datetime = NOW()
WHERE id IN (
  SELECT manifest_id
  FROM reporting_common_costusagereportstatus
  WHERE status = 1
  GROUP BY manifest_id
  HAVING COUNT(*) = (
    SELECT num_total_files
    FROM reporting_common_costusagereportmanifest m
    WHERE m.id = manifest_id
  )
);
```

## Migration Path

### Phase 1: Deploy Listener (Current)

- ✅ Deploy `koku-listener` pod
- ✅ Configure Kafka connectivity
- ✅ Validate with E2E tests
- ⚠️ Orchestrator still uses chords (listener sits idle for cloud providers)

### Phase 2: Modify Orchestrator (Next PR)

- 🔨 Update `orchestrator.py` to publish to Kafka instead of creating chords
- 🔨 Remove chord creation logic
- 🔨 Test with all provider types

### Phase 3: Remove Chord Dependencies (Future)

- 🔨 Remove chord-related code
- 🔨 Simplify Celery configuration
- 🔨 Update monitoring for Kafka-based flow

## References

- **SaaS OCP Flow**: `koku/masu/external/kafka_msg_handler.py`
- **Listener Command**: `koku/masu/management/commands/listener.py`
- **Kafka Utils**: `koku/kafka_utils/utils.py`
- **Orchestrator**: `koku/masu/processor/orchestrator.py`
- **E2E Validation**: `scripts/e2e_validator/phases/kafka_validation.py`

## Summary

The Kafka integration provides a reliable, event-driven alternative to Celery chords for manifest completion. By routing all provider types through Kafka, we achieve:

- ✅ **Unified architecture** (single code path)
- ✅ **Improved reliability** (no chord callback failures)
- ✅ **Better observability** (Kafka topic shows processing flow)
- ✅ **Graceful degradation** (orchestrator fallback if Kafka unavailable)
- ✅ **SaaS alignment** (same pattern as OCP in production)

The listener is now deployed and validated. The next step is to modify the orchestrator to publish cloud provider reports to Kafka, completing the transition to event-driven processing.

