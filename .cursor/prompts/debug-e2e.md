# Debug E2E Test Failures

Step-by-step debugging for end-to-end test failures.

## Prerequisites

Provide:
1. **Which test failed**: e.g., `test_06_summary_tables_populated`
2. **Error message**: The assertion or exception
3. **Cluster namespace**: e.g., `cost-onprem`

## Test-Specific Debugging

### test_01_source_registered
**What it does**: Registers an OCP source via Koku's Sources API endpoints

```bash
# Check Koku API is running (Sources API is now integrated in Koku)
kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=cost-management-api-writes

# Check listener can reach Koku API
kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=listener --tail=50 | grep -i source
```

### test_02_provider_created
**What it does**: Verifies Kafka message created provider in Koku DB

```bash
# Check Kafka is running
kubectl get pods -n ${NAMESPACE} | grep kafka

# Check listener logs for Kafka consumption
kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=listener --tail=50 | grep -i kafka
```

### test_03_upload_data_via_ingress
**What it does**: Uploads test CSV via JWT-authenticated ingress

```bash
# Check ingress is running
kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=ingress
kubectl get routes -n ${NAMESPACE}

# Check ingress logs
kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=ingress --tail=50
```

### test_04_data_received_by_listener
**What it does**: Verifies listener received the upload

```bash
# Check listener logs for upload processing
kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=listener --tail=100 | grep -i "upload\|received\|processing"
```

### test_05_manifest_processed
**What it does**: Verifies manifest status in database

```bash
# Check database for manifest records
DB_POD=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=database -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ${NAMESPACE} ${DB_POD} -- psql -U postgres -d koku -c "SELECT * FROM reporting_common_costusagereportmanifest ORDER BY id DESC LIMIT 5;"
```

### test_06_summary_tables_populated (EXTENDED)
**What it does**: Verifies Koku populated summary tables

```bash
# Check for summary processing in listener logs
kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=listener --tail=200 | grep -i "summary\|start\|end"

# Check database for summary data
DB_POD=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=database -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ${NAMESPACE} ${DB_POD} -- psql -U postgres -d koku -c "SELECT COUNT(*) FROM reporting_ocpusagelineitem_daily_summary;"
```

**Common issue**: Missing `start`/`end` dates in manifest.json

### test_07_kruize_experiments_created (EXTENDED)
**What it does**: Verifies ROS processor created Kruize experiments

```bash
# Check ROS processor logs
kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=ros-processor --tail=100

# Look for TLS or S3 errors
kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=ros-processor | grep -i "error\|x509\|signature\|csv"

# Check Kruize experiments
KRUIZE_POD=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=ros-optimization -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ${NAMESPACE} ${KRUIZE_POD} -- curl -s http://localhost:8080/listExperiments | head -100
```

**Common issues**:
- TLS certificate errors (x509)
- S3 SignatureDoesNotMatch
- Wrong data format (need `--ros-ocp-info` flag for NISE)

### test_08_recommendations_generated (EXTENDED)
**What it does**: Verifies Kruize generated recommendations

```bash
# Check Kruize for recommendations
KRUIZE_POD=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/component=ros-optimization -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ${NAMESPACE} ${KRUIZE_POD} -- curl -s http://localhost:8080/listRecommendations | head -100
```

**Note**: Kruize typically needs multiple data uploads over time to generate recommendations.

## General Debugging

```bash
# All pod statuses
kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/instance=cost-onprem

# Recent events
kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' | tail -30

# Describe failing pod
kubectl describe pod -n ${NAMESPACE} <pod-name>
```
