{{/*
Expand the name of the chart.
*/}}
{{/* prettier-ignore */}}
{{- define "ros-ocp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "ros-ocp.fullname" -}}
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
{{- define "ros-ocp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ros-ocp.labels" -}}
helm.sh/chart: {{ include "ros-ocp.chart" . }}
{{ include "ros-ocp.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ros-ocp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ros-ocp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "ros-ocp.serviceAccountName" -}}
  {{- if .Values.serviceAccount.create -}}
{{- default (include "ros-ocp.fullname" .) .Values.serviceAccount.name -}}
  {{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
  {{- end -}}
{{- end }}

{{/*
Generic database host resolver - returns internal service name if "internal", otherwise returns the configured host
Usage: {{ include "ros-ocp.databaseHost" (list . "ros") }}
*/}}
{{- define "ros-ocp.databaseHost" -}}
  {{- $root := index . 0 -}}
  {{- $dbType := index . 1 -}}
  {{- $hostValue := index $root.Values.database $dbType "host" -}}
  {{- if eq $hostValue "internal" -}}
{{- printf "%s-db-%s" (include "ros-ocp.fullname" $root) $dbType -}}
  {{- else -}}
{{- $hostValue -}}
  {{- end -}}
{{- end }}

{{/*
Get the database URL - returns complete postgresql connection string
*/}}
{{- define "ros-ocp.databaseUrl" -}}
{{- printf "postgresql://postgres:$(DB_PASSWORD)@%s:%s/%s?sslmode=%s" (include "ros-ocp.databaseHost" (list . "ros")) (.Values.database.ros.port | toString) .Values.database.ros.name .Values.database.ros.sslMode }}
{{- end }}

{{/*
Get the kruize database host - returns internal service name if "internal", otherwise returns the configured host
*/}}
{{- define "ros-ocp.kruizeDatabaseHost" -}}
{{- include "ros-ocp.databaseHost" (list . "kruize") -}}
{{- end }}

{{/*
Get the sources database host - returns internal service name if "internal", otherwise returns the configured host
*/}}
{{- define "ros-ocp.sourcesDatabaseHost" -}}
{{- include "ros-ocp.databaseHost" (list . "sources") -}}
{{- end }}

{{/*
Detect if running on OpenShift by checking for OpenShift-specific API resources
Returns true if OpenShift is detected, false otherwise
*/}}
{{- define "ros-ocp.isOpenShift" -}}
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
{{- define "ros-ocp.getDomainFromIngressConfig" -}}
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
{{- define "ros-ocp.getDomainFromIngressController" -}}
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
{{- define "ros-ocp.getDomainFromRoutes" -}}
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
Usage: {{ include "ros-ocp.clusterDomain" . }}
*/}}
{{- define "ros-ocp.clusterDomain" -}}
  {{- /* Try multiple strategies to detect cluster domain */ -}}
  {{- $domain := include "ros-ocp.getDomainFromIngressConfig" . -}}
  {{- if eq $domain "" -}}
    {{- $domain = include "ros-ocp.getDomainFromIngressController" . -}}
  {{- end -}}
  {{- if eq $domain "" -}}
    {{- $domain = include "ros-ocp.getDomainFromRoutes" . -}}
  {{- end -}}

  {{- if eq $domain "" -}}
    {{- /* STRICT MODE: Fail if cluster domain cannot be detected */ -}}
{{- fail "ERROR: Unable to detect OpenShift cluster domain. Ensure you are deploying to a properly configured OpenShift cluster with ingress controllers and routes. Dynamic detection failed for: config.openshift.io/v1/Ingress, operator.openshift.io/v1/IngressController, and existing Routes." -}}
  {{- else -}}
{{- $domain -}}
  {{- end -}}
{{- end }}

{{/*
Extract cluster name from Infrastructure resource
Returns name if found, empty string otherwise
*/}}
{{- define "ros-ocp.getClusterNameFromInfrastructure" -}}
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
{{- define "ros-ocp.getClusterNameFromClusterVersion" -}}
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
Usage: {{ include "ros-ocp.clusterName" . }}
*/}}
{{- define "ros-ocp.clusterName" -}}
  {{- /* Try multiple strategies to detect cluster name */ -}}
  {{- $name := include "ros-ocp.getClusterNameFromInfrastructure" . -}}
  {{- if eq $name "" -}}
    {{- $name = include "ros-ocp.getClusterNameFromClusterVersion" . -}}
  {{- end -}}

  {{- if eq $name "" -}}
    {{- /* STRICT MODE: Fail if cluster name cannot be detected */ -}}
{{- fail "ERROR: Unable to detect OpenShift cluster name. Ensure you are deploying to a properly configured OpenShift cluster. Dynamic detection failed for: config.openshift.io/v1/Infrastructure and config.openshift.io/v1/ClusterVersion resources." -}}
  {{- else -}}
{{- $name -}}
  {{- end -}}
{{- end }}

{{/*
Generate external URL for a service based on deployment platform (OpenShift Routes vs Kubernetes Ingress)
Usage: {{ include "ros-ocp.externalUrl" (list . "service-name" "/path") }}
*/}}
{{- define "ros-ocp.externalUrl" -}}
  {{- $root := index . 0 -}}
  {{- $service := index . 1 -}}
  {{- $path := index . 2 -}}
  {{- if eq (include "ros-ocp.isOpenShift" $root) "true" -}}
    {{- /* OpenShift: Use Route configuration */ -}}
    {{- $scheme := "http" -}}
    {{- if $root.Values.serviceRoute.tls.termination -}}
      {{- $scheme = "https" -}}
    {{- end -}}
    {{- with (index $root.Values.serviceRoute.hosts 0) -}}
      {{- if .host -}}
{{- printf "%s://%s%s" $scheme .host $path -}}
      {{- else -}}
{{- printf "%s://%s-%s.%s%s" $scheme $service $root.Release.Namespace (include "ros-ocp.clusterDomain" $root) $path -}}
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
Usage: {{ include "ros-ocp.volumeMode" . }}
*/}}
{{- define "ros-ocp.volumeMode" -}}
  {{- $storageClass := include "ros-ocp.databaseStorageClass" . -}}
{{- include "ros-ocp.volumeModeForStorageClass" (list . $storageClass) -}}
{{- end }}

{{/*
Get storage class name - validates user-defined storage class exists, falls back to default
Handles dry-run mode gracefully, fails deployment only if no suitable storage class is found during actual installation
Usage: {{ include "ros-ocp.storageClass" . }}
*/}}
{{- define "ros-ocp.storageClass" -}}
  {{- $storageClasses := lookup "storage.k8s.io/v1" "StorageClass" "" "" -}}
  {{- $userDefinedClass := include "ros-ocp.getUserDefinedStorageClass" . -}}

  {{- /* Handle dry-run mode or cluster connectivity issues */ -}}
  {{- if not (and $storageClasses $storageClasses.items) -}}
    {{- if $userDefinedClass -}}
      {{- /* In dry-run mode, trust the user-defined storage class */ -}}
{{- $userDefinedClass -}}
    {{- else -}}
      {{- /* In dry-run mode with no explicit storage class, use a reasonable default */ -}}
{{- include "ros-ocp.getPlatformDefaultStorageClass" . -}}
    {{- end -}}
  {{- else -}}
    {{- /* Normal operation - query cluster for available storage classes */ -}}
    {{- $defaultFound := include "ros-ocp.findDefaultStorageClass" . -}}
    {{- $userClassExists := include "ros-ocp.userStorageClassExists" . -}}

    {{- if $userDefinedClass -}}
      {{- if eq $userClassExists "true" -}}
{{- $userDefinedClass -}}
      {{- else -}}
        {{- if $defaultFound -}}
          {{- printf "# Warning: Storage class '%s' not found, using default '%s' instead" $userDefinedClass $defaultFound | println -}}
{{- $defaultFound -}}
        {{- else -}}
{{- fail (printf "Storage class '%s' not found and no default storage class available. Available storage classes: %s" $userDefinedClass (join ", " (pluck "metadata.name" $storageClasses.items))) -}}
        {{- end -}}
      {{- end -}}
    {{- else -}}
      {{- if $defaultFound -}}
{{- $defaultFound -}}
      {{- else -}}
{{- fail (printf "No default storage class found in cluster. Available storage classes: %s\nPlease either:\n1. Set a default storage class with 'storageclass.kubernetes.io/is-default-class=true' annotation, or\n2. Explicitly specify a storage class with 'global.storageClass'" (join ", " (pluck "metadata.name" $storageClasses.items))) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end }}

{{/*
Extract user-defined storage class from values
Returns the storage class name if defined, empty string otherwise
*/}}
{{- define "ros-ocp.getUserDefinedStorageClass" -}}
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
{{- define "ros-ocp.getPlatformDefaultStorageClass" -}}
  {{- if eq (include "ros-ocp.isOpenShift" .) "true" -}}
ocs-storagecluster-ceph-rbd
  {{- else -}}
standard
  {{- end -}}
{{- end }}

{{/*
Find default storage class from cluster
Returns the name of the default storage class if found, empty string otherwise
*/}}
{{- define "ros-ocp.findDefaultStorageClass" -}}
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
{{- define "ros-ocp.userStorageClassExists" -}}
  {{- $userDefinedClass := include "ros-ocp.getUserDefinedStorageClass" . -}}
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
Usage: {{ include "ros-ocp.databaseStorageClass" . }}
*/}}
{{- define "ros-ocp.databaseStorageClass" -}}
{{- include "ros-ocp.storageClass" . -}}
{{- end }}

{{/*
Check if a provisioner supports filesystem volumes
Returns true if the provisioner is known to support filesystem volumes
Usage: {{ include "ros-ocp.supportsFilesystem" (list . $provisioner $parameters $isOpenShift) }}
*/}}
{{- define "ros-ocp.supportsFilesystem" -}}
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
Usage: {{ include "ros-ocp.supportsBlock" (list . $provisioner $parameters $isOpenShift) }}
*/}}
{{- define "ros-ocp.supportsBlock" -}}
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
Usage: {{ include "ros-ocp.volumeModeForStorageClass" (list . "storage-class-name") }}
*/}}
{{- define "ros-ocp.volumeModeForStorageClass" -}}
  {{- $root := index . 0 -}}
  {{- $storageClassName := index . 1 -}}
  {{- $isOpenShift := eq (include "ros-ocp.isOpenShift" $root) "true" -}}

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
        {{- $supportsFilesystem := include "ros-ocp.supportsFilesystem" (list $root $provisioner $parameters $isOpenShift) -}}
        {{- $supportsBlock := include "ros-ocp.supportsBlock" (list $root $provisioner $parameters $isOpenShift) -}}

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
Cache service name (redis or valkey based on platform)
*/}}
{{- define "ros-ocp.cache.name" -}}
{{- if eq (include "ros-ocp.isOpenShift" .) "true" -}}
valkey
{{- else -}}
redis
{{- end -}}
{{- end }}

{{/*
Cache configuration (returns the appropriate config object)
*/}}
{{- define "ros-ocp.cache.config" -}}
{{- if eq (include "ros-ocp.isOpenShift" .) "true" -}}
{{- .Values.valkey | toYaml -}}
{{- else -}}
{{- .Values.redis | toYaml -}}
{{- end -}}
{{- end }}

{{/*
Cache CLI command (redis-cli or valkey-cli based on platform)
*/}}
{{- define "ros-ocp.cache.cli" -}}
{{- if eq (include "ros-ocp.isOpenShift" .) "true" -}}
valkey-cli
{{- else -}}
redis-cli
{{- end -}}
{{- end }}

{{/*
Storage service name (minio or odf based on platform)
*/}}
{{- define "ros-ocp.storage.name" -}}
{{- if eq (include "ros-ocp.isOpenShift" .) "true" -}}
odf
{{- else -}}
minio
{{- end -}}
{{- end }}

{{/*
Storage configuration (returns the appropriate config object)
*/}}
{{- define "ros-ocp.storage.config" -}}
{{- if eq (include "ros-ocp.isOpenShift" .) "true" -}}
{{- .Values.odf | toYaml -}}
{{- else -}}
{{- .Values.minio | toYaml -}}
{{- end -}}
{{- end }}

{{/*
Storage endpoint (MinIO service or ODF endpoint)
*/}}
{{- define "ros-ocp.storage.endpoint" -}}
{{- if eq (include "ros-ocp.isOpenShift" .) "true" -}}
{{- if .Values.odf.endpoint -}}
{{- .Values.odf.endpoint | quote -}}
{{- else -}}
{{- /* Dynamic ODF S3 service discovery using NooBaa CRD status */ -}}
{{- $noobaaList := lookup "noobaa.io/v1alpha1" "NooBaa" "" "" -}}
{{- $s3Endpoint := "" -}}
{{- if and $noobaaList $noobaaList.items -}}
  {{- range $noobaaList.items -}}
    {{- if and .status .status.services .status.services.serviceS3 .status.services.serviceS3.internalDNS -}}
      {{- $internalDNS := index .status.services.serviceS3.internalDNS 0 -}}
      {{- if $internalDNS -}}
        {{- /* Extract service name from internal DNS (e.g., "https://s3.openshift-storage.svc:443" -> "s3.openshift-storage.svc.cluster.local") */ -}}
        {{- $serviceName := regexReplaceAll "https://" $internalDNS "" -}}
        {{- $serviceName = regexReplaceAll ":443" $serviceName "" -}}
        {{- /* Convert short DNS to full cluster DNS (e.g., "s3.openshift-storage.svc" -> "s3.openshift-storage.svc.cluster.local") */ -}}
        {{- if not (hasSuffix ".cluster.local" $serviceName) -}}
          {{- $serviceName = printf "%s.cluster.local" $serviceName -}}
        {{- end -}}
        {{- $s3Endpoint = $serviceName -}}
        {{- break -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if $s3Endpoint -}}
{{- $s3Endpoint | quote -}}
{{- else -}}
{{- fail "Unable to discover ODF S3 service endpoint. Please ensure OpenShift Data Foundation is installed and specify 'odf.endpoint' in values.yaml" -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- printf "%s-minio:%v" (include "ros-ocp.fullname" .) .Values.minio.ports.api | quote -}}
{{- end -}}
{{- end }}

{{/*
Storage port (MinIO port or ODF port)
*/}}
{{- define "ros-ocp.storage.port" -}}
{{- if eq (include "ros-ocp.isOpenShift" .) "true" -}}
{{- .Values.odf.port -}}
{{- else -}}
{{- .Values.minio.ports.api -}}
{{- end -}}
{{- end }}

{{/*
Storage access key (MinIO root user - ODF uses noobaa-admin secret directly)
*/}}
{{- define "ros-ocp.storage.accessKey" -}}
{{- .Values.minio.rootUser -}}
{{- end }}

{{/*
Storage secret key (MinIO root password - ODF uses noobaa-admin secret directly)
*/}}
{{- define "ros-ocp.storage.secretKey" -}}
{{- .Values.minio.rootPassword -}}
{{- end }}

{{/*
Storage bucket name
*/}}
{{- define "ros-ocp.storage.bucket" -}}
{{- if eq (include "ros-ocp.isOpenShift" .) "true" -}}
{{- .Values.odf.bucket -}}
{{- else -}}
{{- .Values.ingress.storage.bucket -}}
{{- end -}}
{{- end }}

{{/*
Storage use SSL flag
*/}}
{{- define "ros-ocp.storage.useSSL" -}}
{{- if eq (include "ros-ocp.isOpenShift" .) "true" -}}
{{- .Values.odf.useSSL -}}
{{- else -}}
{{- .Values.ingress.storage.useSSL -}}
{{- end -}}
{{- end }}

{{/*
Keycloak Dynamic Configuration Helpers
*/}}

{{/*
Detect if Keycloak is installed in the cluster
This helper looks for common Keycloak resources to determine if it's available
*/}}
{{- define "ros-ocp.keycloak.isInstalled" -}}
{{- $keycloakFound := false -}}
{{- /* Try to find Keycloak by looking for common patterns */ -}}
{{- range $ns := (lookup "v1" "Namespace" "" "").items -}}
  {{- if or (contains "keycloak" $ns.metadata.name) (contains "rhsso" $ns.metadata.name) (contains "sso" $ns.metadata.name) -}}
    {{- $keycloakFound = true -}}
  {{- end -}}
{{- end -}}
{{- $keycloakFound -}}
{{- end }}

{{/*
Find Keycloak namespace by looking for common patterns
*/}}
{{- define "ros-ocp.keycloak.namespace" -}}
{{- $keycloakNs := "" -}}
{{- range $ns := (lookup "v1" "Namespace" "" "").items -}}
  {{- if or (contains "keycloak" $ns.metadata.name) (contains "rhsso" $ns.metadata.name) -}}
    {{- $keycloakNs = $ns.metadata.name -}}
    {{- break -}}
  {{- end -}}
{{- end -}}
{{- $keycloakNs -}}
{{- end }}

{{/*
Find Keycloak service name by looking in the detected namespace
*/}}
{{- define "ros-ocp.keycloak.serviceName" -}}
{{- $keycloakSvc := "" -}}
{{- $ns := include "ros-ocp.keycloak.namespace" . -}}
{{- if $ns -}}
  {{- range $svc := (lookup "v1" "Service" $ns "").items -}}
    {{- if or (contains "keycloak" $svc.metadata.name) (contains "sso" $svc.metadata.name) -}}
      {{- $keycloakSvc = $svc.metadata.name -}}
      {{- break -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $keycloakSvc -}}
{{- end }}

{{/*
Get Keycloak route URL (OpenShift) or construct service URL (Kubernetes)
*/}}
{{- define "ros-ocp.keycloak.url" -}}
{{- $keycloakUrl := "" -}}
{{- $ns := include "ros-ocp.keycloak.namespace" . -}}
{{- if $ns -}}
  {{- if (include "ros-ocp.isOpenShift" .) -}}
    {{- /* OpenShift: Look for Keycloak route */ -}}
    {{- range $route := (lookup "route.openshift.io/v1" "Route" $ns "").items -}}
      {{- if or (contains "keycloak" $route.metadata.name) (contains "sso" $route.metadata.name) -}}
        {{- $scheme := "https" -}}
        {{- if $route.spec.tls -}}
          {{- $scheme = "https" -}}
        {{- else -}}
          {{- $scheme = "http" -}}
        {{- end -}}
        {{- $keycloakUrl = printf "%s://%s" $scheme $route.spec.host -}}
        {{- break -}}
      {{- end -}}
    {{- end -}}
  {{- else -}}
    {{- /* Kubernetes: Look for Keycloak ingress or construct service URL */ -}}
    {{- $found := false -}}
    {{- range $ing := (lookup "networking.k8s.io/v1" "Ingress" $ns "").items -}}
      {{- if or (contains "keycloak" $ing.metadata.name) (contains "sso" $ing.metadata.name) -}}
        {{- if $ing.spec.rules -}}
          {{- $host := (index $ing.spec.rules 0).host -}}
          {{- $scheme := "http" -}}
          {{- if $ing.spec.tls -}}
            {{- $scheme = "https" -}}
          {{- end -}}
          {{- $keycloakUrl = printf "%s://%s" $scheme $host -}}
          {{- $found = true -}}
          {{- break -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- if not $found -}}
      {{- /* Fallback: construct service URL */ -}}
      {{- $svcName := include "ros-ocp.keycloak.serviceName" . -}}
      {{- if $svcName -}}
        {{- $keycloakUrl = printf "http://%s.%s.svc.cluster.local:8080" $svcName $ns -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $keycloakUrl -}}
{{- end }}

{{/*
Get complete Keycloak issuer URL with realm
*/}}
{{- define "ros-ocp.keycloak.issuerUrl" -}}
{{- $baseUrl := "" -}}
{{- if .Values.jwt_auth.keycloak.issuer.baseUrl -}}
  {{- /* Use explicitly configured URL */ -}}
  {{- $baseUrl = .Values.jwt_auth.keycloak.issuer.baseUrl -}}
{{- else -}}
  {{- /* Auto-detect Keycloak URL */ -}}
  {{- $baseUrl = include "ros-ocp.keycloak.url" . -}}
{{- end -}}
{{- if $baseUrl -}}
  {{- printf "%s/auth/realms/%s" $baseUrl .Values.jwt_auth.keycloak.issuer.realm -}}
{{- else -}}
  {{- /* Fallback URL for development */ -}}
  {{- printf "https://keycloak-rhsso.apps.stress.parodos.dev/auth/realms/%s" .Values.jwt_auth.keycloak.issuer.realm -}}
{{- end -}}
{{- end }}

{{/*
Get Keycloak JWKS URL
*/}}
{{- define "ros-ocp.keycloak.jwksUrl" -}}
{{- printf "%s/protocol/openid-connect/certs" (include "ros-ocp.keycloak.issuerUrl" .) -}}
{{- end }}

{{/*
Check if JWT authentication should be enabled
This enables JWT auth automatically if Keycloak is detected and jwt_auth.enabled is not explicitly set to false
*/}}
{{- define "ros-ocp.jwt.shouldEnable" -}}
{{- if hasKey .Values.jwt_auth "enabled" -}}
  {{- .Values.jwt_auth.enabled -}}
{{- else -}}
  {{- /* Auto-enable if Keycloak is detected */ -}}
  {{- include "ros-ocp.keycloak.isInstalled" . -}}
{{- end -}}
{{- end }}