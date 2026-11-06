{{- define "wiki.labels" -}}
app.kubernetes.io/name: wiki
app.kubernetes.io/part-of: conservices
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "wiki.podSecurity" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "wiki.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- define "wiki.image" -}}
{{- $img := index .root.Values.image .name -}}
{{- printf "%s:%s" $img.repository (required (printf "image.%s.tag is required (MAJOR.MINOR.PATCH-BUILD)" .name) $img.tag) -}}
{{- end -}}
