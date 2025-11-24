{{/*
Expand the name of the chart.
*/}}
{{- define "trino.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "trino.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "trino.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "trino.labels" -}}
helm.sh/chart: {{ include "trino.chart" . }}
{{ include "trino.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "trino.selectorLabels" -}}
app.kubernetes.io/name: {{ include "trino.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "trino.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "trino.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Get storage class
*/}}
{{- define "trino.storageClass" -}}
{{- if .Values.global.storageClass }}
{{- .Values.global.storageClass }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
Detect if running on OpenShift
*/}}
{{- define "trino.isOpenShift" -}}
{{- if .Capabilities.APIVersions.Has "route.openshift.io/v1" -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Get S3 endpoint based on environment
*/}}
{{- define "trino.s3Endpoint" -}}
{{- if .Values.catalogs.hive.s3.endpoint }}
{{- .Values.catalogs.hive.s3.endpoint }}
{{- else if eq (include "trino.isOpenShift" .) "true" }}
{{- if .Values.catalogs.hive.s3.useODF }}
https://{{ .Values.catalogs.hive.s3.odfService }}:{{ .Values.catalogs.hive.s3.odfPort }}
{{- else }}
http://{{ .Values.catalogs.hive.s3.minioService }}.{{ .Release.Namespace }}.svc.cluster.local:{{ .Values.catalogs.hive.s3.minioPort }}
{{- end }}
{{- else }}
http://{{ .Values.catalogs.hive.s3.minioService }}.{{ .Release.Namespace }}.svc.cluster.local:{{ .Values.catalogs.hive.s3.minioPort }}
{{- end }}
{{- end }}

{{/*
Get Hive Metastore URI
*/}}
{{- define "trino.metastoreUri" -}}
{{- if .Values.catalogs.hive.metastoreUri }}
{{- .Values.catalogs.hive.metastoreUri }}
{{- else }}
thrift://{{ include "trino.fullname" . }}-metastore:{{ .Values.metastore.port }}
{{- end }}
{{- end }}

