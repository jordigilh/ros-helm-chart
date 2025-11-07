{{/*
Base helper functions for cost-management-onprem chart
These are minimal helpers needed until PR #27 merges
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "cost-mgmt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "cost-mgmt.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cost-mgmt.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "cost-mgmt.labels" -}}
helm.sh/chart: {{ include "cost-mgmt.chart" . }}
{{ include "cost-mgmt.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "cost-mgmt.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cost-mgmt.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Database host - placeholder until infrastructure chart exists
*/}}
{{- define "cost-mgmt.database.host" -}}
{{- $context := .context -}}
{{- $database := .database | default "ros" -}}
{{- printf "%s-%s-db" (include "cost-mgmt.fullname" $context) $database -}}
{{- end -}}

{{/*
Redis host - placeholder
*/}}
{{- define "cost-mgmt.redis.host" -}}
{{- printf "redis" -}}
{{- end -}}

{{/*
Redis port
*/}}
{{- define "cost-mgmt.redis.port" -}}
{{- 6379 -}}
{{- end -}}

{{/*
Kafka bootstrap servers - placeholder
*/}}
{{- define "cost-mgmt.kafka.bootstrapServers" -}}
{{- printf "kafka:29092" -}}
{{- end -}}

{{/*
Storage endpoint (S3-compatible object storage)
Defaults to ODF NooBaa, can be overridden for external S3 or MinIO
*/}}
{{- define "cost-mgmt.storage.endpoint" -}}
{{- .Values.infrastructure.storage.endpoint | default "http://s3.openshift-storage.svc:80" -}}
{{- end -}}

{{/*
Storage bucket name
*/}}
{{- define "cost-mgmt.storage.bucketName" -}}
{{- "koku-report" -}}
{{- end -}}

{{/*
Security context for pods
*/}}
{{- define "cost-mgmt.securityContext.pod" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/*
Security context for containers
*/}}
{{- define "cost-mgmt.securityContext.container" -}}
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
readOnlyRootFilesystem: false
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/*
Platform detection - always OpenShift for this chart
*/}}
{{- define "cost-mgmt.platform.isOpenShift" -}}
{{- true -}}
{{- end -}}

