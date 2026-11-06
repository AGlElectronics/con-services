{{- define "rally.labels" -}}
app.kubernetes.io/name: rally
app.kubernetes.io/part-of: conservices
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "rally.podSecurity" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "rally.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- define "rally.image" -}}
{{- $img := index .root.Values.image .name -}}
{{- printf "%s:%s" $img.repository (required (printf "image.%s.tag is required (MAJOR.MINOR.PATCH-BUILD)" .name) $img.tag) -}}
{{- end -}}

{{/* nginx config for a Rally web app (staff app or submission site). */}}
{{- define "rally.nginx" -}}
upstream rally_backend {
    server rally-backend.{{ .Values.namespace }}.svc.cluster.local:{{ .Values.backend.port }};
}
server {
    listen {{ .Values.frontend.port }};
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    client_max_body_size 50m;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript application/wasm image/svg+xml;
    gzip_min_length 1024;
    location /api/ {
        proxy_pass http://rally_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Request-ID $request_id;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        proxy_buffering off;
    }
    location = /livez { proxy_pass http://rally_backend; }
    location = /readyz { proxy_pass http://rally_backend; }
    location /static/ {
        expires 1y;
        add_header Cache-Control "public, immutable" always;
        try_files $uri =404;
    }
    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-cache" always;
    }
}
{{- end -}}

{{/* A Rally web Deployment. Args: root, name (rally-frontend|rally-submit), component, image, replicas. */}}
{{- define "rally.webDeployment" -}}
{{- $root := .root -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "rally.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  replicas: {{ .replicas }}
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: rally
      app.kubernetes.io/component: {{ .component }}
  template:
    metadata:
      labels:
        {{- include "rally.labels" $root | nindent 8 }}
        app.kubernetes.io/component: {{ .component }}
      annotations:
        checksum/config: {{ include (print $root.Template.BasePath "/configmap.yaml") $root | sha256sum }}
    spec:
      serviceAccountName: rally-frontend
      automountServiceAccountToken: false
      securityContext:
        {{- include "rally.podSecurity" $root | nindent 8 }}
        runAsUser: 101
        runAsGroup: 101
      containers:
        - name: web
          image: {{ .image | quote }}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: {{ $root.Values.frontend.port }}
          readinessProbe:
            httpGet: { path: /, port: http }
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /, port: http }
            periodSeconds: 20
          resources:
            {{- toYaml $root.Values.frontend.resources | nindent 12 }}
          securityContext:
            {{- include "rally.containerSecurity" $root | nindent 12 }}
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
              readOnly: true
            - name: cache
              mountPath: /var/cache/nginx
            - name: run
              mountPath: /run
      volumes:
        - name: nginx-conf
          configMap:
            name: {{ $root.Release.Name }}-frontend-nginx
        - name: cache
          emptyDir: {}
        - name: run
          emptyDir: {}
{{- end -}}
