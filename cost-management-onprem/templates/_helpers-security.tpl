{{/*
Reusable Security Context Templates
*/}}

{{/*
Standard non-root security context for containers
Usage: {{ include "cost-mgmt.securityContext.nonRoot" . | nindent 6 }}
*/}}
{{- define "cost-mgmt.securityContext.nonRoot" -}}
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
{{- end -}}

{{/*
Security context with read-only root filesystem
Usage: {{ include "cost-mgmt.securityContext.readOnlyRoot" . | nindent 6 }}
*/}}
{{- define "cost-mgmt.securityContext.readOnlyRoot" -}}
runAsNonRoot: true
{{- if eq (include "cost-mgmt.platform.isOpenShift" .) "false" }}
runAsUser: 1000
{{- end }}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop:
    - ALL
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/*
Security context for privileged operations (use sparingly)
Usage: {{ include "cost-mgmt.securityContext.privileged" . | nindent 6 }}
*/}}
{{- define "cost-mgmt.securityContext.privileged" -}}
allowPrivilegeEscalation: true
capabilities:
  add:
    - NET_ADMIN
    - NET_RAW
seccompProfile:
  type: RuntimeDefault
{{- end -}}
