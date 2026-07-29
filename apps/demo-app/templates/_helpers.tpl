{{- define "demo-app.fullname" -}}
{{- printf "%s-%s" .Chart.Name .Values.environment | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "demo-app.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Values.environment }}
app.kubernetes.io/managed-by: argocd
environment: {{ .Values.environment }}
{{- end }}

{{- define "demo-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "demo-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
