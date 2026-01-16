{{/*
Expand the name of the chart.
*/}}
{{/* prettier-ignore */}}
{{- define "cost-onprem.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "cost-onprem.fullname" -}}
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
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cost-onprem.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cost-onprem.labels" -}}
helm.sh/chart: {{ include "cost-onprem.chart" . }}
{{ include "cost-onprem.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cost-onprem.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cost-onprem.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: {{ include "cost-onprem.name" . }}
{{- end }}

{{/*
Database host resolver - returns unified database service name if "internal", otherwise returns the configured host
Since all databases (ros, kruize, sources) are on the same unified server, this returns a single common host.
Usage: {{ include "cost-onprem.database.host" . }}
*/}}
{{- define "cost-onprem.database.host" -}}
  {{- if eq .Values.database.server.host "internal" -}}
{{- printf "%s-database" (include "cost-onprem.fullname" .) -}}
  {{- else -}}
{{- .Values.database.server.host -}}
  {{- end -}}
{{- end }}

{{/*
Get the database URL - returns complete postgresql connection string
Uses $(DB_USER) and $(DB_PASSWORD) environment variables for credentials
*/}}
{{- define "cost-onprem.database.url" -}}
{{- printf "postgresql://$(DB_USER):$(DB_PASSWORD)@%s:%s/%s?sslmode=%s" (include "cost-onprem.database.host" .) (.Values.database.server.port | toString) .Values.database.ros.name .Values.database.server.sslMode }}
{{- end }}

{{/*
Get the kruize database host - returns unified database service name (alias for backward compatibility)
*/}}
{{- define "cost-onprem.kruize.databaseHost" -}}
{{- include "cost-onprem.database.host" . -}}
{{- end }}

{{/*
Get the sources database host - now returns infra chart's PostgreSQL host
Sources API shares the koku database with Koku because Sources provisions tables that Koku uses
*/}}
{{- define "cost-onprem.sources.databaseHost" -}}
{{- include "cost-onprem.koku.database.host" . -}}
{{- end }}

{{/*
Get the default database credentials secret name (chart-managed secret)
Usage: {{ include "cost-onprem.database.defaultSecretName" . }}
*/}}
{{- define "cost-onprem.database.defaultSecretName" -}}
{{- printf "%s-db-credentials" (include "cost-onprem.fullname" .) -}}
{{- end -}}

{{/*
Get the database credentials secret name - returns existingSecret if set, otherwise returns generated secret name
Usage: {{ include "cost-onprem.database.secretName" . }}
*/}}
{{- define "cost-onprem.database.secretName" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecret -}}
{{- else -}}
{{- include "cost-onprem.database.defaultSecretName" . -}}
{{- end -}}
{{- end }}

{{/*
Get ROS database username - returns value from values.yaml (used for both secret generation and ConfigMap)
Usage: {{ include "cost-onprem.database.ros.user" . }}
*/}}
{{- define "cost-onprem.database.ros.user" -}}
{{- .Values.database.ros.user -}}
{{- end }}

{{/*
Get ROS database password - returns value from values.yaml (used for both secret generation and ConfigMap)
Usage: {{ include "cost-onprem.database.ros.password" . }}
*/}}
{{- define "cost-onprem.database.ros.password" -}}
{{- .Values.database.ros.password -}}
{{- end }}

{{/*
Get Kruize database username - returns value from values.yaml (used for both secret generation and ConfigMap)
Usage: {{ include "cost-onprem.database.kruize.user" . }}
*/}}
{{- define "cost-onprem.database.kruize.user" -}}
{{- .Values.database.kruize.user -}}
{{- end }}

{{/*
Get Kruize database password - returns value from values.yaml (used for both secret generation and ConfigMap)
Usage: {{ include "cost-onprem.database.kruize.password" . }}
*/}}
{{- define "cost-onprem.database.kruize.password" -}}
{{- .Values.database.kruize.password -}}
{{- end }}

{{/*
NOTE: Sources API now uses the infra chart's PostgreSQL (shares koku database)
because Sources API provisions tables that Koku uses.
Sources credentials are in the postgres-credentials secret from the infra chart.
*/}}

{{/*
Detect if running on OpenShift by checking for OpenShift-specific API resources
Returns true if OpenShift is detected, false otherwise
*/}}
{{- define "cost-onprem.platform.isOpenShift" -}}
  {{- if .Values.global.storageType -}}
    {{- if eq .Values.global.storageType "odf" -}}
true
    {{- else -}}
false
    {{- end -}}
  {{- else -}}
    {{- if .Capabilities.APIVersions.Has "route.openshift.io/v1" -}}
true
    {{- else -}}
false
    {{- end -}}
  {{- end -}}
{{- end }}

{{/*
Extract domain from cluster ingress configuration
Returns domain if found, empty string otherwise
*/}}
{{- define "cost-onprem.platform.getDomainFromIngressConfig" -}}
  {{- $ingressConfig := lookup "config.openshift.io/v1" "Ingress" "" "cluster" -}}
  {{- if and $ingressConfig $ingressConfig.spec $ingressConfig.spec.domain -}}
{{- $ingressConfig.spec.domain -}}
  {{- else -}}
{{- "" -}}
  {{- end -}}
{{- end }}

{{/*
Extract domain from ingress controller
Returns domain if found, empty string otherwise
*/}}
{{- define "cost-onprem.platform.getDomainFromIngressController" -}}
  {{- $ingressController := lookup "operator.openshift.io/v1" "IngressController" "openshift-ingress-operator" "default" -}}
  {{- if and $ingressController $ingressController.status $ingressController.status.domain -}}
{{- $ingressController.status.domain -}}
  {{- else -}}
{{- "" -}}
  {{- end -}}
{{- end }}

{{/*
Extract domain from existing routes
Returns domain if found, empty string otherwise
*/}}
{{- define "cost-onprem.platform.getDomainFromRoutes" -}}
  {{- $routes := lookup "route.openshift.io/v1" "Route" "" "" -}}
  {{- $clusterDomain := "" -}}
  {{- if and $routes $routes.items -}}
    {{- range $routes.items -}}
      {{- if and .spec.host (contains "." .spec.host) -}}
        {{- $hostParts := regexSplit "\\." .spec.host -1 -}}
        {{- if gt (len $hostParts) 2 -}}
          {{- $clusterDomain = join "." (slice $hostParts 1) -}}
          {{- break -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- $clusterDomain -}}
{{- end }}

{{/*
Get OpenShift cluster domain dynamically
Returns the cluster's default route domain (e.g., "apps.mycluster.example.com")
STRICT MODE: Fails deployment if cluster domain cannot be detected
Usage: {{ include "cost-onprem.platform.clusterDomain" . }}
*/}}
{{- define "cost-onprem.platform.clusterDomain" -}}
  {{- /* 1. Check for explicit override first (avoids lookup calls) */ -}}
  {{- if and .Values.global .Values.global.clusterDomain -}}
{{- .Values.global.clusterDomain -}}
  {{- else -}}
    {{- /* 2. Try multiple strategies to detect cluster domain */ -}}
    {{- $domain := include "cost-onprem.platform.getDomainFromIngressConfig" . -}}
    {{- if eq $domain "" -}}
      {{- $domain = include "cost-onprem.platform.getDomainFromIngressController" . -}}
    {{- end -}}
    {{- if eq $domain "" -}}
      {{- $domain = include "cost-onprem.platform.getDomainFromRoutes" . -}}
    {{- end -}}

    {{- if eq $domain "" -}}
      {{- /* STRICT MODE: Fail if cluster domain cannot be detected */ -}}
{{- fail "ERROR: Unable to detect OpenShift cluster domain. Ensure you are deploying to a properly configured OpenShift cluster with ingress controllers and routes. Dynamic detection failed for: config.openshift.io/v1/Ingress, operator.openshift.io/v1/IngressController, and existing Routes." -}}
    {{- else -}}
{{- $domain -}}
    {{- end -}}
  {{- end -}}
{{- end }}

{{/*
Extract cluster name from Infrastructure resource
Returns name if found, empty string otherwise
*/}}
{{- define "cost-onprem.platform.getClusterNameFromInfrastructure" -}}
  {{- $infrastructure := lookup "config.openshift.io/v1" "Infrastructure" "" "cluster" -}}
  {{- if and $infrastructure $infrastructure.status $infrastructure.status.infrastructureName -}}
{{- $infrastructure.status.infrastructureName -}}
  {{- else -}}
{{- "" -}}
  {{- end -}}
{{- end }}

{{/*
Extract cluster name from ClusterVersion resource
Returns name if found, empty string otherwise
*/}}
{{- define "cost-onprem.platform.getClusterNameFromClusterVersion" -}}
  {{- $clusterVersion := lookup "config.openshift.io/v1" "ClusterVersion" "" "version" -}}
  {{- if and $clusterVersion $clusterVersion.spec $clusterVersion.spec.clusterID -}}
{{- printf "cluster-%s" (substr 0 8 $clusterVersion.spec.clusterID) -}}
  {{- else -}}
{{- "" -}}
  {{- end -}}
{{- end }}

{{/*
Get OpenShift cluster name dynamically
Returns the cluster's infrastructure name (e.g., "mycluster-abcd1")
STRICT MODE: Fails deployment if cluster name cannot be detected
Usage: {{ include "cost-onprem.platform.clusterName" . }}
*/}}
{{- define "cost-onprem.platform.clusterName" -}}
  {{- /* 1. Check for explicit override first (avoids lookup calls) */ -}}
  {{- if and .Values.global .Values.global.clusterName -}}
{{- .Values.global.clusterName -}}
  {{- else -}}
    {{- /* 2. Try multiple strategies to detect cluster name */ -}}
    {{- $name := include "cost-onprem.platform.getClusterNameFromInfrastructure" . -}}
    {{- if eq $name "" -}}
      {{- $name = include "cost-onprem.platform.getClusterNameFromClusterVersion" . -}}
    {{- end -}}

    {{- if eq $name "" -}}
      {{- /* STRICT MODE: Fail if cluster name cannot be detected */ -}}
{{- fail "ERROR: Unable to detect OpenShift cluster name. Ensure you are deploying to a properly configured OpenShift cluster. Dynamic detection failed for: config.openshift.io/v1/Infrastructure and config.openshift.io/v1/ClusterVersion resources." -}}
    {{- else -}}
{{- $name -}}
    {{- end -}}
  {{- end -}}
{{- end }}

{{/*
Generate external URL for a service based on deployment platform (OpenShift Routes vs Kubernetes Ingress)
Usage: {{ include "cost-onprem.externalUrl" (list . "service-name" "/path") }}
*/}}
{{- define "cost-onprem.externalUrl" -}}
  {{- $root := index . 0 -}}
  {{- $service := index . 1 -}}
  {{- $path := index . 2 -}}
  {{- if eq (include "cost-onprem.platform.isOpenShift" $root) "true" -}}
    {{- /* OpenShift: Use Route configuration */ -}}
    {{- $scheme := "http" -}}
    {{- if $root.Values.serviceRoute.tls.termination -}}
      {{- $scheme = "https" -}}
    {{- end -}}
    {{- with (index $root.Values.serviceRoute.hosts 0) -}}
      {{- if .host -}}
{{- printf "%s://%s%s" $scheme .host $path -}}
      {{- else -}}
{{- printf "%s://%s-%s.%s%s" $scheme $service $root.Release.Namespace (include "cost-onprem.platform.clusterDomain" $root) $path -}}
      {{- end -}}
    {{- end -}}
  {{- else -}}
    {{- /* Kubernetes: Use Ingress configuration */ -}}
    {{- $scheme := "http" -}}
    {{- if $root.Values.serviceIngress.tls -}}
      {{- $scheme = "https" -}}
    {{- end -}}
    {{- with (index $root.Values.serviceIngress.hosts 0) -}}
{{- printf "%s://%s%s" $scheme .host $path -}}
    {{- end -}}
  {{- end -}}
{{- end }}

{{/*
Detect appropriate volume mode based on actual storage class provisioner
Returns "Block" for block storage, "Filesystem" for filesystem storage
Usage: {{ include "cost-onprem.storage.volumeMode" . }}
*/}}
{{- define "cost-onprem.storage.volumeMode" -}}
  {{- $storageClass := include "cost-onprem.storage.databaseClass" . -}}
{{- include "cost-onprem.storage.volumeModeForStorageClass" (list . $storageClass) -}}
{{- end }}

{{/*
Get storage class name - validates user-defined storage class exists, falls back to default
Handles dry-run mode gracefully, fails deployment only if no suitable storage class is found during actual installation
Usage: {{ include "cost-onprem.storage.class" . }}
*/}}
{{- define "cost-onprem.storage.class" -}}
  {{- /* 1. FIRST check for explicit user-defined storage class */ -}}
  {{- $userDefinedClass := include "cost-onprem.storage.getUserDefinedClass" . -}}
  {{- if $userDefinedClass -}}
    {{- /* User provided explicit storage class - trust it and skip lookups */ -}}
{{- $userDefinedClass -}}
  {{- else -}}
    {{- /* No explicit storage class - need to query cluster */ -}}
    {{- $storageClasses := lookup "storage.k8s.io/v1" "StorageClass" "" "" -}}

    {{- /* Handle dry-run mode or cluster connectivity issues */ -}}
    {{- if not (and $storageClasses $storageClasses.items) -}}
      {{- /* In dry-run mode with no explicit storage class, use a reasonable default */ -}}
{{- include "cost-onprem.storage.getPlatformDefault" . -}}
    {{- else -}}
      {{- /* Normal operation - find default storage class */ -}}
      {{- $defaultFound := "" -}}
      {{- range $storageClasses.items -}}
        {{- if and .metadata.annotations (eq (index .metadata.annotations "storageclass.kubernetes.io/is-default-class") "true") -}}
          {{- $defaultFound = .metadata.name -}}
        {{- end -}}
      {{- end -}}

      {{- if $defaultFound -}}
{{- $defaultFound -}}
      {{- else -}}
{{- $scNames := list -}}
        {{- range $storageClasses.items -}}
          {{- $scNames = append $scNames .metadata.name -}}
        {{- end -}}
{{- fail (printf "No default storage class found in cluster. Available storage classes: %s\nPlease either:\n1. Set a default storage class with 'storageclass.kubernetes.io/is-default-class=true' annotation, or\n2. Explicitly specify a storage class with 'global.storageClass'" (join ", " $scNames)) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end }}

{{/*
Extract user-defined storage class from values
Returns the storage class name if defined, empty string otherwise
*/}}
{{- define "cost-onprem.storage.getUserDefinedClass" -}}
  {{- if and .Values.global.storageClass (ne .Values.global.storageClass "") -}}
{{- .Values.global.storageClass -}}
  {{- else -}}
{{- "" -}}
  {{- end -}}
{{- end }}

{{/*
Get platform-specific default storage class
Returns appropriate default storage class based on platform
*/}}
{{- define "cost-onprem.storage.getPlatformDefault" -}}
  {{- if eq (include "cost-onprem.platform.isOpenShift" .) "true" -}}
ocs-storagecluster-ceph-rbd
  {{- else -}}
standard
  {{- end -}}
{{- end }}

{{/*
Find default storage class from cluster
Returns the name of the default storage class if found, empty string otherwise
*/}}
{{- define "cost-onprem.storage.findDefault" -}}
  {{- $storageClasses := lookup "storage.k8s.io/v1" "StorageClass" "" "" -}}
  {{- $defaultFound := "" -}}
  {{- if and $storageClasses $storageClasses.items -}}
    {{- range $storageClasses.items -}}
      {{- if and .metadata.annotations (eq (index .metadata.annotations "storageclass.kubernetes.io/is-default-class") "true") -}}
        {{- $defaultFound = .metadata.name -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- $defaultFound -}}
{{- end }}

{{/*
Check if user-defined storage class exists in cluster
Returns true if found, false otherwise
*/}}
{{- define "cost-onprem.storage.userClassExists" -}}
  {{- $userDefinedClass := include "cost-onprem.storage.getUserDefinedClass" . -}}
  {{- $storageClasses := lookup "storage.k8s.io/v1" "StorageClass" "" "" -}}
  {{- $exists := false -}}
  {{- if and $userDefinedClass $storageClasses $storageClasses.items -}}
    {{- range $storageClasses.items -}}
      {{- if eq .metadata.name $userDefinedClass -}}
        {{- $exists = true -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- $exists -}}
{{- end }}

{{/*
Get storage class for database workloads - uses same logic as main storage class
Only uses default storage class or user-defined, no fallbacks
Usage: {{ include "cost-onprem.storage.databaseClass" . }}
*/}}
{{- define "cost-onprem.storage.databaseClass" -}}
{{- include "cost-onprem.storage.class" . -}}
{{- end }}

{{/*
Check if a provisioner supports filesystem volumes
Returns true if the provisioner is known to support filesystem volumes
Usage: {{ include "cost-onprem.storage.supportsFilesystem" (list . $provisioner $parameters $isOpenShift) }}
*/}}
{{- define "cost-onprem.storage.supportsFilesystem" -}}
  {{- $root := index . 0 -}}
  {{- $provisioner := index . 1 -}}
  {{- $parameters := index . 2 -}}
  {{- $isOpenShift := index . 3 -}}

  {{- /* Check for explicit filesystem indicators */ -}}
  {{- if and $parameters $parameters.fstype -}}
true
  {{- else -}}
    {{- /* Platform-specific filesystem provisioner detection */ -}}
    {{- if $isOpenShift -}}
      {{- /* OpenShift filesystem provisioners */ -}}
      {{- if or (contains "rbd" $provisioner) (contains "ceph-rbd" $provisioner) (contains "nfs" $provisioner) (contains "ebs" $provisioner) (contains "gce" $provisioner) (contains "azure" $provisioner) -}}
true
      {{- else -}}
false
      {{- end -}}
    {{- else -}}
      {{- /* Vanilla Kubernetes filesystem provisioners */ -}}
      {{- if or (contains "local-path" $provisioner) (contains "hostpath" $provisioner) (contains "host-path" $provisioner) (contains "nfs" $provisioner) (contains "rgw" $provisioner) (contains "bucket" $provisioner) (contains "ebs" $provisioner) (contains "gce" $provisioner) (contains "azure" $provisioner) (contains "rbd" $provisioner) (contains "ceph-rbd" $provisioner) -}}
true
      {{- else if contains "no-provisioner" $provisioner -}}
        {{- /* No provisioner - check if it's a local volume with filesystem support */ -}}
        {{- if and $parameters $parameters.path -}}
true
        {{- else -}}
false
        {{- end -}}
      {{- else -}}
        {{- /* Default to filesystem for unknown provisioners (safer for most workloads) */ -}}
true
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end }}

{{/*
Check if a provisioner supports block volumes
Returns true if the provisioner is known to support block volumes
Usage: {{ include "cost-onprem.storage.supportsBlock" (list . $provisioner $parameters $isOpenShift) }}
*/}}
{{- define "cost-onprem.storage.supportsBlock" -}}
  {{- $root := index . 0 -}}
  {{- $provisioner := index . 1 -}}
  {{- $parameters := index . 2 -}}
  {{- $isOpenShift := index . 3 -}}

  {{- /* Platform-specific block provisioner detection */ -}}
  {{- if $isOpenShift -}}
    {{- /* OpenShift block provisioners - most OpenShift provisioners prefer filesystem */ -}}
    {{- if or (contains "iscsi" $provisioner) (contains "fc" $provisioner) -}}
true
    {{- else -}}
false
    {{- end -}}
  {{- else -}}
    {{- /* Vanilla Kubernetes block provisioners */ -}}
    {{- if or (contains "iscsi" $provisioner) (contains "fc" $provisioner) -}}
true
    {{- else if contains "no-provisioner" $provisioner -}}
      {{- /* No provisioner - check if it's not a local path volume */ -}}
      {{- if not (and $parameters $parameters.path) -}}
true
      {{- else -}}
false
      {{- end -}}
    {{- else -}}
      {{- /* Most other provisioners prefer filesystem */ -}}
false
    {{- end -}}
  {{- end -}}
{{- end }}

{{/*
Detect volume mode by platform-aware analysis of storage class capabilities
Handles OpenShift, vanilla Kubernetes, KIND, and other distributions appropriately
Usage: {{ include "cost-onprem.storage.volumeModeForStorageClass" (list . "storage-class-name") }}
*/}}
{{- define "cost-onprem.storage.volumeModeForStorageClass" -}}
  {{- $root := index . 0 -}}
  {{- $storageClassName := index . 1 -}}
  {{- $isOpenShift := eq (include "cost-onprem.platform.isOpenShift" $root) "true" -}}

  {{- /* Strategy 1: Check existing PVs for this storage class to see what volume modes are actually working */ -}}
  {{- $existingPVs := lookup "v1" "PersistentVolume" "" "" -}}
  {{- $filesystemPVs := 0 -}}
  {{- $blockPVs := 0 -}}
  {{- if and $existingPVs $existingPVs.items -}}
    {{- range $existingPVs.items -}}
      {{- if and .spec.storageClassName (eq .spec.storageClassName $storageClassName) -}}
        {{- if eq .spec.volumeMode "Filesystem" -}}
          {{- $filesystemPVs = add $filesystemPVs 1 -}}
        {{- else if eq .spec.volumeMode "Block" -}}
          {{- $blockPVs = add $blockPVs 1 -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- /* If we found existing PVs, use the mode that's actually working */ -}}
  {{- if gt $filesystemPVs 0 -}}
    {{- /* Filesystem volumes are working for this storage class */ -}}
Filesystem
  {{- else if gt $blockPVs 0 -}}
    {{- /* Block volumes are working for this storage class */ -}}
Block
  {{- else -}}
    {{- /* Strategy 2: Platform-aware storage class analysis */ -}}
    {{- $storageClass := lookup "storage.k8s.io/v1" "StorageClass" "" $storageClassName -}}
    {{- if $storageClass -}}
      {{- $provisioner := $storageClass.provisioner -}}
      {{- $parameters := $storageClass.parameters -}}

      {{- /* Check for explicit volume mode configuration in storage class parameters */ -}}
      {{- if and $parameters $parameters.volumeMode -}}
{{- $parameters.volumeMode -}}
      {{- else -}}
        {{- /* Strategy 3: Use helper functions to determine volume mode support */ -}}
        {{- $supportsFilesystem := include "cost-onprem.storage.supportsFilesystem" (list $root $provisioner $parameters $isOpenShift) -}}
        {{- $supportsBlock := include "cost-onprem.storage.supportsBlock" (list $root $provisioner $parameters $isOpenShift) -}}

        {{- /* Determine volume mode based on support */ -}}
        {{- if eq $supportsFilesystem "true" -}}
Filesystem
        {{- else if eq $supportsBlock "true" -}}
Block
        {{- else -}}
          {{- /* Default fallback - prefer filesystem for safety */ -}}
Filesystem
        {{- end -}}
      {{- end -}}
    {{- else -}}
      {{- /* Strategy 4: Fallback based on platform and storage class name patterns */ -}}
      {{- if $isOpenShift -}}
        {{- /* OpenShift fallback - prefer filesystem */ -}}
Filesystem
      {{- else -}}
        {{- /* Vanilla Kubernetes fallback - check storage class name patterns */ -}}
        {{- if or (contains "local" $storageClassName) (contains "no-provisioner" $storageClassName) -}}
          {{- /* Check if it's a local-path type by name */ -}}
          {{- if contains "local-path" $storageClassName -}}
Filesystem
          {{- else -}}
            {{- /* Other local storage - default to block but this is risky */ -}}
Block
          {{- end -}}
        {{- else if or (contains "rbd" $storageClassName) (contains "ceph" $storageClassName) -}}
Filesystem
        {{- else -}}
          {{- /* Default to filesystem for most storage classes */ -}}
Filesystem
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end }}

{{/*
Cache service name (valkey)
*/}}
{{- define "cost-onprem.cache.name" -}}
valkey
{{- end }}

{{/*
Cache configuration (returns valkey config object)
*/}}
{{- define "cost-onprem.cache.config" -}}
{{- .Values.valkey | toYaml -}}
{{- end }}

{{/*
Cache CLI command (valkey-cli)
*/}}
{{- define "cost-onprem.cache.cli" -}}
valkey-cli
{{- end }}

{{/*
Storage service name (minio or odf based on platform)
*/}}
{{- define "cost-onprem.storage.name" -}}
{{- if eq (include "cost-onprem.platform.isOpenShift" .) "true" -}}
odf
{{- else -}}
minio
{{- end -}}
{{- end }}

{{/*
Storage configuration (returns the appropriate config object)
*/}}
{{- define "cost-onprem.storage.config" -}}
{{- if eq (include "cost-onprem.platform.isOpenShift" .) "true" -}}
{{- .Values.odf | toYaml -}}
{{- else -}}
{{- .Values.minio | toYaml -}}
{{- end -}}
{{- end }}

{{/*
Storage endpoint (MinIO service or ODF endpoint)
Supports: ODF (production) and MinIO standalone (CI)
*/}}
{{- define "cost-onprem.storage.endpoint" -}}
{{- /* 1. Check for explicit override */ -}}
{{- if and .Values.odf .Values.odf.endpoint -}}
{{- .Values.odf.endpoint -}}
{{- else -}}
  {{- /* 2. Detect ODF vs MinIO by checking NooBaa CRD */ -}}
  {{- $noobaaList := lookup "noobaa.io/v1alpha1" "NooBaa" "" "" -}}
  {{- if and $noobaaList $noobaaList.items (gt (len $noobaaList.items) 0) -}}
    {{- /* ODF detected - discover S3 endpoint from NooBaa CRD */ -}}
    {{- $s3Endpoint := "" -}}
    {{- range $noobaaList.items -}}
      {{- if and .status .status.services .status.services.serviceS3 .status.services.serviceS3.internalDNS -}}
        {{- $internalDNS := index .status.services.serviceS3.internalDNS 0 -}}
        {{- if $internalDNS -}}
          {{- $serviceName := regexReplaceAll "https://" $internalDNS "" -}}
          {{- $serviceName = regexReplaceAll ":443" $serviceName "" -}}
          {{- if not (hasSuffix ".cluster.local" $serviceName) -}}
            {{- $serviceName = printf "%s.cluster.local" $serviceName -}}
          {{- end -}}
          {{- $s3Endpoint = $serviceName -}}
          {{- break -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- if $s3Endpoint -}}
{{- $s3Endpoint -}}
    {{- else -}}
      {{- fail "ODF detected but unable to discover S3 endpoint from NooBaa CRD. Please specify 'odf.endpoint' in values.yaml" -}}
    {{- end -}}
  {{- else -}}
    {{- /* MinIO standalone (CI pattern) - check for proxy service */ -}}
    {{- $minioProxy := lookup "v1" "Service" .Release.Namespace "minio-storage" -}}
    {{- if $minioProxy -}}
      {{- /* CI pattern: minio-storage proxy service in same namespace */ -}}
minio-storage
    {{- else -}}
      {{- /* Fallback: MinIO in minio namespace */ -}}
minio.minio.svc
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Storage port (MinIO port or ODF port)
*/}}
{{- define "cost-onprem.storage.port" -}}
{{- if and .Values.odf .Values.odf.port -}}
{{- .Values.odf.port -}}
{{- else -}}
  {{- /* Auto-detect based on ODF NooBaa CRD */ -}}
  {{- $noobaaList := lookup "noobaa.io/v1alpha1" "NooBaa" "" "" -}}
  {{- if and $noobaaList $noobaaList.items (gt (len $noobaaList.items) 0) -}}
443
  {{- else -}}
9000
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Storage endpoint with protocol and port for S3 connections
This helper constructs the full S3 endpoint URL including protocol and port.
Uses .Values.odf.useSSL (set by install script) to determine protocol.
No lookup() calls - relies on values passed via --set flags.

Returns:
  - ODF (useSSL=true):  https://s3.openshift-storage.svc:443
  - MinIO (useSSL=false): http://minio-storage:9000
*/}}
{{- define "cost-onprem.storage.endpointWithProtocol" -}}
{{- $endpoint := include "cost-onprem.storage.endpoint" . -}}
{{- $port := include "cost-onprem.storage.port" . -}}
{{- $useSSL := false -}}

{{- /* Determine protocol based on .Values.odf.useSSL (passed by install script) */ -}}
{{- if and .Values.odf (hasKey .Values.odf "useSSL") -}}
  {{- $useSSL = .Values.odf.useSSL -}}
{{- end -}}

{{- if $useSSL -}}
https://{{ $endpoint }}:{{ $port }}
{{- else -}}
http://{{ $endpoint }}:{{ $port }}
{{- end -}}
{{- end }}

{{/*
Storage access key (MinIO root user - ODF uses noobaa-admin secret directly)
*/}}
{{- define "cost-onprem.storage.accessKey" -}}
{{- .Values.minio.rootUser -}}
{{- end }}

{{/*
Storage secret key (MinIO root password - ODF uses noobaa-admin secret directly)
*/}}
{{- define "cost-onprem.storage.secretKey" -}}
{{- .Values.minio.rootPassword -}}
{{- end }}

{{/*
Storage bucket name (staging bucket for ingress uploads)
*/}}
{{- define "cost-onprem.storage.bucket" -}}
{{- if eq (include "cost-onprem.platform.isOpenShift" .) "true" -}}
{{- if .Values.odf -}}
{{- .Values.odf.bucket -}}
{{- else -}}
insights-upload-perma
{{- end -}}
{{- else -}}
{{- .Values.ingress.storage.bucket -}}
{{- end -}}
{{- end }}

{{/*
Storage use SSL flag
*/}}
{{- define "cost-onprem.storage.useSSL" -}}
{{- if ne .Values.odf.useSSL nil -}}
{{- .Values.odf.useSSL -}}
{{- else -}}
  {{- /* Auto-detect based on ODF NooBaa CRD */ -}}
  {{- $noobaaList := lookup "noobaa.io/v1alpha1" "NooBaa" "" "" -}}
  {{- if and $noobaaList $noobaaList.items (gt (len $noobaaList.items) 0) -}}
true
  {{- else -}}
false
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Storage credentials secret name
*/}}
{{- define "cost-onprem.storage.secretName" -}}
{{- printf "%s-storage-credentials" (include "cost-onprem.fullname" .) -}}
{{- end }}

{{/*
Keycloak Dynamic Configuration Helpers
*/}}

{{/*
Get Keycloak CR object (centralized lookup to avoid duplication)
Returns the first Keycloak CR found, or empty dict if none exist
Only supports: k8s.keycloak.org/v2alpha1 (RHBK v22+)
This is a low-level helper - most code should use higher-level helpers like .namespace, .url, etc.
*/}}
{{- define "cost-onprem.keycloak.getCR" -}}
{{- $keycloaks := lookup "k8s.keycloak.org/v2alpha1" "Keycloak" "" "" -}}
{{- if and $keycloaks $keycloaks.items (gt (len $keycloaks.items) 0) -}}
{{- index $keycloaks.items 0 | toJson -}}
{{- else -}}
{}
{{- end -}}
{{- end }}

{{/*
Detect if Keycloak (RHBK) is installed in the cluster
This helper looks for Keycloak Custom Resources from the RHBK operator
Only supports: k8s.keycloak.org/v2alpha1 (RHBK v22+)
*/}}
{{- define "cost-onprem.keycloak.isInstalled" -}}
{{- /* 1. Check for explicit override first (avoids lookup calls) */ -}}
{{- if and .Values.jwtAuth .Values.jwtAuth.keycloak (hasKey .Values.jwtAuth.keycloak "installed") -}}
  {{- .Values.jwtAuth.keycloak.installed -}}
{{- else if or (and .Values.jwtAuth .Values.jwtAuth.keycloak .Values.jwtAuth.keycloak.url) .Values.jwtAuth.keycloak.namespace -}}
  {{- /* If jwtAuth.keycloak.url or jwtAuth.keycloak.namespace is explicitly set, assume installed */ -}}
  true
{{- else -}}
  {{- /* 2. Check for Keycloak CR */ -}}
  {{- $cr := include "cost-onprem.keycloak.getCR" . | fromJson -}}
  {{- if $cr.metadata -}}
    true
  {{- else -}}
    {{- /* 3. Fallback: try namespace pattern matching */ -}}
    {{- $found := false -}}
    {{- range $ns := (lookup "v1" "Namespace" "" "").items -}}
      {{- if or (contains "keycloak" $ns.metadata.name) (contains "sso" $ns.metadata.name) -}}
        {{- $found = true -}}
      {{- end -}}
    {{- end -}}
    {{- $found -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Find Keycloak namespace by looking for Keycloak CRs first, then fallback to patterns
Only supports RHBK (v2alpha1) operator
*/}}
{{- define "cost-onprem.keycloak.namespace" -}}
{{- /* 1. Check for explicit namespace override (avoids lookup calls) */ -}}
{{- if .Values.jwtAuth.keycloak.namespace -}}
  {{- .Values.jwtAuth.keycloak.namespace -}}
{{- else -}}
  {{- /* 2. Try to find namespace from Keycloak CR */ -}}
  {{- $cr := include "cost-onprem.keycloak.getCR" . | fromJson -}}
  {{- if $cr.metadata -}}
    {{- $cr.metadata.namespace -}}
  {{- else -}}
    {{- /* 3. Fallback: try namespace pattern matching */ -}}
    {{- $found := "" -}}
    {{- range $ns := (lookup "v1" "Namespace" "" "").items -}}
      {{- if or (contains "keycloak" $ns.metadata.name) (contains "sso" $ns.metadata.name) -}}
        {{- $found = $ns.metadata.name -}}
      {{- end -}}
    {{- end -}}
    {{- $found -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Find Keycloak service name by looking at Keycloak CRs first, then service discovery
Only supports RHBK (v2alpha1) operator
*/}}
{{- define "cost-onprem.keycloak.serviceName" -}}
{{- /* 1. Check for explicit override first (avoids lookup calls) */ -}}
{{- if and .Values.jwtAuth .Values.jwtAuth.keycloak .Values.jwtAuth.keycloak.serviceName -}}
  {{- .Values.jwtAuth.keycloak.serviceName -}}
{{- else -}}
  {{- /* 2. Try to get service name from Keycloak CR */ -}}
  {{- $cr := include "cost-onprem.keycloak.getCR" . | fromJson -}}
  {{- if $cr.metadata -}}
    {{- printf "%s-service" $cr.metadata.name -}}
  {{- else -}}
    {{- /* 3. Fallback: service discovery in the namespace */ -}}
    {{- $ns := include "cost-onprem.keycloak.namespace" . -}}
    {{- if $ns -}}
      {{- $found := "" -}}
      {{- range $svc := (lookup "v1" "Service" $ns "").items -}}
        {{- if or (contains "keycloak" $svc.metadata.name) (contains "sso" $svc.metadata.name) -}}
          {{- $found = $svc.metadata.name -}}
        {{- end -}}
      {{- end -}}
      {{- $found -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Get Keycloak URL from CR status.hostname field
Returns empty string if not available
*/}}
{{- define "cost-onprem.keycloak.getUrlFromCR" -}}
{{- $cr := include "cost-onprem.keycloak.getCR" . | fromJson -}}
{{- if and $cr.status $cr.status.hostname -}}
  {{- printf "https://%s" $cr.status.hostname -}}
{{- end -}}
{{- end }}

{{/*
Get Keycloak URL from OpenShift Route
Returns empty string if not found
*/}}
{{- define "cost-onprem.keycloak.getUrlFromRoute" -}}
{{- $ns := include "cost-onprem.keycloak.namespace" . -}}
{{- if $ns -}}
  {{- $found := "" -}}
  {{- range $route := (lookup "route.openshift.io/v1" "Route" $ns "").items -}}
    {{- if or (contains "keycloak" $route.metadata.name) (contains "sso" $route.metadata.name) -}}
      {{- $scheme := "https" -}}
      {{- if not $route.spec.tls -}}
        {{- $scheme = "http" -}}
      {{- end -}}
      {{- $found = printf "%s://%s" $scheme $route.spec.host -}}
    {{- end -}}
  {{- end -}}
  {{- $found -}}
{{- end -}}
{{- end }}

{{/*
Get Keycloak URL from Kubernetes Ingress
Returns empty string if not found
*/}}
{{- define "cost-onprem.keycloak.getUrlFromIngress" -}}
{{- $ns := include "cost-onprem.keycloak.namespace" . -}}
{{- if $ns -}}
  {{- $found := "" -}}
  {{- range $ing := (lookup "networking.k8s.io/v1" "Ingress" $ns "").items -}}
    {{- if or (contains "keycloak" $ing.metadata.name) (contains "sso" $ing.metadata.name) -}}
      {{- if $ing.spec.rules -}}
        {{- $host := (index $ing.spec.rules 0).host -}}
        {{- $scheme := "http" -}}
        {{- if $ing.spec.tls -}}
          {{- $scheme = "https" -}}
        {{- end -}}
        {{- $found = printf "%s://%s" $scheme $host -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $found -}}
{{- end -}}
{{- end }}

{{/*
Get Keycloak URL from Service (fallback - constructs internal cluster URL)
Returns empty string if service not found
*/}}
{{- define "cost-onprem.keycloak.getUrlFromService" -}}
{{- $ns := include "cost-onprem.keycloak.namespace" . -}}
{{- $svcName := include "cost-onprem.keycloak.serviceName" . -}}
{{- if and $ns $svcName -}}
  {{- $servicePort := .Values.jwtAuth.keycloak.servicePort | default 8080 -}}
  {{- printf "http://%s.%s.svc.cluster.local:%v" $svcName $ns $servicePort -}}
{{- end -}}
{{- end }}

{{/*
Get Keycloak route URL (OpenShift) or construct service URL (Kubernetes)
First try to get URL from Keycloak CR status, then fallback to route/ingress discovery
Only supports RHBK (v2alpha1) operator
*/}}
{{- define "cost-onprem.keycloak.url" -}}
{{- /* 1. Check for explicit override from values (set via --set or values.yaml) */ -}}
{{- if and .Values.jwtAuth .Values.jwtAuth.keycloak .Values.jwtAuth.keycloak.url -}}
  {{- .Values.jwtAuth.keycloak.url -}}
{{- else -}}
  {{- /* 2. Try to get URL from Keycloak CR status */ -}}
  {{- $url := include "cost-onprem.keycloak.getUrlFromCR" . -}}
  {{- if $url -}}
    {{- $url -}}
  {{- else if (include "cost-onprem.platform.isOpenShift" .) -}}
    {{- /* 3. OpenShift: Try route discovery */ -}}
    {{- $url = include "cost-onprem.keycloak.getUrlFromRoute" . -}}
    {{- if $url -}}
      {{- $url -}}
    {{- else -}}
      {{- /* 4. Final fallback: service URL */ -}}
      {{- include "cost-onprem.keycloak.getUrlFromService" . -}}
    {{- end -}}
  {{- else -}}
    {{- /* 3. Kubernetes: Try ingress discovery */ -}}
    {{- $url = include "cost-onprem.keycloak.getUrlFromIngress" . -}}
    {{- if $url -}}
      {{- $url -}}
    {{- else -}}
      {{- /* 4. Final fallback: service URL */ -}}
      {{- include "cost-onprem.keycloak.getUrlFromService" . -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Get complete Keycloak issuer URL with realm
*/}}
{{- define "cost-onprem.keycloak.issuerUrl" -}}
{{- $baseUrl := "" -}}
{{- if .Values.jwtAuth.keycloak.url -}}
  {{- /* Use explicitly configured URL */ -}}
  {{- $baseUrl = .Values.jwtAuth.keycloak.url -}}
{{- else -}}
  {{- /* Auto-detect Keycloak URL */ -}}
  {{- $baseUrl = include "cost-onprem.keycloak.url" . -}}
{{- end -}}
{{- if $baseUrl -}}
  {{- /* RHBK v22+ uses /realms/ without /auth prefix */ -}}
  {{- printf "%s/realms/%s" $baseUrl .Values.jwtAuth.keycloak.realm -}}
{{- else -}}
  {{- /* No Keycloak URL found - fail with helpful message (OpenShift only) */ -}}
  {{- fail "Keycloak URL not found on OpenShift cluster. JWT authentication requires Red Hat Build of Keycloak. Please either:\n  1. Set jwtAuth.keycloak.url in values.yaml, or\n  2. Ensure Keycloak is deployed with a Route in a common namespace (keycloak, sso), or\n  3. Deploy Keycloak using the provided scripts/deploy-rhbk.sh script\n\nNote: JWT authentication is only supported on OpenShift. For KIND/Kubernetes, authentication is automatically disabled." -}}
{{- end -}}
{{- end }}

{{/*
Get Keycloak JWKS URL
*/}}
{{- define "cost-onprem.keycloak.jwksUrl" -}}
{{- printf "%s/protocol/openid-connect/certs" (include "cost-onprem.keycloak.issuerUrl" .) -}}
{{- end }}

{{/*
Get Keycloak CR information for debugging
Only supports RHBK (v2alpha1) operator
*/}}
{{- define "cost-onprem.keycloak.crInfo" -}}
{{- $info := dict -}}
{{- $_ := set $info "apiVersion" "k8s.keycloak.org/v2alpha1" -}}
{{- $_ := set $info "operator" "RHBK" -}}
{{- /* Look for RHBK v2alpha1 CRs */ -}}
{{- $keycloaks := lookup "k8s.keycloak.org/v2alpha1" "Keycloak" "" "" -}}
{{- if $keycloaks -}}
  {{- if $keycloaks.items -}}
    {{- if gt (len $keycloaks.items) 0 -}}
      {{- $keycloak := index $keycloaks.items 0 -}}
      {{- $_ := set $info "found" true -}}
      {{- $_ := set $info "name" $keycloak.metadata.name -}}
      {{- $_ := set $info "namespace" $keycloak.metadata.namespace -}}
      {{- if $keycloak.status -}}
        {{- if $keycloak.status.conditions -}}
          {{- $_ := set $info "ready" (eq (index $keycloak.status.conditions 0).status "True") -}}
        {{- end -}}
        {{- if $keycloak.status.hostname -}}
          {{- $_ := set $info "externalURL" (printf "https://%s" $keycloak.status.hostname) -}}
        {{- end -}}
      {{- end -}}
      {{- if $keycloak.spec -}}
        {{- $_ := set $info "instances" $keycloak.spec.instances -}}
        {{- if $keycloak.spec.ingress -}}
          {{- $_ := set $info "ingressEnabled" (default false $keycloak.spec.ingress.enabled) -}}
        {{- end -}}
      {{- end -}}
    {{- else -}}
      {{- $_ := set $info "found" false -}}
    {{- end -}}
  {{- else -}}
    {{- $_ := set $info "found" false -}}
  {{- end -}}
{{- else -}}
  {{- $_ := set $info "found" false -}}
  {{- $_ := set $info "crdAvailable" false -}}
{{- end -}}
{{- $info | toYaml -}}
{{- end }}

{{/*
Check if JWT authentication should be enabled
Auto-detects based on platform: true for OpenShift, false for KIND/K8s
JWT authentication requires Keycloak, which is only deployed on OpenShift
*/}}
{{- define "cost-onprem.jwt.shouldEnable" -}}
{{- include "cost-onprem.platform.isOpenShift" . -}}
{{- end }}

{{/*
Kafka service host resolver (supports both internal Strimzi and external Kafka)
*/}}
{{- define "cost-onprem.kafka.host" -}}
{{- if .Values.kafka.bootstrapServers -}}
  {{- $bootstrapServers := .Values.kafka.bootstrapServers -}}
  {{- if contains "," $bootstrapServers -}}
    {{- $firstServer := regexFind "^[^,]+" $bootstrapServers -}}
    {{- if contains ":" $firstServer -}}
{{- regexFind "^[^:]+" $firstServer -}}
    {{- else -}}
{{- $firstServer -}}
    {{- end -}}
  {{- else -}}
    {{- if contains ":" $bootstrapServers -}}
{{- regexFind "^[^:]+" $bootstrapServers -}}
    {{- else -}}
{{- $bootstrapServers -}}
    {{- end -}}
  {{- end -}}
{{- else -}}
{{- .Release.Name }}-kafka-kafka-bootstrap.kafka.svc.cluster.local
{{- end -}}
{{- end }}

{{/*
Kafka port resolver (supports both internal Strimzi and external Kafka)
*/}}
{{- define "cost-onprem.kafka.port" -}}
{{- if .Values.kafka.bootstrapServers -}}
  {{- $bootstrapServers := .Values.kafka.bootstrapServers -}}
  {{- if contains "," $bootstrapServers -}}
    {{- $firstServer := regexFind "^[^,]+" $bootstrapServers -}}
    {{- if contains ":" $firstServer -}}
{{- regexFind "[^:]+$" $firstServer -}}
    {{- else -}}
9092
    {{- end -}}
  {{- else -}}
    {{- if contains ":" $bootstrapServers -}}
{{- regexFind "[^:]+$" $bootstrapServers -}}
    {{- else -}}
9092
    {{- end -}}
  {{- end -}}
{{- else -}}
9092
{{- end -}}
{{- end }}

{{/*
Kafka bootstrap servers resolver (supports both internal Strimzi and external Kafka)
*/}}
{{- define "cost-onprem.kafka.bootstrapServers" -}}
{{- if .Values.kafka.bootstrapServers -}}
{{- .Values.kafka.bootstrapServers -}}
{{- else -}}
{{- .Release.Name }}-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092
{{- end -}}
{{- end }}

{{/*
Kafka security protocol resolver (supports both internal Strimzi and external Kafka)
*/}}
{{- define "cost-onprem.kafka.securityProtocol" -}}
{{- .Values.kafka.securityProtocol | default "PLAINTEXT" -}}
{{- end }}

{{/*
Valkey fsGroup resolver (dynamically detects from namespace SCC annotations for OCP 4.20 compatibility)
Returns the fsGroup value from:
1. Explicit value set via .Values.valkey.securityContext.fsGroup (from script or user)
2. Or lookup() the namespace's supplemental-groups annotation (fallback for standalone helm upgrade)
This ensures Valkey can write to persistent volumes in OCP 4.20+ while remaining compatible with 4.18
*/}}
{{- define "cost-onprem.valkey.fsGroup" -}}
{{- if and (hasKey .Values.valkey "securityContext") (hasKey .Values.valkey.securityContext "fsGroup") .Values.valkey.securityContext.fsGroup -}}
  {{- .Values.valkey.securityContext.fsGroup -}}
{{- else -}}
  {{- $ns := lookup "v1" "Namespace" "" .Release.Namespace -}}
  {{- if $ns -}}
    {{- $suppGroups := index $ns.metadata.annotations "openshift.io/sa.scc.supplemental-groups" | default "" -}}
    {{- if $suppGroups -}}
      {{- /* Extract first number from "1000740000/10000" format */ -}}
      {{- $parts := splitList "/" $suppGroups -}}
      {{- if gt (len $parts) 0 -}}
        {{- index $parts 0 -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}