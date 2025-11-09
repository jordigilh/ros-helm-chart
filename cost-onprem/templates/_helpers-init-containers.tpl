{{/*
Reusable Init Container Templates
*/}}

{{/*
Wait for Database init container
Usage: {{ include "cost-mgmt.initContainer.waitForDb" (list . "ros") | nindent 8 }}
Parameters:
  - Root context (.)
  - Database type ("ros", "kruize", "sources")
*/}}
{{- define "cost-mgmt.initContainer.waitForDb" -}}
{{- $root := index . 0 -}}
{{- $dbType := index . 1 -}}
- name: wait-for-db-{{ $dbType }}
  image: "{{ $root.Values.global.initContainers.waitFor.repository }}:{{ $root.Values.global.initContainers.waitFor.tag }}"
  securityContext:
    runAsNonRoot: true
    {{- if eq (include "cost-mgmt.platform.isOpenShift" $root) "false" }}
    runAsUser: 1000
    {{- end }}
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
  command: ['bash', '-c']
  args:
    - |
      echo "Waiting for {{ $dbType }} database at {{ include "cost-mgmt.fullname" $root }}-db-{{ $dbType }}:{{ index $root.Values.database $dbType "port" }}..."
      until timeout 3 bash -c "echo > /dev/tcp/{{ include "cost-mgmt.fullname" $root }}-db-{{ $dbType }}/{{ index $root.Values.database $dbType "port" }}" 2>/dev/null; do
        echo "Database not ready yet, retrying in 5 seconds..."
        sleep 5
      done
      echo "{{ $dbType }} database is ready"
{{- end -}}

{{/*
Wait for Kafka init container
Usage: {{ include "cost-mgmt.initContainer.waitForKafka" . | nindent 8 }}
*/}}
{{- define "cost-mgmt.initContainer.waitForKafka" -}}
- name: wait-for-kafka
  image: "{{ .Values.global.initContainers.waitFor.repository }}:{{ .Values.global.initContainers.waitFor.tag }}"
  securityContext:
    runAsNonRoot: true
    {{- if eq (include "cost-mgmt.platform.isOpenShift" .) "false" }}
    runAsUser: 1000
    {{- end }}
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
  command: ['bash', '-c']
  args:
    - |
      echo "Waiting for Kafka at {{ include "cost-mgmt.kafka.host" . }}:{{ include "cost-mgmt.kafka.port" . }}..."
      until timeout 3 bash -c "echo > /dev/tcp/{{ include "cost-mgmt.kafka.host" . }}/{{ include "cost-mgmt.kafka.port" . }}" 2>/dev/null; do
        echo "Kafka not ready yet, retrying in 5 seconds..."
        sleep 5
      done
      echo "Kafka is ready"
{{- end -}}

{{/*
Wait for Storage (MinIO/ODF) init container
Usage: {{ include "cost-mgmt.initContainer.waitForStorage" . | nindent 8 }}
*/}}
{{- define "cost-mgmt.initContainer.waitForStorage" -}}
- name: wait-for-storage
  image: "{{ .Values.global.initContainers.waitFor.repository }}:{{ .Values.global.initContainers.waitFor.tag }}"
  securityContext:
    runAsNonRoot: true
    {{- if eq (include "cost-mgmt.platform.isOpenShift" .) "false" }}
    runAsUser: 1000
    {{- end }}
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
  command: ['bash', '-c']
  args:
    {{- if (eq (include "cost-mgmt.platform.isOpenShift" .) "false") }}
    - |
      echo "Waiting for MinIO at {{ include "cost-mgmt.fullname" . }}-minio:{{ .Values.minio.ports.api }}..."
      until timeout 3 bash -c "echo > /dev/tcp/{{ include "cost-mgmt.fullname" . }}-minio/{{ .Values.minio.ports.api }}" 2>/dev/null; do
        echo "MinIO not ready yet, retrying in 5 seconds..."
        sleep 5
      done
      echo "MinIO is ready"
    {{- else }}
    - |
      echo "Waiting for ODF S3 endpoint at {{ include "cost-mgmt.storage.endpoint" . }}:{{ include "cost-mgmt.storage.port" . }}..."
      until timeout 3 bash -c "echo > /dev/tcp/{{ include "cost-mgmt.storage.endpoint" . }}/{{ include "cost-mgmt.storage.port" . }}" 2>/dev/null; do
        echo "ODF S3 endpoint not ready yet, retrying in 5 seconds..."
        sleep 5
      done
      echo "ODF S3 endpoint is ready"
    {{- end }}
{{- end -}}

{{/*
Prepare CA bundle init container (for JWT/Keycloak TLS validation)
Usage: {{ include "cost-mgmt.initContainer.prepareCABundle" . | nindent 8 }}
*/}}
{{- define "cost-mgmt.initContainer.prepareCABundle" -}}
- name: prepare-ca-bundle
  image: "{{ .Values.global.initContainers.waitFor.repository }}:{{ .Values.global.initContainers.waitFor.tag }}"
  securityContext:
    runAsNonRoot: true
    {{- if eq (include "cost-mgmt.platform.isOpenShift" .) "false" }}
    runAsUser: 1000
    {{- end }}
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
  command: ['bash', '/scripts/combine-ca.sh']
  volumeMounts:
    - name: ca-scripts
      mountPath: /scripts
      readOnly: true
    - name: ca-source
      mountPath: /ca-source
      readOnly: true
    - name: ca-bundle
      mountPath: /ca-output
{{- end -}}
