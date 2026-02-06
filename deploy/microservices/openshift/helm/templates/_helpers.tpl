{{/*
Expand the name of the chart.
*/}}
{{- define "pyroscope.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
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
Common labels
*/}}
{{- define "pyroscope.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "pyroscope.name" . }}
{{- end }}

{{/*
Component labels — call with (dict "ctx" . "component" "distributor")
*/}}
{{- define "pyroscope.componentLabels" -}}
{{ include "pyroscope.labels" .ctx }}
app.kubernetes.io/name: {{ include "pyroscope.fullname" .ctx }}-{{ .component }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Selector labels for a component
*/}}
{{- define "pyroscope.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pyroscope.fullname" .ctx }}-{{ .component }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
