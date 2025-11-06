# Koku Migration to Helm Chart - Implementation Guide

**Date**: November 6, 2025
**Purpose**: Practical guide to add Koku API and Trino components to the existing ROS Helm chart

## Current State

The helm chart currently contains:
- ✅ ROS-OCP services (API, processor, recommendation poller, housekeeper)
- ✅ Supporting infrastructure (PostgreSQL, Kafka, Redis/Valkey, MinIO/ODF)
- ✅ Kruize, Sources API, Ingress
- ❌ **Missing**: Koku API deployments, Trino, Celery workers

## Migration Goal

Add the Koku-specific components from the ClowdApp to complete the cost management platform:

1. **Koku API Deployments** (api-reads, api-writes)
2. **Trino** (query engine)
3. **Celery Worker Pools** (background processing)
4. **Celery Beat** (task scheduler)
5. **Koku-specific configuration** (environment variables, secrets)

---

## Phase 1: Add Koku API Deployments

### 1.1 Add Koku Configuration to values.yaml

```yaml
# Koku Cost Management API
koku:
  # Koku API image (from ClowdApp)
  image:
    repository: quay.io/cloudservices/koku  # Same as ClowdApp IMAGE parameter
    tag: "latest"  # Use IMAGE_TAG from ClowdApp
    pullPolicy: Always

  # API Reads deployment (read-only queries)
  apiReads:
    enabled: true
    replicas: 3
    port: 8000
    pathPrefix: "/api/cost-management"

    # Gunicorn configuration
    gunicorn:
      workers: 4  # Auto-calculated based on CPU if not set
      threads: 4
      logLevel: "info"

    # Resource configuration
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 1000m
        memory: 3Gi

    # Database connection (read replica)
    database:
      useReadReplica: true  # Route to read replica
      poolSize: 10
      maxOverflow: 20

  # API Writes deployment (mutations and updates)
  apiWrites:
    enabled: true
    replicas: 2
    port: 8000
    pathPrefix: "/api/cost-management"

    # Gunicorn configuration
    gunicorn:
      workers: 4
      threads: 4
      logLevel: "info"

    # Resource configuration
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 1000m
        memory: 2Gi

    # Database connection (primary)
    database:
      useReadReplica: false  # Route to primary
      poolSize: 10
      maxOverflow: 20

  # Common Koku environment configuration
  env:
    clowderEnabled: false
    apiPathPrefix: "/api/cost-management/v1"
    appDomain: "console.redhat.com"
    development: false
    djangoSecretKey: ""  # From secret
    djangoLogLevel: "INFO"
    djangoLogFormatter: "json"
    djangoLogHandlers: "console"
    kokuLogLevel: "INFO"
    unleashLogLevel: "WARNING"
    rbacServicePath: "/api/rbac/v1/access/"
    rbacCacheTtl: "30"
    prometheusMultiprocDir: "/tmp/prometheus"
    retainNumMonths: "3"
    notificationCheckTime: "00:00:00"
    enableSentry: false
    sentryEnvironment: "production"
    demoAccounts: ""
    accountEnhancedMetrics: ""
    cachedViewsDisabled: "False"
    qeSchema: ""
    enhancedOrgAdmin: "False"
    tagEnabledLimit: "200"

  # Django secret key (generate with: python -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())')
  djangoSecretKey: ""  # Override in deployment
```

### 1.2 Create Koku API-Reads Deployment

**File**: `ros-ocp/templates/deployment-koku-api-reads.yaml`

```yaml
{{- if .Values.koku.apiReads.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "ros-ocp.fullname" . }}-koku-api-reads
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "ros-ocp.labels" . | nindent 4 }}
    app.kubernetes.io/component: koku-api-reads
    app.kubernetes.io/name: koku-api-reads
spec:
  replicas: {{ .Values.koku.apiReads.replicas }}
  selector:
    matchLabels:
      {{- include "ros-ocp.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: koku-api-reads
      app.kubernetes.io/name: koku-api-reads
  template:
    metadata:
      labels:
        {{- include "ros-ocp.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: koku-api-reads
        app.kubernetes.io/name: koku-api-reads
    spec:
      serviceAccountName: {{ include "ros-ocp.serviceAccountName" . }}
      {{- with .Values.global.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}

      initContainers:
        # Wait for database
        - name: wait-for-db
          image: "{{ .Values.global.initContainers.waitFor.repository }}:{{ .Values.global.initContainers.waitFor.tag }}"
          command: ['bash', '-c']
          args:
            - |
              echo "Waiting for Koku database..."
              {{- if .Values.koku.apiReads.database.useReadReplica }}
              DB_HOST="{{ include "ros-ocp.fullname" . }}-db-koku-replica"
              {{- else }}
              DB_HOST="{{ include "ros-ocp.fullname" . }}-db-koku"
              {{- end }}
              until timeout 3 bash -c "echo > /dev/tcp/${DB_HOST}/5432" 2>/dev/null; do
                echo "Database not ready, retrying..."
                sleep 5
              done
              echo "Database ready"

      containers:
        - name: koku-api-reads
          image: "{{ .Values.koku.image.repository }}:{{ .Values.koku.image.tag }}"
          imagePullPolicy: {{ .Values.koku.image.pullPolicy }}

          command: ["/bin/bash"]
          args:
            - -c
            - |
              # Run migrations (read-only, safe to run multiple times)
              python manage.py migrate --noinput || echo "Migrations already applied"

              # Start Gunicorn with auto-calculated workers if not specified
              if [ -z "$GUNICORN_WORKERS" ]; then
                WORKERS=$((2 * $(nproc) + 1))
              else
                WORKERS=$GUNICORN_WORKERS
              fi

              exec gunicorn \
                --bind=0.0.0.0:{{ .Values.koku.apiReads.port }} \
                --workers=$WORKERS \
                --threads={{ .Values.koku.apiReads.gunicorn.threads }} \
                --timeout=90 \
                --log-level={{ .Values.koku.apiReads.gunicorn.logLevel }} \
                --access-logfile=- \
                --error-logfile=- \
                koku.wsgi:application

          ports:
            - name: http
              containerPort: {{ .Values.koku.apiReads.port }}
              protocol: TCP

          env:
            # Clowder
            - name: CLOWDER_ENABLED
              value: {{ .Values.koku.env.clowderEnabled | quote }}

            # Database configuration (read replica)
            - name: DATABASE_ENGINE
              value: "postgresql"
            - name: DATABASE_NAME
              value: {{ .Values.database.koku.name | quote }}
            - name: DATABASE_USER
              value: {{ .Values.database.koku.user | quote }}
            - name: DATABASE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "ros-ocp.fullname" . }}-db-credentials
                  key: koku-password
            {{- if .Values.koku.apiReads.database.useReadReplica }}
            - name: DATABASE_HOST
              value: {{ include "ros-ocp.fullname" . }}-db-koku-replica
            {{- else }}
            - name: DATABASE_HOST
              value: {{ include "ros-ocp.fullname" . }}-db-koku
            {{- end }}
            - name: DATABASE_PORT
              value: {{ .Values.database.koku.port | quote }}
            - name: DATABASE_SSLMODE
              value: {{ .Values.database.koku.sslMode | quote }}

            # Django configuration
            - name: DJANGO_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: {{ include "ros-ocp.fullname" . }}-koku-secret
                  key: django-secret-key
            - name: DJANGO_DEBUG
              value: "False"
            - name: DJANGO_LOG_LEVEL
              value: {{ .Values.koku.env.djangoLogLevel | quote }}
            - name: DJANGO_LOG_FORMATTER
              value: {{ .Values.koku.env.djangoLogFormatter | quote }}
            - name: DJANGO_LOG_HANDLERS
              value: {{ .Values.koku.env.djangoLogHandlers | quote }}

            # Koku configuration
            - name: KOKU_LOG_LEVEL
              value: {{ .Values.koku.env.kokuLogLevel | quote }}
            - name: API_PATH_PREFIX
              value: {{ .Values.koku.env.apiPathPrefix | quote }}
            - name: APP_DOMAIN
              value: {{ .Values.koku.env.appDomain | quote }}
            - name: DEVELOPMENT
              value: {{ .Values.koku.env.development | quote }}

            # Gunicorn
            - name: GUNICORN_WORKERS
              value: {{ .Values.koku.apiReads.gunicorn.workers | quote }}
            - name: GUNICORN_THREADS
              value: {{ .Values.koku.apiReads.gunicorn.threads | quote }}
            - name: GUNICORN_LOG_LEVEL
              value: {{ .Values.koku.apiReads.gunicorn.logLevel | quote }}

            # CPU limits (for auto-calculating workers)
            - name: POD_CPU_LIMIT
              valueFrom:
                resourceFieldRef:
                  containerName: koku-api-reads
                  resource: limits.cpu

            # Database pool configuration
            - name: DB_POOL_SIZE
              value: {{ .Values.koku.apiReads.database.poolSize | quote }}
            - name: DB_MAX_OVERFLOW
              value: {{ .Values.koku.apiReads.database.maxOverflow | quote }}

            # RBAC
            - name: RBAC_SERVICE_PATH
              value: {{ .Values.koku.env.rbacServicePath | quote }}
            - name: RBAC_CACHE_TTL
              value: {{ .Values.koku.env.rbacCacheTtl | quote }}

            # Kafka configuration
            - name: KAFKA_BOOTSTRAP_SERVERS
              value: {{ include "ros-ocp.kafkaBootstrapServers" . | quote }}
            - name: KAFKA_SECURITY_PROTOCOL
              value: {{ include "ros-ocp.kafkaSecurityProtocol" . | quote }}

            # Object storage (MinIO/ODF)
            - name: S3_BUCKET_NAME
              value: "koku-bucket"
            - name: S3_ENDPOINT
              {{- if eq (include "ros-ocp.isOpenShift" .) "true" }}
              value: "https://s3.openshift-storage.svc.cluster.local"
              {{- else }}
              value: "http://{{ include "ros-ocp.fullname" . }}-minio:9000"
              {{- end }}
            - name: S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: {{ include "ros-ocp.fullname" . }}-storage-credentials
                  key: access-key
            - name: S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: {{ include "ros-ocp.fullname" . }}-storage-credentials
                  key: secret-key

            # Redis/Celery
            - name: REDIS_HOST
              {{- if eq (include "ros-ocp.isOpenShift" .) "true" }}
              value: {{ include "ros-ocp.fullname" . }}-valkey
              {{- else }}
              value: {{ include "ros-ocp.fullname" . }}-redis
              {{- end }}
            - name: REDIS_PORT
              value: "6379"

            # Prometheus
            - name: PROMETHEUS_MULTIPROC_DIR
              value: {{ .Values.koku.env.prometheusMultiprocDir | quote }}

            # Sentry (optional)
            {{- if .Values.koku.env.enableSentry }}
            - name: KOKU_ENABLE_SENTRY
              value: "True"
            - name: KOKU_SENTRY_ENVIRONMENT
              value: {{ .Values.koku.env.sentryEnvironment | quote }}
            - name: KOKU_SENTRY_DSN
              valueFrom:
                secretKeyRef:
                  name: {{ include "ros-ocp.fullname" . }}-sentry-secret
                  key: dsn
                  optional: true
            {{- end }}

            # Other Koku settings
            - name: RETAIN_NUM_MONTHS
              value: {{ .Values.koku.env.retainNumMonths | quote }}
            - name: NOTIFICATION_CHECK_TIME
              value: {{ .Values.koku.env.notificationCheckTime | quote }}
            - name: CACHED_VIEWS_DISABLED
              value: {{ .Values.koku.env.cachedViewsDisabled | quote }}
            - name: TAG_ENABLED_LIMIT
              value: {{ .Values.koku.env.tagEnabledLimit | quote }}

          volumeMounts:
            # Temporary directory for Prometheus multiproc
            - name: tmp-prometheus
              mountPath: /tmp/prometheus
            # AWS credentials (if needed)
            {{- if .Values.koku.cloudProviders.aws.enabled }}
            - name: aws-credentials
              mountPath: /etc/aws
              readOnly: true
            {{- end }}
            # GCP credentials (if needed)
            {{- if .Values.koku.cloudProviders.gcp.enabled }}
            - name: gcp-credentials
              mountPath: /etc/gcp
              readOnly: true
            {{- end }}

          livenessProbe:
            httpGet:
              path: {{ .Values.koku.env.apiPathPrefix }}/status/
              port: {{ .Values.koku.apiReads.port }}
              scheme: HTTP
            initialDelaySeconds: 30
            periodSeconds: 20
            timeoutSeconds: 10
            failureThreshold: 5

          readinessProbe:
            httpGet:
              path: {{ .Values.koku.env.apiPathPrefix }}/status/
              port: {{ .Values.koku.apiReads.port }}
              scheme: HTTP
            initialDelaySeconds: 30
            periodSeconds: 20
            timeoutSeconds: 10
            failureThreshold: 5

          resources:
            {{- toYaml .Values.koku.apiReads.resources | nindent 12 }}

      volumes:
        # Temporary directories
        - name: tmp-prometheus
          emptyDir: {}

        # Cloud provider credentials
        {{- if .Values.koku.cloudProviders.aws.enabled }}
        - name: aws-credentials
          secret:
            secretName: {{ include "ros-ocp.fullname" . }}-aws-credentials
            items:
              - key: aws-credentials
                path: aws-credentials
        {{- end }}

        {{- if .Values.koku.cloudProviders.gcp.enabled }}
        - name: gcp-credentials
          secret:
            secretName: {{ include "ros-ocp.fullname" . }}-gcp-credentials
            items:
              - key: gcp-credentials
                path: gcp-credentials.json
        {{- end }}
{{- end }}
```

### 1.3 Create Koku API-Writes Deployment

**File**: `ros-ocp/templates/deployment-koku-api-writes.yaml`

Similar to api-reads but with:
- `useReadReplica: false` (connects to primary database)
- Lower replica count (2 instead of 3)
- Slightly different resource allocation

### 1.4 Create Koku Service

**File**: `ros-ocp/templates/service-koku-api.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "ros-ocp.fullname" . }}-koku-api
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "ros-ocp.labels" . | nindent 4 }}
    app.kubernetes.io/component: koku-api
spec:
  type: ClusterIP
  selector:
    # This service routes to BOTH api-reads and api-writes
    # Load balancer or ingress handles routing based on HTTP method
    app.kubernetes.io/instance: {{ .Release.Name }}
  ports:
    - port: 8000
      targetPort: http
      protocol: TCP
      name: http
```

### 1.5 Create Koku Secrets

**File**: `ros-ocp/templates/secret-koku-credentials.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "ros-ocp.fullname" . }}-koku-secret
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "ros-ocp.labels" . | nindent 4 }}
type: Opaque
stringData:
  # Django secret key - MUST be generated and provided
  django-secret-key: {{ .Values.koku.djangoSecretKey | required "koku.djangoSecretKey is required" | quote }}
```

---

## Phase 2: Add Trino Query Engine

### 2.1 Add Trino Configuration to values.yaml

```yaml
# Trino (query engine for cost data)
trino:
  enabled: true

  image:
    repository: trinodb/trino
    tag: "435"  # Match version from ClowdApp if specified
    pullPolicy: IfNotPresent

  coordinator:
    replicas: 1
    port: 8080

    jvm:
      maxHeapSize: "4G"
      heapHeadroom: "1G"

    resources:
      requests:
        cpu: 1000m
        memory: 6Gi
      limits:
        cpu: 2000m
        memory: 8Gi

  worker:
    replicas: 2
    port: 8080

    jvm:
      maxHeapSize: "4G"
      heapHeadroom: "1G"

    resources:
      requests:
        cpu: 1000m
        memory: 6Gi
      limits:
        cpu: 2000m
        memory: 8Gi

  # Trino catalog configuration
  catalogs:
    hive:
      enabled: true
      connector: "hive"
      metastoreUri: "thrift://{{ include \"ros-ocp.fullname\" . }}-hive-metastore:9083"
      s3Endpoint: ""  # Auto-configured based on platform
      s3AccessKey: ""  # From secret
      s3SecretKey: ""  # From secret
```

### 2.2 Create Trino Coordinator Deployment

**File**: `ros-ocp/templates/statefulset-trino-coordinator.yaml`

```yaml
{{- if .Values.trino.enabled }}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "ros-ocp.fullname" . }}-trino-coordinator
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "ros-ocp.labels" . | nindent 4 }}
    app.kubernetes.io/component: trino-coordinator
spec:
  serviceName: {{ include "ros-ocp.fullname" . }}-trino-coordinator
  replicas: {{ .Values.trino.coordinator.replicas }}
  selector:
    matchLabels:
      {{- include "ros-ocp.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: trino-coordinator
  template:
    metadata:
      labels:
        {{- include "ros-ocp.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: trino-coordinator
    spec:
      containers:
        - name: trino-coordinator
          image: "{{ .Values.trino.image.repository }}:{{ .Values.trino.image.tag }}"
          imagePullPolicy: {{ .Values.trino.image.pullPolicy }}

          ports:
            - name: http
              containerPort: {{ .Values.trino.coordinator.port }}
              protocol: TCP

          env:
            - name: TRINO_ENVIRONMENT
              value: "production"

          volumeMounts:
            - name: config
              mountPath: /etc/trino
            - name: catalog
              mountPath: /etc/trino/catalog
            - name: data
              mountPath: /data/trino

          resources:
            {{- toYaml .Values.trino.coordinator.resources | nindent 12 }}

          livenessProbe:
            httpGet:
              path: /v1/info
              port: {{ .Values.trino.coordinator.port }}
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 5

          readinessProbe:
            httpGet:
              path: /v1/info
              port: {{ .Values.trino.coordinator.port }}
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3

      volumes:
        - name: config
          configMap:
            name: {{ include "ros-ocp.fullname" . }}-trino-coordinator-config
        - name: catalog
          configMap:
            name: {{ include "ros-ocp.fullname" . }}-trino-catalog-config

  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ "ReadWriteOnce" ]
        {{- if .Values.global.storageClass }}
        storageClassName: {{ .Values.global.storageClass | quote }}
        {{- end }}
        resources:
          requests:
            storage: 50Gi
{{- end }}
```

### 2.3 Create Trino Worker Deployment

Similar to coordinator but:
- No query scheduler
- Different configuration (worker mode)
- Scalable replicas

### 2.4 Create Trino Configuration ConfigMaps

**File**: `ros-ocp/templates/configmap-trino-config.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "ros-ocp.fullname" . }}-trino-coordinator-config
  namespace: {{ .Release.Namespace }}
data:
  node.properties: |
    node.environment=production
    node.id={{ include "ros-ocp.fullname" . }}-coordinator
    node.data-dir=/data/trino

  jvm.config: |
    -server
    -Xmx{{ .Values.trino.coordinator.jvm.maxHeapSize }}
    -XX:+UseG1GC
    -XX:G1HeapRegionSize=32M
    -XX:+ExplicitGCInvokesConcurrent
    -XX:+HeapDumpOnOutOfMemoryError
    -XX:+ExitOnOutOfMemoryError
    -Djdk.attach.allowAttachSelf=true

  config.properties: |
    coordinator=true
    node-scheduler.include-coordinator=false
    http-server.http.port={{ .Values.trino.coordinator.port }}
    discovery.uri=http://localhost:{{ .Values.trino.coordinator.port }}
    query.max-memory={{ .Values.trino.coordinator.jvm.maxHeapSize }}
    query.max-memory-per-node={{ .Values.trino.coordinator.jvm.maxHeapSize }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "ros-ocp.fullname" . }}-trino-catalog-config
  namespace: {{ .Release.Namespace }}
data:
  hive.properties: |
    connector.name=hive
    hive.metastore.uri={{ .Values.trino.catalogs.hive.metastoreUri }}
    hive.s3.endpoint={{ .Values.trino.catalogs.hive.s3Endpoint }}
    hive.s3.aws-access-key={{ .Values.trino.catalogs.hive.s3AccessKey }}
    hive.s3.aws-secret-key={{ .Values.trino.catalogs.hive.s3SecretKey }}
    hive.s3.path-style-access=true
    hive.non-managed-table-writes-enabled=true
```

---

## Phase 3: Add Celery Workers

### 3.1 Add Celery Worker Configuration to values.yaml

```yaml
# Celery workers (background task processing)
celery:
  # Celery broker (Redis)
  broker:
    url: ""  # Auto-generated from Redis service

  # Result backend
  resultBackend:
    url: ""  # Auto-generated from PostgreSQL

  # Worker pools
  workers:
    # Default/Download worker
    download:
      enabled: true
      replicas: 2
      queue: "default"
      concurrency: 4
      resources:
        requests:
          cpu: 100m
          memory: 300Mi
        limits:
          cpu: 200m
          memory: 500Mi

    # Priority worker
    priority:
      enabled: true
      replicas: 2
      queue: "priority"
      concurrency: 4
      resources:
        requests:
          cpu: 150m
          memory: 500Mi
        limits:
          cpu: 300m
          memory: 750Mi

    # Priority XL worker (large tasks)
    priorityXl:
      enabled: true
      replicas: 2
      queue: "priority_xl"
      concurrency: 2
      resources:
        requests:
          cpu: 200m
          memory: 768Mi
        limits:
          cpu: 400m
          memory: 1Gi

    # Refresh worker
    refresh:
      enabled: true
      replicas: 2
      queue: "refresh"
      concurrency: 4
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 200m
          memory: 512Mi

    # Summary worker (report generation)
    summary:
      enabled: true
      replicas: 2
      queue: "summary"
      concurrency: 4
      resources:
        requests:
          cpu: 100m
          memory: 500Mi
        limits:
          cpu: 200m
          memory: 750Mi

    # Add other worker types as needed...

  # Celery Beat (scheduler)
  beat:
    enabled: true
    replicas: 1
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 100m
        memory: 256Mi
```

### 3.2 Create Celery Worker Deployment Template

**File**: `ros-ocp/templates/deployment-celery-worker.yaml`

```yaml
{{- range $workerName, $workerConfig := .Values.celery.workers }}
{{- if $workerConfig.enabled }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "ros-ocp.fullname" $ }}-celery-worker-{{ $workerName }}
  namespace: {{ $.Release.Namespace }}
  labels:
    {{- include "ros-ocp.labels" $ | nindent 4 }}
    app.kubernetes.io/component: celery-worker-{{ $workerName }}
spec:
  replicas: {{ $workerConfig.replicas }}
  selector:
    matchLabels:
      {{- include "ros-ocp.selectorLabels" $ | nindent 6 }}
      app.kubernetes.io/component: celery-worker-{{ $workerName }}
  template:
    metadata:
      labels:
        {{- include "ros-ocp.selectorLabels" $ | nindent 8 }}
        app.kubernetes.io/component: celery-worker-{{ $workerName }}
    spec:
      containers:
        - name: celery-worker
          image: "{{ $.Values.koku.image.repository }}:{{ $.Values.koku.image.tag }}"
          imagePullPolicy: {{ $.Values.koku.image.pullPolicy }}

          command: ["/bin/bash"]
          args:
            - -c
            - |
              exec celery \
                --app=koku \
                worker \
                --loglevel=INFO \
                --queues={{ $workerConfig.queue }} \
                --concurrency={{ $workerConfig.concurrency }} \
                --hostname={{ $workerName }}@%h

          env:
            # Same environment variables as Koku API
            - name: CELERY_BROKER_URL
              value: "redis://{{ include \"ros-ocp.fullname\" $ }}-redis:6379/0"
            - name: CELERY_RESULT_BACKEND
              value: "db+postgresql://{{ $.Values.database.koku.user }}:{{ $.Values.database.koku.password }}@{{ include \"ros-ocp.fullname\" $ }}-db-koku:5432/{{ $.Values.database.koku.name }}"
            # ... (include all Koku env vars)

          resources:
            {{- toYaml $workerConfig.resources | nindent 12 }}
{{- end }}
{{- end }}
```

### 3.3 Create Celery Beat Deployment

**File**: `ros-ocp/templates/deployment-celery-beat.yaml`

```yaml
{{- if .Values.celery.beat.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "ros-ocp.fullname" . }}-celery-beat
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "ros-ocp.labels" . | nindent 4 }}
    app.kubernetes.io/component: celery-beat
spec:
  replicas: {{ .Values.celery.beat.replicas }}
  strategy:
    type: Recreate  # Only one beat scheduler should run
  selector:
    matchLabels:
      {{- include "ros-ocp.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: celery-beat
  template:
    metadata:
      labels:
        {{- include "ros-ocp.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: celery-beat
    spec:
      containers:
        - name: celery-beat
          image: "{{ .Values.koku.image.repository }}:{{ .Values.koku.image.tag }}"
          imagePullPolicy: {{ .Values.koku.image.pullPolicy }}

          command: ["/bin/bash"]
          args:
            - -c
            - |
              exec celery \
                --app=koku \
                beat \
                --loglevel=INFO \
                --scheduler django_celery_beat.schedulers:DatabaseScheduler

          env:
            # Same as workers
            - name: CELERY_BROKER_URL
              value: "redis://{{ include \"ros-ocp.fullname\" . }}-redis:6379/0"
            # ... (include all Koku env vars)

          resources:
            {{- toYaml .Values.celery.beat.resources | nindent 12 }}
{{- end }}
```

---

## Phase 4: Database Updates

### 4.1 Add Koku Database

Update `values.yaml`:

```yaml
database:
  # ... existing ros, kruize, sources ...

  # Koku database (cost management)
  koku:
    image:
      repository: quay.io/insights-onprem/postgresql
      tag: "16"
    storage:
      size: 20Gi  # Larger for cost data
    host: internal
    port: 5432
    name: koku
    user: koku
    password: koku_password
    sslMode: disable

    # Read replica support
    readReplica:
      enabled: false  # Enable when ready
      host: internal
      port: 5432
      user: koku_replica
      password: koku_replica_password
```

### 4.2 Create Koku Database StatefulSet

**File**: `ros-ocp/templates/statefulset-db-koku.yaml`

Similar to existing database StatefulSets but for Koku database.

### 4.3 (Optional) Create Koku Read Replica StatefulSet

**File**: `ros-ocp/templates/statefulset-db-koku-replica.yaml`

If read replica is needed.

---

## Phase 5: Configuration and Secrets

### 5.1 Required Secrets

Create these secrets before deployment:

```bash
# Django secret key
python -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())' > django-secret-key.txt

# Create secret
kubectl create secret generic ros-ocp-koku-secret \
  --from-file=django-secret-key=django-secret-key.txt \
  -n ros-ocp
```

### 5.2 Storage Credentials

Ensure storage credentials secret exists:

```bash
kubectl create secret generic ros-ocp-storage-credentials \
  --from-literal=access-key=minioaccesskey \
  --from-literal=secret-key=miniosecretkey \
  -n ros-ocp
```

### 5.3 (Optional) Cloud Provider Credentials

For AWS cost data:

```bash
kubectl create secret generic ros-ocp-aws-credentials \
  --from-file=aws-credentials=/path/to/aws/credentials \
  -n ros-ocp
```

For GCP cost data:

```bash
kubectl create secret generic ros-ocp-gcp-credentials \
  --from-file=gcp-credentials=/path/to/gcp/credentials.json \
  -n ros-ocp
```

---

## Phase 6: Routes and Services

### 6.1 Update Ingress/Routes

Update the main route to include Koku API paths:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ include "ros-ocp.fullname" . }}-koku-api
spec:
  to:
    kind: Service
    name: {{ include "ros-ocp.fullname" . }}-koku-api
  path: /api/cost-management
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

### 6.2 Create Services

- Koku API service (already created above)
- Trino coordinator service
- Trino worker service

---

## Implementation Checklist

### Preparation
- [ ] Review ClowdApp YAML for exact image tags
- [ ] Generate Django secret key
- [ ] Prepare storage credentials
- [ ] (Optional) Prepare cloud provider credentials

### Phase 1: Koku API
- [ ] Add Koku configuration to values.yaml
- [ ] Create `deployment-koku-api-reads.yaml`
- [ ] Create `deployment-koku-api-writes.yaml`
- [ ] Create `service-koku-api.yaml`
- [ ] Create `secret-koku-credentials.yaml`
- [ ] Test Koku API deployment

### Phase 2: Trino
- [ ] Add Trino configuration to values.yaml
- [ ] Create `statefulset-trino-coordinator.yaml`
- [ ] Create `deployment-trino-worker.yaml`
- [ ] Create `configmap-trino-config.yaml`
- [ ] Create `service-trino.yaml`
- [ ] Test Trino deployment

### Phase 3: Celery Workers
- [ ] Add Celery configuration to values.yaml
- [ ] Create `deployment-celery-worker.yaml` (template for all workers)
- [ ] Create `deployment-celery-beat.yaml`
- [ ] Test worker deployments

### Phase 4: Database
- [ ] Add Koku database to values.yaml
- [ ] Create `statefulset-db-koku.yaml`
- [ ] (Optional) Create `statefulset-db-koku-replica.yaml`
- [ ] Test database connectivity

### Phase 5: Integration Testing
- [ ] Deploy full stack
- [ ] Verify Koku API responds
- [ ] Verify Trino queries work
- [ ] Verify workers process tasks
- [ ] Check Celery Beat scheduling
- [ ] Load test

### Phase 6: Documentation
- [ ] Update README with Koku components
- [ ] Document configuration options
- [ ] Create operational runbooks
- [ ] Update troubleshooting guide

---

## Testing Strategy

### 1. Component Testing
Test each component individually:

```bash
# Test Koku API-Reads
kubectl exec -it deployment/ros-ocp-koku-api-reads -- curl localhost:8000/api/cost-management/v1/status/

# Test Koku API-Writes
kubectl exec -it deployment/ros-ocp-koku-api-writes -- curl localhost:8000/api/cost-management/v1/status/

# Test Trino
kubectl exec -it statefulset/ros-ocp-trino-coordinator -- trino --execute "SHOW CATALOGS;"

# Test Celery Workers
kubectl logs deployment/ros-ocp-celery-worker-priority | grep "ready"
```

### 2. Integration Testing
Test end-to-end flows:

```bash
# Test API to Database
curl http://koku-api.ros-ocp.svc.cluster.local:8000/api/cost-management/v1/organizations/

# Test Celery task execution
kubectl exec -it deployment/ros-ocp-koku-api-reads -- python manage.py shell
>>> from koku.celery import app
>>> app.send_task('test.task', queue='priority')
```

### 3. Load Testing
Use `locust` or similar tool to test API performance under load.

---

## Rollback Plan

If issues arise:

1. **Disable new components** in values.yaml:
   ```yaml
   koku:
     apiReads:
       enabled: false
     apiWrites:
       enabled: false
   trino:
     enabled: false
   celery:
     workers:
       download:
         enabled: false
   ```

2. **Helm rollback**:
   ```bash
   helm rollback ros-ocp -n ros-ocp
   ```

3. **Manual cleanup** if needed:
   ```bash
   kubectl delete deployment -l app.kubernetes.io/component=koku-api-reads -n ros-ocp
   kubectl delete deployment -l app.kubernetes.io/component=celery-worker -n ros-ocp
   kubectl delete statefulset ros-ocp-trino-coordinator -n ros-ocp
   ```

---

## Next Steps

1. Review this implementation guide
2. Confirm image repositories and tags from ClowdApp
3. Start with Phase 1 (Koku API)
4. Test thoroughly before proceeding to next phase
5. Consider starting with minimal worker types (3-5) instead of all 13

---

**Questions or issues?** Refer to the ClowdApp YAML for exact configuration values and environment variables.

