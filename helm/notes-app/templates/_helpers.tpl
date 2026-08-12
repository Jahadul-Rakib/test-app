{{- define "notes-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "notes-app.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "notes-app.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "notes-app.labels" -}}
app.kubernetes.io/name: {{ include "notes-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "notes-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "notes-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
