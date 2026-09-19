{{- define "laravel.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "laravel.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "laravel.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "laravel.selectorLabels" -}}
app.kubernetes.io/name: laravel
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "laravel.labels" -}}
{{ include "laravel.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/component: web
{{- end }}
