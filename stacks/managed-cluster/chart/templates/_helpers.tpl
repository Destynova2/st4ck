{{/*
========================================================================
st4ck-managed-cluster — template helpers
========================================================================
Naming convention:
  - Tenant name (DNS label) is the single source of truth.
  - Namespace defaults to "tenant-<name>".
  - Context id mirrors the st4ck context format used in state paths.
========================================================================
*/}}

{{- define "st4ck.fullname" -}}
{{- .Values.tenant.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "st4ck.namespace" -}}
{{- if .Values.tenant.namespace -}}
{{- .Values.tenant.namespace -}}
{{- else -}}
{{- printf "tenant-%s" .Values.tenant.name -}}
{{- end -}}
{{- end -}}

{{- define "st4ck.contextId" -}}
{{- printf "st4ck-tenant-%s-%s" .Values.tenant.name .Values.scaleway.region -}}
{{- end -}}

{{- define "st4ck.kmsKeyName" -}}
{{- if .Values.encryption.keyName -}}
{{- .Values.encryption.keyName -}}
{{- else -}}
{{- printf "tenant-%s" .Values.tenant.name -}}
{{- end -}}
{{- end -}}

{{- define "st4ck.kmsApproleSecret" -}}
{{- printf "%s-kms-approle" (include "st4ck.fullname" .) -}}
{{- end -}}

{{- define "st4ck.kmsPolicyName" -}}
{{- printf "kamaji-kms-tenant-%s" .Values.tenant.name -}}
{{- end -}}

{{- define "st4ck.kmsApproleName" -}}
{{- printf "kamaji-kms-tenant-%s" .Values.tenant.name -}}
{{- end -}}

{{- define "st4ck.encryptionConfigSecret" -}}
{{- printf "%s-encryption-config" (include "st4ck.fullname" .) -}}
{{- end -}}

{{- define "st4ck.tcpName" -}}
{{- include "st4ck.fullname" . -}}
{{- end -}}

{{- define "st4ck.etcdName" -}}
{{- printf "%s-etcd" (include "st4ck.fullname" .) -}}
{{- end -}}

{{- define "st4ck.dataStoreName" -}}
{{- printf "%s-etcd" (include "st4ck.fullname" .) -}}
{{- end -}}

{{- define "st4ck.scwClusterName" -}}
{{- printf "%s-scw" (include "st4ck.fullname" .) -}}
{{- end -}}

{{- define "st4ck.kamajiCPName" -}}
{{- printf "%s-cp" (include "st4ck.fullname" .) -}}
{{- end -}}

{{- define "st4ck.apiHost" -}}
{{- printf "%s-api.%s" .Values.tenant.name .Values.ingress.baseDomain -}}
{{- end -}}

{{/*
Standard labels applied to every rendered object.
*/}}
{{- define "st4ck.labels" -}}
app.kubernetes.io/name: st4ck-managed-cluster
app.kubernetes.io/instance: {{ include "st4ck.fullname" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
app.kubernetes.io/part-of: st4ck
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
st4ck.io/tenant: {{ .Values.tenant.name | quote }}
st4ck.io/context-id: {{ include "st4ck.contextId" . | quote }}
{{- end -}}

{{- define "st4ck.selectorLabels" -}}
app.kubernetes.io/name: st4ck-managed-cluster
app.kubernetes.io/instance: {{ include "st4ck.fullname" . | quote }}
st4ck.io/tenant: {{ .Values.tenant.name | quote }}
{{- end -}}

{{/*
Map controlPlane.apiServer.resourcesPreset → resource requests/limits.
Reused by the TenantControlPlane template.
*/}}
{{- define "st4ck.apiServerResources" -}}
{{- $preset := .Values.controlPlane.apiServer.resourcesPreset | default "small" -}}
{{- if eq $preset "large" -}}
requests:
  cpu: "1"
  memory: "2Gi"
limits:
  cpu: "4"
  memory: "8Gi"
{{- else if eq $preset "medium" -}}
requests:
  cpu: "500m"
  memory: "1Gi"
limits:
  cpu: "2"
  memory: "4Gi"
{{- else -}}
requests:
  cpu: "250m"
  memory: "512Mi"
limits:
  cpu: "2"
  memory: "2Gi"
{{- end -}}
{{- end -}}
