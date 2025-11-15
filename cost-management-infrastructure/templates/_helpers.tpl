{{/*
Expand the name of the chart.
*/}}
{{- define "cost-mgmt-infra.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "cost-mgmt-infra.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cost-mgmt-infra.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cost-mgmt-infra.labels" -}}
helm.sh/chart: {{ include "cost-mgmt-infra.chart" . }}
{{ include "cost-mgmt-infra.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cost-mgmt-infra.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cost-mgmt-infra.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "cost-mgmt-infra.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cost-mgmt-infra.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
PostgreSQL service name
*/}}
{{- define "cost-mgmt-infra.postgresql.serviceName" -}}
postgres
{{- end -}}

{{/*
PostgreSQL secret name
*/}}
{{- define "cost-mgmt-infra.postgresql.secretName" -}}
{{- if .Values.postgresql.database.existingSecret -}}
{{- .Values.postgresql.database.existingSecret -}}
{{- else -}}
postgres-credentials
{{- end -}}
{{- end -}}

