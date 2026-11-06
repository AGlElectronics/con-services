{{- define "tasks.labels" -}}
app.kubernetes.io/name: tasks
app.kubernetes.io/part-of: conservices
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "tasks.podSecurity" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "tasks.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- define "tasks.image" -}}
{{- $img := index .root.Values.image .name -}}
{{- printf "%s:%s" $img.repository (required (printf "image.%s.tag is required (MAJOR.MINOR.PATCH-BUILD)" .name) $img.tag) -}}
{{- end -}}
