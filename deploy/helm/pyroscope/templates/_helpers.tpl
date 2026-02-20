{{/*
Chart name, truncated to 63 characters.
*/}}
{{- define "pyroscope.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified release name, truncated to 63 characters.
*/}}
{{- define "pyroscope.fullname" -}}
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
Common labels applied to every resource.
*/}}
{{- define "pyroscope.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "pyroscope.name" . }}
{{- end }}

{{/*
Component labels — call with (dict "ctx" . "component" "<name>").
Includes common labels plus name and component.
*/}}
{{- define "pyroscope.componentLabels" -}}
{{ include "pyroscope.labels" .ctx }}
app.kubernetes.io/name: {{ include "pyroscope.name" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Selector labels — minimal set for matchLabels / selectors.
Call with (dict "ctx" . "component" "<name>").
*/}}
{{- define "pyroscope.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pyroscope.name" .ctx }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end }}

{{/*
Agent push endpoint — the URL Java agents should set as PYROSCOPE_SERVER_ADDRESS.
Monolith: the single service. Microservices: the distributor.
*/}}
{{- define "pyroscope.agentEndpoint" -}}
{{- $fullname := include "pyroscope.fullname" . -}}
{{- if eq .Values.mode "microservices" -}}
http://{{ $fullname }}-distributor.{{ .Release.Namespace }}.svc:4040
{{- else -}}
http://{{ $fullname }}.{{ .Release.Namespace }}.svc:4040
{{- end -}}
{{- end }}

{{/*
Grafana datasource endpoint — the URL Grafana should use to query Pyroscope.
Monolith: the single service. Microservices: query-frontend.
Computed based on grafana.location:
  same-namespace      → short DNS
  different-namespace → FQDN
  external            → placeholder (operator must use Route/Ingress URL)
*/}}
{{- define "pyroscope.grafanaEndpoint" -}}
{{- $fullname := include "pyroscope.fullname" . -}}
{{- $ns := .Release.Namespace -}}
{{- if .Values.grafana.datasource.urlOverride -}}
{{ .Values.grafana.datasource.urlOverride }}
{{- else if eq .Values.grafana.location "same-namespace" -}}
  {{- if eq .Values.mode "microservices" -}}
http://{{ $fullname }}-query-frontend:4040
  {{- else -}}
http://{{ $fullname }}:4040
  {{- end -}}
{{- else if eq .Values.grafana.location "different-namespace" -}}
  {{- if eq .Values.mode "microservices" -}}
http://{{ $fullname }}-query-frontend.{{ $ns }}.svc.cluster.local:4040
  {{- else -}}
http://{{ $fullname }}.{{ $ns }}.svc.cluster.local:4040
  {{- end -}}
{{- else -}}
EXTERNAL_URL_SEE_NOTES
{{- end -}}
{{- end }}

{{/*
Memberlist join address for microservices mode — uses the headless service DNS.
*/}}
{{- define "pyroscope.memberlistJoinAddress" -}}
{{ include "pyroscope.fullname" . }}-ingester-headless:7946
{{- end }}
