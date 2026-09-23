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

{{/*
Labels shared by every pod this chart creates. The Service and Deployment
selectors add app.kubernetes.io/component=web on top of these, so hook and
maintenance pods (migrate, efs-bootstrap, backups, restore) never receive
Service traffic even though they carry the same name/instance labels.
*/}}
{{- define "laravel.commonLabels" -}}
app.kubernetes.io/name: laravel
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "laravel.selectorLabels" -}}
{{ include "laravel.commonLabels" . }}
app.kubernetes.io/component: web
{{- end }}

{{- define "laravel.labels" -}}
{{ include "laravel.selectorLabels" . }}
app.kubernetes.io/version: {{ (.Values.image.tag | default .Chart.AppVersion) | quote }}
{{- end }}

{{/*
Labels for a maintenance pod. Usage:
  {{ include "laravel.maintenanceLabels" (dict "root" . "component" "mysql-backup") }}
Every pod in the app namespace must carry app.kubernetes.io/name (admission policy).
*/}}
{{- define "laravel.maintenanceLabels" -}}
{{ include "laravel.commonLabels" .root }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/version: {{ (.root.Values.image.tag | default .root.Chart.AppVersion) | quote }}
{{- end }}

{{/*
Pod security context for pods based on the official mysql image (UID/GID 999).
*/}}
{{- define "laravel.mysqlToolsPodSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .Values.backup.runAsUser }}
runAsGroup: {{ .Values.backup.runAsUser }}
fsGroup: {{ .Values.backup.runAsUser }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "laravel.restrictedContainerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}

{{/*
Writable paths of the application image under a read-only root filesystem.
Each is an emptyDir: Laravel file cache, compiled Blade views, file sessions
(unused with the database driver, kept for artisan commands), log files
(unused with LOG_CHANNEL=stderr), PHP's /tmp, and Apache's pid and lock
directories. bootstrap/cache is generated at build time and stays read-only.
*/}}
{{- define "laravel.appWritablePaths" -}}
- name: tmp
  mountPath: /tmp
- name: storage-cache
  mountPath: /var/www/html/storage/framework/cache
- name: storage-views
  mountPath: /var/www/html/storage/framework/views
- name: storage-sessions
  mountPath: /var/www/html/storage/framework/sessions
- name: storage-logs
  mountPath: /var/www/html/storage/logs
{{- end }}

{{- define "laravel.apacheWritablePaths" -}}
- name: apache-run
  mountPath: /var/run/apache2
- name: apache-lock
  mountPath: /var/lock/apache2
{{- end }}

{{- define "laravel.appWritableVolumes" -}}
- name: tmp
  emptyDir: {}
- name: storage-cache
  emptyDir: {}
- name: storage-views
  emptyDir: {}
- name: storage-sessions
  emptyDir: {}
- name: storage-logs
  emptyDir: {}
{{- end }}

{{- define "laravel.apacheWritableVolumes" -}}
- name: apache-run
  emptyDir: {}
- name: apache-lock
  emptyDir: {}
{{- end }}
