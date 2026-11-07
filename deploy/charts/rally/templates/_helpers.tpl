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

{{/* "https" with internal TLS, "http" without: port names and probe schemes. */}}
{{- define "rally.scheme" -}}
{{- if .Values.internalTLS.enabled }}https{{ else }}http{{ end -}}
{{- end -}}

{{/* Volumes for a pod that serves with <secret> and trusts the internal CA. */}}
{{- define "rally.tlsVolumes" -}}
- name: tls
  secret:
    secretName: {{ .secret }}
    defaultMode: 0440
- name: internal-ca
  configMap:
    name: {{ .root.Values.internalTLS.caConfigMap }}
{{- end -}}

{{- define "rally.tlsVolumeMounts" -}}
- name: tls
  mountPath: /etc/conservices-tls
  readOnly: true
- name: internal-ca
  mountPath: /etc/conservices-internal-ca
  readOnly: true
{{- end -}}

{{- define "rally.certificate" -}}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .name }}-tls
  namespace: {{ .root.Values.namespace }}
  labels:
    {{- include "rally.labels" .root | nindent 4 }}
spec:
  secretName: {{ .name }}-tls
  duration: {{ .root.Values.internalTLS.duration }}
  renewBefore: {{ .root.Values.internalTLS.renewBefore }}
  privateKey:
    algorithm: ECDSA
    size: 256
    encoding: PKCS8
    rotationPolicy: Always
  usages: ["server auth", "digital signature"]
  dnsNames:
    - {{ .name }}
    - {{ .name }}.{{ .root.Values.namespace }}
    - {{ .name }}.{{ .root.Values.namespace }}.svc
    - {{ .name }}.{{ .root.Values.namespace }}.svc.cluster.local
  issuerRef:
    group: cert-manager.io
    kind: {{ .root.Values.internalTLS.issuerRef.kind }}
    name: {{ .root.Values.internalTLS.issuerRef.name }}
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

{{/* nginx config for a Rally web app (staff app or submission site). Each
pod mounts its own certificate at /etc/conservices-tls. */}}
{{- define "rally.nginx" -}}
{{- $tls := .Values.internalTLS.enabled -}}
{{- $scheme := include "rally.scheme" . -}}
upstream rally_backend {
    server rally-backend.{{ .Values.namespace }}.svc.cluster.local:{{ .Values.backend.port }};
}
server {
    {{- if $tls }}
    listen {{ .Values.frontend.port }} ssl;
    {{- else }}
    listen {{ .Values.frontend.port }};
    {{- end }}
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    client_max_body_size {{ .Values.frontend.clientMaxBodySize | default "50m" }};
    {{- if $tls }}
    ssl_certificate     /etc/conservices-tls/tls.crt;
    ssl_certificate_key /etc/conservices-tls/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    proxy_ssl_trusted_certificate /etc/conservices-internal-ca/ca.crt;
    proxy_ssl_verify              on;
    proxy_ssl_verify_depth        2;
    proxy_ssl_name                rally-backend.{{ .Values.namespace }}.svc.cluster.local;
    proxy_ssl_server_name         on;
    proxy_ssl_session_reuse       on;
    {{- end }}
    gzip on;
    gzip_types text/plain text/css application/json application/javascript application/wasm image/svg+xml;
    gzip_min_length 1024;
    location /api/ {
        proxy_pass {{ $scheme }}://rally_backend;
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
    location = /livez { proxy_pass {{ $scheme }}://rally_backend; }
    location = /readyz { proxy_pass {{ $scheme }}://rally_backend; }
    # Installation settings of the web app (sign-in address and the like),
    # mounted at /etc/conservices. Never cached, so a change shows on reload.
    location = /config.json {
        alias /etc/conservices/config.json;
        add_header Cache-Control "no-store" always;
    }

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

{{/* /config.json of a Rally web app. Args: root, app (frontend|submit).
Defaults derived from config; a key set in frontend.config or submit.config
always wins, even when empty. */}}
{{- define "rally.webConfig" -}}
{{- $c := .root.Values.config -}}
{{- $out := dict "authMode" ($c.AUTH_MODE | default "oidc") "oidcScope" "openid profile email" "apiBaseUrl" "" -}}
{{- if eq .app "submit" }}
{{- $_ := set $out "oidcAuthority" ($c.ATTENDEE_OIDC_ISSUER_URL | default "") }}
{{- $_ := set $out "oidcClientId" ($c.ATTENDEE_OIDC_CLIENT_ID | default "rally-submit") }}
{{- $_ := set $out "productName" "Event submissions" }}
{{- $_ := set $out "publicScheduleKey" ($c.PUBLIC_API_BUILTIN_KEY | default "") }}
{{- else }}
{{- $_ := set $out "oidcAuthority" ($c.OIDC_ISSUER_URL | default "") }}
{{- $_ := set $out "oidcClientId" ($c.OIDC_CLIENT_ID | default "events-spa") }}
{{- $_ := set $out "productName" "Rally" }}
{{- end }}
{{- range $k, $v := ((index .root.Values .app).config | default dict) }}
{{- $_ := set $out $k $v }}
{{- end }}
{{- toPrettyJson $out -}}
{{- end -}}

{{/* A Rally web Deployment. Args: root, name (rally-frontend|rally-submit), component, image, replicas,
config (its /config.json ConfigMap). With internal TLS it serves with the Secret <name>-tls. */}}
{{- define "rally.webDeployment" -}}
{{- $root := .root -}}
{{- $tls := $root.Values.internalTLS.enabled -}}
{{- $scheme := include "rally.scheme" $root -}}
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
        checksum/web-config: {{ include "rally.webConfig" (dict "root" $root "app" .component) | sha256sum }}
    spec:
      serviceAccountName: rally-frontend
      automountServiceAccountToken: false
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      terminationGracePeriodSeconds: {{ $root.Values.frontend.terminationGracePeriodSeconds | default 30 }}
      {{- with (include "rally.scheduling" (dict "root" $root "component" .component "replicas" .replicas) | trim) }}{{ . | nindent 6 }}{{ end }}
      securityContext:
        {{- include "rally.podSecurity" $root | nindent 8 }}
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101
      containers:
        - name: web
          image: {{ .image | quote }}
          imagePullPolicy: IfNotPresent
          ports:
            - name: {{ $scheme }}
              containerPort: {{ $root.Values.frontend.port }}
          readinessProbe:
            httpGet: { path: /, port: {{ $scheme }}, scheme: {{ upper $scheme }} }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /, port: {{ $scheme }}, scheme: {{ upper $scheme }} }
            periodSeconds: 20
          {{- with $root.Values.frontend.preStopSleepSeconds }}
          # Keep serving while the gateway drops this pod from its endpoints.
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep {{ . }}"]
          {{- end }}
          resources:
            {{- toYaml $root.Values.frontend.resources | nindent 12 }}
          securityContext:
            {{- include "rally.containerSecurity" $root | nindent 12 }}
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
              readOnly: true
            {{- if $tls }}
            - name: nginx-conf
              mountPath: /docker-entrypoint.d/90-reload-tls.sh
              subPath: 90-reload-tls.sh
              readOnly: true
            {{- include "rally.tlsVolumeMounts" $root | nindent 12 }}
            {{- end }}
            # Served as /config.json (frontend.config or submit.config).
            - name: web-config
              mountPath: /etc/conservices
              readOnly: true
            - name: cache
              mountPath: /var/cache/nginx
            - name: run
              mountPath: /run
            # nginx-unprivileged: nginx.pid and temporary files
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: nginx-conf
          configMap:
            name: {{ $root.Release.Name }}-frontend-nginx
            defaultMode: 0555
        - name: web-config
          configMap:
            name: {{ .config }}
        - name: cache
          emptyDir: {}
        - name: run
          emptyDir: {}
        - name: tmp
          emptyDir: {}
        {{- if $tls }}
        {{- include "rally.tlsVolumes" (dict "root" $root "secret" (printf "%s-tls" .name)) | nindent 8 }}
        {{- end }}
{{- end -}}

{{/* An Ingress for one Rally web app. Args: root, name (rally|rally-submit), host, service (rally-frontend|rally-submit). */}}
{{- define "rally.ingress" -}}
{{- $root := .root -}}
{{- $tls := $root.Values.internalTLS.enabled -}}
{{- $ns := $root.Values.namespace -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .name }}
  namespace: {{ $ns }}
  labels:
    {{- include "rally.labels" $root | nindent 4 }}
  {{- if or $root.Values.ingress.annotations (and $tls $root.Values.internalTLS.ingressNginxAnnotations) }}
  annotations:
    {{- with $root.Values.ingress.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- if and $tls $root.Values.internalTLS.ingressNginxAnnotations }}
    # The controller talks HTTPS to the web app and checks its certificate
    # against the ca.crt in {{ .service }}-tls.
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/proxy-ssl-secret: {{ $ns }}/{{ .service }}-tls
    nginx.ingress.kubernetes.io/proxy-ssl-verify: "on"
    nginx.ingress.kubernetes.io/proxy-ssl-name: {{ .service }}.{{ $ns }}.svc.cluster.local
    nginx.ingress.kubernetes.io/proxy-ssl-server-name: "on"
    {{- end }}
  {{- end }}
spec:
  {{- with $root.Values.ingress.className }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- if $root.Values.ingress.tlsSecretName }}
  tls:
    - hosts:
        - {{ .host }}
      secretName: {{ $root.Values.ingress.tlsSecretName }}
  {{- end }}
  rules:
    - host: {{ .host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .service }}
                port:
                  name: {{ include "rally.scheme" $root }}
{{- end -}}

{{/* Pod-spec scheduling fields for one component. Args: root, component, replicas.
Spreading only makes sense with more than one replica. */}}
{{- define "rally.scheduling" -}}
{{- $root := .root -}}
{{- with $root.Values.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- if and $root.Values.ha.topologySpread (gt (int .replicas) 1) }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    matchLabelKeys: ["pod-template-hash"]
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: rally
        app.kubernetes.io/component: {{ .component }}
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: rally
              app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end -}}

{{/* PodDisruptionBudget for one component. Args: root, name, component, replicas.
A single replica gets none: minAvailable 1 on one pod would block node drains. */}}
{{- define "rally.pdb" -}}
{{- if and .root.Values.ha.podDisruptionBudget (gt (int .replicas) 1) }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .name }}
  namespace: {{ .root.Values.namespace }}
  labels:
    {{- include "rally.labels" .root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: rally
      app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end -}}

{{/* HTTPRoute for one web app. Args: root, name, host, service. */}}
{{- define "rally.httpRoute" -}}
{{- $root := .root -}}
{{- $r := $root.Values.route -}}
{{- $port := ternary 443 80 $root.Values.internalTLS.enabled -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .name }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "rally.labels" $root | nindent 4 }}
  {{- with $r.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  parentRefs:
    {{- toYaml (required "route.parentRefs is required when route.enabled" $r.parentRefs) | nindent 4 }}
  hostnames:
    - {{ required "route.host is required when route.enabled" .host | quote }}
  rules:
    {{- with $root.Values.frontend.websocketPathRegex }}
    # Websockets stay open as long as the page: no request timeout here.
    - matches:
        - path:
            type: RegularExpression
            value: {{ . | quote }}
      backendRefs:
        - name: {{ $.service }}
          port: {{ $port }}
      {{- with $r.websocketTimeout }}
      timeouts:
        request: {{ . }}
      {{- end }}
    {{- end }}
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {{ .service }}
          port: {{ $port }}
      {{- with $r.timeout }}
      timeouts:
        request: {{ . }}
      {{- end }}
{{- end -}}

{{/* BackendTLSPolicy: the gateway talks HTTPS to <service> and checks its
certificate against the internal CA. The hostname must be a SAN of the
<service>-tls certificate (see rally.certificate). Cilium only accepts
ConfigMap CA references. */}}
{{- define "rally.backendTLSPolicy" -}}
{{- $root := .root -}}
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: {{ .service }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "rally.labels" $root | nindent 4 }}
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: {{ .service }}
      sectionName: https
  validation:
    caCertificateRefs:
      - group: ""
        kind: ConfigMap
        name: {{ $root.Values.internalTLS.caConfigMap }}
    hostname: {{ .service }}.{{ $root.Values.namespace }}.svc.cluster.local
{{- end -}}

{{/* Egress rule to pods <podSelector> in namespace <namespace> on <port>. */}}
{{- define "rally.egressTo" -}}
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ .namespace }}
      podSelector:
        matchLabels:
          {{- toYaml .podSelector | nindent 10 }}
  ports:
    - { protocol: TCP, port: {{ .port }} }
{{- end -}}

{{/* Egress to PostgreSQL and S3 (networkPolicy.data). Accepts the old keys
postgresPort, s3Port and a boolean data.s3. */}}
{{- define "rally.dataEgress" -}}
{{- $d := .Values.networkPolicy.data -}}
{{- if $d.enabled }}
{{- $pg := $d.postgres | default dict -}}
{{- include "rally.egressTo" (dict "namespace" $d.namespace "podSelector" ($pg.podSelector | default (dict "cnpg.io/cluster" "conservices-pg")) "port" (int (coalesce $d.postgresPort $pg.port 5432))) }}
{{- $s3 := $d.s3 -}}
{{- $s3on := true -}}
{{- if kindIs "bool" $s3 }}{{ $s3on = $s3 }}{{ $s3 = dict }}{{ else if kindIs "map" $s3 }}{{ $s3on = ne (toString $s3.enabled) "false" }}{{ else }}{{ $s3 = dict }}{{ end -}}
{{- if $s3on }}
{{ include "rally.egressTo" (dict "namespace" $d.namespace "podSelector" ($s3.podSelector | default (dict "app.kubernetes.io/name" "garage")) "port" (int (coalesce $d.s3Port $s3.port 3900))) }}
{{- end }}
{{- end }}
{{- with (include "rally.externalS3" . | fromYaml) }}
{{- with .cidrs }}
# External S3 by address range (any CNI). With Cilium, prefer fqdns.
- to:
    {{- range . }}
    - ipBlock:
        cidr: {{ . }}
    {{- end }}
  ports:
    - { protocol: TCP, port: {{ $.Values.networkPolicy.data.s3.external.port | default 443 }} }
{{- end }}
{{- end }}
{{- end -}}

{{/* networkPolicy.data.s3.external as YAML ({} when unset or data.s3 is a boolean). */}}
{{- define "rally.externalS3" -}}
{{- $s3 := .Values.networkPolicy.data.s3 -}}
{{- if kindIs "map" $s3 }}{{ toYaml ($s3.external | default dict) }}{{ else }}{}{{ end -}}
{{- end -}}

{{/* CiliumNetworkPolicy: egress to external S3 by host name (toFQDNs), with
the DNS rule that sends lookups through Cilium's DNS proxy so it learns the
addresses behind the names. Args: root, components. */}}
{{- define "rally.externalS3Policy" -}}
{{- $root := .root -}}
{{- $ext := include "rally.externalS3" $root | fromYaml -}}
{{- if and $ext.fqdns ($root.Values.networkPolicy.gateway | default dict).cilium }}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: rally-external-s3
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "rally.labels" $root | nindent 4 }}
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: rally
    matchExpressions:
      - key: app.kubernetes.io/component
        operator: In
        values: {{ toJson .components }}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - { port: "53", protocol: ANY }
          rules:
            dns:
              - matchPattern: "*"
    - toFQDNs:
        {{- range $ext.fqdns }}
        - matchPattern: {{ . | quote }}
        {{- end }}
      toPorts:
        - ports:
            - port: {{ $ext.port | default 443 | quote }}
              protocol: TCP
{{- end }}
{{- end -}}

{{/* "namespace|selector|port" of the in-cluster OIDC target, "" when off. */}}
{{- define "rally.oidcKey" -}}
{{- $o := .Values.networkPolicy.oidc | default dict -}}
{{- if $o.inCluster -}}
{{- printf "%s|%s|%d" $o.namespace (toJson $o.podSelector) (int $o.port) -}}
{{- end -}}
{{- end -}}

{{/* Egress to the OIDC issuer: in-cluster Keycloak (networkPolicy.oidc) and/or
the legacy route through the ingress controller. */}}
{{- define "rally.oidcEgress" -}}
{{- $np := .Values.networkPolicy -}}
{{- $o := $np.oidc | default dict -}}
{{- if $o.inCluster }}
# OIDC discovery and signing keys: auth.<domain> resolves to
# keycloak-public in-cluster, whose certificate carries that name.
{{ include "rally.egressTo" (dict "namespace" $o.namespace "podSelector" $o.podSelector "port" (int $o.port)) }}
{{- end }}
{{- if $np.oidcViaIngressController }}
# OIDC discovery and signing keys through the public issuer (legacy).
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ $np.ingressControllerNamespace }}
  ports:
    - { protocol: TCP, port: 443 }
{{- end }}
{{- end -}}

{{/* Ingress rules for a web app: the ingress controller (with ingress.enabled)
and a non-Cilium gateway namespace. Cilium's gateway is admitted by a
CiliumNetworkPolicy instead (rally.ciliumGatewayPolicy). */}}
{{- define "rally.webIngressFrom" -}}
{{- $np := .Values.networkPolicy -}}
{{- if .Values.ingress.enabled }}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ $np.ingressControllerNamespace }}
{{- end }}
{{- with ($np.gateway | default dict).namespace }}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ . }}
{{- end }}
{{- end -}}

{{/* Cilium's gateway (Envoy) reaches pods with the reserved identity
"ingress", which a Kubernetes NetworkPolicy cannot select. Args: root, components. */}}
{{- define "rally.ciliumGatewayPolicy" -}}
{{- $root := .root -}}
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: rally-web-from-gateway
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "rally.labels" $root | nindent 4 }}
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: rally
    matchExpressions:
      - key: app.kubernetes.io/component
        operator: In
        values: {{ toJson .components }}
  ingress:
    - fromEntities: ["ingress"]
      toPorts:
        - ports:
            - port: {{ $root.Values.frontend.port | quote }}
              protocol: TCP
{{- end -}}
