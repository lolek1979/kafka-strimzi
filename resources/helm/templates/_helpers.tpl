# ==============================
# templates/_helpers.tpl
# ==============================

{{- /* ---- Namespaces ---- */ -}}
{{- define "kafka.ns" -}}{{ default "kafka"           .Values.namespaces.kafka          }}{{- end -}}
{{- define "kafka-ui.ns" -}}{{ default "kafka-ui"      .Values.namespaces.kafkaUi        }}{{- end -}}
{{- define "schema-registry.ns" -}}{{ default "schema-registry" .Values.namespaces.schemaRegistry }}{{- end -}}
{{- define "lag-exporter.ns" -}}{{ default "observability" .Values.namespaces.lagExporter }}{{- end -}}

{{- /* ---- Cluster name ---- */ -}}
{{- define "kafka.name" -}}
{{- if .Values.kafka.name }}{{ .Values.kafka.name }}{{ else }}kafka-cluster{{ end -}}
{{- end -}}

{{- /* ---- ServiceAccount used by AKV sync job ---- */ -}}
{{- define "tls.saName" -}}
{{- $raw := (index .Values "tls" "serviceAccount") | default "" | toString | trim -}}
{{- if $raw -}}{{ $raw }}{{- else -}}tls-writer{{- end -}}
{{- end -}}

{{/* ---- AAD issuer/token/jwks helpers (v1|v2) ---- */}}
{{- define "kafka.issuerUri" -}}
{{- $ver := .ver | default "v2" -}}
{{- $tid := .ctx.Values.azure.tenantId -}}
{{- if eq $ver "v1" -}}
https://sts.windows.net/{{ $tid }}/
{{- else -}}
https://login.microsoftonline.com/{{ $tid }}/v2.0
{{- end -}}
{{- end -}}

{{- define "kafka.tokenEndpoint" -}}
{{- $ver := .ver | default "v2" -}}
{{- $tid := .ctx.Values.azure.tenantId -}}
https://login.microsoftonline.com/{{ $tid }}/oauth2/{{ if eq $ver "v1" }}token{{ else }}v2.0/token{{ end }}
{{- end -}}

{{- define "kafka.jwksUri" -}}
{{- $tid := .ctx.Values.azure.tenantId -}}
https://login.microsoftonline.com/{{ $tid }}/discovery/v2.0/keys
{{- end -}}

{{/* ---- Expected audience: GUID by default (matches broker `clientId`/checkAudience) ---- */}}
{{- define "kafka.expectedAudience" -}}
{{- $explicit := .Values.kafka.oauth.expectedAudience | default "" -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- .Values.kafka.oauth.audienceAppId -}}
{{- end -}}
{{- end -}}
