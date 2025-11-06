# Ingress Component Clarification

## Critical Update: Use Platform-Wide Ingress

**Component**: [`insights-ingress-go`](https://github.com/insights-onprem/insights-ingress-go)
**NOT**: `insights-ros-ingress` (ROS-specific, deprecated for shared infrastructure)

---

## Why insights-ingress-go?

### 1. **Platform-Wide Service**
`insights-ingress-go` is the official Red Hat Insights platform ingress service, designed to handle uploads from multiple services:

```
Client → 3Scale → insights-ingress-go → Cloud Storage + Kafka
                                      ↓
                              platform.upload.announce
                                      ↓
                          ┌────────────┴────────────┐
                          ↓                         ↓
                      ROS Services            Koku Services
```

### 2. **Content-Type Based Routing**
The service routes uploads based on content type:

```
Content-Type: application/vnd.redhat.advisor.report+tgz
  → Kafka Header: {"service": "advisor"}

Content-Type: application/vnd.redhat.cost-management.report+tgz
  → Kafka Header: {"service": "cost-management"}

Content-Type: application/vnd.redhat.ros.optimization+tgz
  → Kafka Header: {"service": "ros"}
```

### 3. **Multi-Service Support**
Perfect for infrastructure chart serving multiple applications:
- ✅ ROS uploads
- ✅ Koku/Cost Management uploads
- ✅ Future services (just add content type)

---

## Architecture from insights-ingress-go

### Workflow
```
┌─────────────────────────────────────────────────────────────────┐
│  Client (Insights Agent, Tower, etc.)                           │
│  - Sends payload with content type                              │
│  - Example: application/vnd.redhat.advisor.report+tgz           │
└────────────────────────┬────────────────────────────────────────┘
                         │ HTTPS POST with x-rh-identity header
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│  3Scale Gateway (Authentication)                                │
│  - Validates identity                                           │
│  - Adds x-rh-insights-request-id (UUID)                         │
│  - Routes to ingress                                            │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│  insights-ingress-go                                            │
│                                                                 │
│  1. Receives upload                                             │
│  2. Extracts service name from content-type                     │
│  3. Uploads file to Cloud Storage (S3/MinIO)                    │
│  4. Publishes message to Kafka topic: platform.upload.announce │
│     - Message includes service header for filtering            │
│     - Message includes download URL                            │
│                                                                 │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│  Kafka Topic: platform.upload.announce                          │
│                                                                 │
│  Message Format:                                                │
│  {                                                              │
│    "account": "0000001",                                        │
│    "org_id": "000001",                                          │
│    "content_type": "application/vnd.redhat.advisor.report+tgz", │
│    "request_id": "uuid",                                        │
│    "service": "advisor",                                        │
│    "size": 12345,                                               │
│    "url": "s3://bucket/path/to/file.tar.gz",                   │
│    "b64_identity": "base64-encoded-identity",                   │
│    "timestamp": "2025-11-06T12:00:00Z"                          │
│  }                                                              │
│                                                                 │
│  Headers:                                                       │
│  - service: "advisor" (or "cost-management", "ros", etc.)       │
│                                                                 │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ↓
┌─────────────────────────────────────────────────────────────────┐
│  Service Consumers (Filter by service header)                   │
│                                                                 │
│  ┌───────────────────────┐  ┌───────────────────────────────┐  │
│  │  ROS Services         │  │  Koku Services                │  │
│  │  - Filter: ros        │  │  - Filter: cost-management    │  │
│  │  - Process uploads    │  │  - Process uploads            │  │
│  └───────────────────────┘  └───────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Message Flow Details

**1. Upload Announcement**
```
Topic: platform.upload.announce
Header: {"service": "cost-management"}
Body: {
  "org_id": "000001",
  "content_type": "application/vnd.redhat.cost-management.cost-report+tgz",
  "url": "s3://koku-data/reports/2025/11/06/report.tar.gz",
  ...
}
```

**2. Validation Response** (Optional)
```
Topic: platform.upload.validation
Body: {
  ...all data from announcement...
  "validation": "success" | "failure",
  "reason": "Error message if failed",
  "reporter": "cost-management-validator"
}
```

---

## Infrastructure Chart Configuration

### Ingress Deployment

```yaml
# platform-infrastructure/values.yaml

ingress:
  enabled: true

  # Use insights-ingress-go, not insights-ros-ingress
  image:
    repository: quay.io/cloudservices/insights-ingress-go
    tag: "latest"  # Replace with specific version

  replicas: 2

  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi

  # Environment configuration
  env:
    # Storage backend (MinIO in our case)
    INGRESS_STAGEBUCKET: "platform-uploads-stage"
    INGRESS_REJECTBUCKET: "platform-uploads-rejected"
    INGRESS_BUCKET: "platform-uploads"

    # Kafka configuration
    INGRESS_KAFKA_BROKERS: "ros-ocp-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092"
    INGRESS_KAFKA_TOPIC: "platform.upload.announce"

    # Valid upload types (content-type service names)
    INGRESS_VALID_UPLOAD_TYPES: "advisor,cost-management,ros,openshift"

    # Storage endpoint
    INGRESS_STORAGE_ENDPOINT: "http://minio.platform-infra.svc.cluster.local:9000"
    INGRESS_STORAGE_ACCESS_KEY: "minioadmin"
    INGRESS_STORAGE_SECRET_KEY: "minioadmin"

    # Logging
    INGRESS_LOG_LEVEL: "INFO"

    # Maximum upload size (in bytes)
    INGRESS_MAX_SIZE: "10737418240"  # 10GB

  service:
    type: ClusterIP
    port: 8080
    targetPort: 8080

  # Health checks
  livenessProbe:
    httpGet:
      path: /api/ingress/v1/version
      port: 8080
    initialDelaySeconds: 10
    periodSeconds: 30

  readinessProbe:
    httpGet:
      path: /api/ingress/v1/version
      port: 8080
    initialDelaySeconds: 5
    periodSeconds: 10
```

### Example Deployment Template

```yaml
# platform-infrastructure/templates/deployment-ingress.yaml
{{- if .Values.ingress.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: insights-ingress
  namespace: {{ .Release.Namespace }}
  labels:
    app: insights-ingress
    component: platform-infrastructure
spec:
  replicas: {{ .Values.ingress.replicas }}
  selector:
    matchLabels:
      app: insights-ingress
  template:
    metadata:
      labels:
        app: insights-ingress
    spec:
      containers:
      - name: ingress
        image: "{{ .Values.ingress.image.repository }}:{{ .Values.ingress.image.tag }}"
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: INGRESS_STAGEBUCKET
          value: {{ .Values.ingress.env.INGRESS_STAGEBUCKET }}
        - name: INGRESS_REJECTBUCKET
          value: {{ .Values.ingress.env.INGRESS_REJECTBUCKET }}
        - name: INGRESS_BUCKET
          value: {{ .Values.ingress.env.INGRESS_BUCKET }}
        - name: INGRESS_KAFKA_BROKERS
          value: {{ .Values.ingress.env.INGRESS_KAFKA_BROKERS }}
        - name: INGRESS_KAFKA_TOPIC
          value: {{ .Values.ingress.env.INGRESS_KAFKA_TOPIC }}
        - name: INGRESS_VALID_UPLOAD_TYPES
          value: {{ .Values.ingress.env.INGRESS_VALID_UPLOAD_TYPES }}
        - name: INGRESS_STORAGE_ENDPOINT
          value: {{ .Values.ingress.env.INGRESS_STORAGE_ENDPOINT }}
        - name: INGRESS_STORAGE_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: accessKey
        - name: INGRESS_STORAGE_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: secretKey
        - name: INGRESS_LOG_LEVEL
          value: {{ .Values.ingress.env.INGRESS_LOG_LEVEL }}
        - name: INGRESS_MAX_SIZE
          value: {{ .Values.ingress.env.INGRESS_MAX_SIZE | quote }}
        resources:
          {{- toYaml .Values.ingress.resources | nindent 10 }}
        livenessProbe:
          {{- toYaml .Values.ingress.livenessProbe | nindent 10 }}
        readinessProbe:
          {{- toYaml .Values.ingress.readinessProbe | nindent 10 }}
{{- end }}
```

---

## ROS Chart Updates

### Remove ROS-Specific Ingress

```bash
# Delete ROS-specific ingress deployment
rm ros-ocp/templates/deployment-ingress.yaml

# Or disable it via values
# ros-ocp/values.yaml
ingress:
  enabled: false  # Now using platform-infrastructure ingress
```

### Update ROS to Use Platform Ingress

```yaml
# ros-ocp/values.yaml

externalServices:
  # ... postgresql, redis, minio ...

  ingress:
    host: insights-ingress.platform-infra.svc.cluster.local
    port: 8080
    endpoint: "http://insights-ingress.platform-infra.svc.cluster.local:8080"
```

---

## Koku Chart Configuration

### Use Platform Ingress

```yaml
# koku-chart/values.yaml

externalServices:
  # ... postgresql, redis, minio ...

  ingress:
    host: insights-ingress.platform-infra.svc.cluster.local
    port: 8080
    endpoint: "http://insights-ingress.platform-infra.svc.cluster.local:8080"
```

### Koku Content Types

Koku should use these content types for uploads:

```
application/vnd.redhat.cost-management.cost-report+tgz
application/vnd.redhat.cost-management.aws-billing+tgz
application/vnd.redhat.cost-management.azure-billing+tgz
application/vnd.redhat.cost-management.gcp-billing+tgz
application/vnd.redhat.cost-management.openshift-usage+tgz
```

---

## Testing Platform Ingress

### Test 1: Version Check
```bash
# Test ingress is running
kubectl exec -n platform-infra deployment/insights-ingress -- \
  curl localhost:8080/api/ingress/v1/version
```

### Test 2: Upload (ROS)
```bash
# Create test file
echo "test data" > test.tar.gz

# Upload with ROS content type
curl -F "file=@test.tar.gz;type=application/vnd.redhat.ros.optimization+tgz" \
  -H "x-rh-identity: eyJpZGVudGl0eSI6IHsidHlwZSI6ICJVc2VyIiwgImFjY291bnRfbnVtYmVyIjogIjAwMDAwMDEiLCAib3JnX2lkIjogIjAwMDAwMSIsICJpbnRlcm5hbCI6IHsib3JnX2lkIjogIjAwMDAwMSJ9fX0=" \
  -H "x-rh-insights-request-id: $(uuidgen)" \
  http://insights-ingress.platform-infra.svc.cluster.local:8080/api/ingress/v1/upload
```

### Test 3: Upload (Koku)
```bash
# Upload with Koku content type
curl -F "file=@test.tar.gz;type=application/vnd.redhat.cost-management.cost-report+tgz" \
  -H "x-rh-identity: eyJpZGVudGl0eSI6IHsidHlwZSI6ICJVc2VyIiwgImFjY291bnRfbnVtYmVyIjogIjAwMDAwMDEiLCAib3JnX2lkIjogIjAwMDAwMSIsICJpbnRlcm5hbCI6IHsib3JnX2lkIjogIjAwMDAwMSJ9fX0=" \
  -H "x-rh-insights-request-id: $(uuidgen)" \
  http://insights-ingress.platform-infra.svc.cluster.local:8080/api/ingress/v1/upload
```

### Test 4: Verify Kafka Messages
```bash
# Check that message was published to Kafka
kubectl exec -n kafka ros-ocp-kafka-kafka-0 -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic platform.upload.announce \
  --from-beginning \
  --max-messages 1
```

---

## Migration from insights-ros-ingress

### Step 1: Deploy Platform Ingress
```bash
# Deploy infrastructure chart with insights-ingress-go
helm install platform-infra platform-infrastructure/ \
  --namespace platform-infra \
  --create-namespace
```

### Step 2: Update ROS Chart
```bash
# Update ROS values to disable local ingress
helm upgrade ros ros-ocp/ \
  --set ingress.enabled=false \
  --set externalServices.ingress.host=insights-ingress.platform-infra.svc.cluster.local
```

### Step 3: Verify Traffic
```bash
# Check that ROS can reach platform ingress
kubectl exec -n ros-ocp deployment/rosocp-api -- \
  curl insights-ingress.platform-infra.svc.cluster.local:8080/api/ingress/v1/version
```

### Step 4: Remove Old Ingress
```bash
# If old insights-ros-ingress deployment exists
kubectl delete deployment insights-ros-ingress -n ros-ocp
```

---

## Benefits of Platform-Wide Ingress

### 1. **Single Point of Entry**
- One ingress for all services
- Consistent upload handling
- Unified monitoring and logging

### 2. **Content-Type Routing**
- Automatic service discovery via content-type
- No manual routing configuration needed
- Easy to add new services

### 3. **Kafka Integration**
- Standardized message format
- Service filtering via Kafka headers
- Platform-wide upload tracking

### 4. **Shared Infrastructure**
- One ingress deployment
- Lower resource usage
- Simpler operations

### 5. **Multi-Tenant Ready**
- Org ID based isolation
- Account-based access control
- Shared by multiple applications

---

## Summary

### ✅ DO: Use insights-ingress-go
- Platform-wide service
- Content-type based routing
- Kafka integration
- Multi-service support

### ❌ DON'T: Use insights-ros-ingress
- ROS-specific (not suitable for shared infrastructure)
- Doesn't support multiple services
- Not designed for platform-wide use

### Action Items

1. **Infrastructure Chart**:
   - Include `insights-ingress-go` deployment
   - Configure for MinIO + Kafka
   - Set valid upload types: ros, cost-management, advisor, openshift

2. **ROS Chart**:
   - Remove `insights-ros-ingress` deployment
   - Reference platform ingress via externalServices

3. **Koku Chart**:
   - Reference platform ingress via externalServices
   - Configure cost-management content types

---

**References**:
- [insights-ingress-go GitHub](https://github.com/insights-onprem/insights-ingress-go)
- [Platform Upload Topic Documentation](https://github.com/insights-onprem/insights-ingress-go#announcement-topic)
- [Content Type Format](https://github.com/insights-onprem/insights-ingress-go#content-type)

**Document Version**: 1.0
**Date**: November 6, 2025
**Status**: ✅ **CRITICAL UPDATE - Must Use insights-ingress-go**

