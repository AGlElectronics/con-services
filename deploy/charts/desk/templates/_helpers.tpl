{{- define "desk.labels" -}}
app.kubernetes.io/name: desk
app.kubernetes.io/part-of: conservices
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "desk.podSecurity" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/* "https" with internal TLS, "http" without: port names and probe schemes. */}}
{{- define "desk.scheme" -}}
{{- if .Values.internalTLS.enabled }}https{{ else }}http{{ end -}}
{{- end -}}

{{/* Volumes for a pod that serves with <secret> and trusts the internal CA. */}}
{{- define "desk.tlsVolumes" -}}
- name: tls
  secret:
    secretName: {{ .secret }}
    defaultMode: 0440
- name: internal-ca
  configMap:
    name: {{ .root.Values.internalTLS.caConfigMap }}
{{- end -}}

{{- define "desk.tlsVolumeMounts" -}}
- name: tls
  mountPath: /etc/conservices-tls
  readOnly: true
- name: internal-ca
  mountPath: /etc/conservices-internal-ca
  readOnly: true
{{- end -}}

{{- define "desk.certificate" -}}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .name }}-tls
  namespace: {{ .root.Values.namespace }}
  labels:
    {{- include "desk.labels" .root | nindent 4 }}
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

{{- define "desk.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- define "desk.image" -}}
{{- $img := index .root.Values.image .name -}}
{{- printf "%s:%s" $img.repository (required (printf "image.%s.tag is required (MAJOR.MINOR.PATCH-BUILD)" .name) $img.tag) -}}
{{- end -}}

{{/* Pod-spec scheduling fields for one component. Args: root, component, replicas.
Spreading only makes sense with more than one replica. */}}
{{- define "desk.scheduling" -}}
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
        app.kubernetes.io/name: desk
        app.kubernetes.io/component: {{ .component }}
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: desk
              app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end -}}

{{/* PodDisruptionBudget for one component. Args: root, name, component, replicas.
A single replica gets none: minAvailable 1 on one pod would block node drains. */}}
{{- define "desk.pdb" -}}
{{- if and .root.Values.ha.podDisruptionBudget (gt (int .replicas) 1) }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .name }}
  namespace: {{ .root.Values.namespace }}
  labels:
    {{- include "desk.labels" .root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: desk
      app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end -}}

{{/* HTTPRoute for one web app. Args: root, name, host, service. */}}
{{- define "desk.httpRoute" -}}
{{- $root := .root -}}
{{- $r := $root.Values.route -}}
{{- $port := ternary 443 80 $root.Values.internalTLS.enabled -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .name }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "desk.labels" $root | nindent 4 }}
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
<service>-tls certificate (see desk.certificate). Cilium only accepts
ConfigMap CA references. */}}
{{- define "desk.backendTLSPolicy" -}}
{{- $root := .root -}}
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: {{ .service }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "desk.labels" $root | nindent 4 }}
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
{{- define "desk.egressTo" -}}
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
{{- define "desk.dataEgress" -}}
{{- $d := .Values.networkPolicy.data -}}
{{- if $d.enabled }}
{{- $pg := $d.postgres | default dict -}}
{{- include "desk.egressTo" (dict "namespace" $d.namespace "podSelector" ($pg.podSelector | default (dict "cnpg.io/cluster" "conservices-pg")) "port" (int (coalesce $d.postgresPort $pg.port 5432))) }}
{{- $s3 := $d.s3 -}}
{{- $s3on := true -}}
{{- if kindIs "bool" $s3 }}{{ $s3on = $s3 }}{{ $s3 = dict }}{{ else if kindIs "map" $s3 }}{{ $s3on = ne (toString $s3.enabled) "false" }}{{ else }}{{ $s3 = dict }}{{ end -}}
{{- if $s3on }}
{{ include "desk.egressTo" (dict "namespace" $d.namespace "podSelector" ($s3.podSelector | default (dict "app.kubernetes.io/name" "garage")) "port" (int (coalesce $d.s3Port $s3.port 3900))) }}
{{- end }}
{{- end }}
{{- with (include "desk.externalS3" . | fromYaml) }}
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
{{- define "desk.externalS3" -}}
{{- $s3 := .Values.networkPolicy.data.s3 -}}
{{- if kindIs "map" $s3 }}{{ toYaml ($s3.external | default dict) }}{{ else }}{}{{ end -}}
{{- end -}}

{{/* CiliumNetworkPolicy: egress to external S3 by host name (toFQDNs), with
the DNS rule that sends lookups through Cilium's DNS proxy so it learns the
addresses behind the names. Args: root, components. */}}
{{- define "desk.externalS3Policy" -}}
{{- $root := .root -}}
{{- $ext := include "desk.externalS3" $root | fromYaml -}}
{{- if and $ext.fqdns ($root.Values.networkPolicy.gateway | default dict).cilium }}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: desk-external-s3
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "desk.labels" $root | nindent 4 }}
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: desk
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
{{- define "desk.oidcKey" -}}
{{- $o := .Values.networkPolicy.oidc | default dict -}}
{{- if $o.inCluster -}}
{{- printf "%s|%s|%d" $o.namespace (toJson $o.podSelector) (int $o.port) -}}
{{- end -}}
{{- end -}}

{{/* Egress to the OIDC issuer: in-cluster Keycloak (networkPolicy.oidc) and/or
the legacy route through the ingress controller. */}}
{{- define "desk.oidcEgress" -}}
{{- $np := .Values.networkPolicy -}}
{{- $o := $np.oidc | default dict -}}
{{- if $o.inCluster }}
# OIDC discovery and signing keys: auth.<domain> resolves to
# keycloak-public in-cluster, whose certificate carries that name.
{{ include "desk.egressTo" (dict "namespace" $o.namespace "podSelector" $o.podSelector "port" (int $o.port)) }}
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
CiliumNetworkPolicy instead (desk.ciliumGatewayPolicy). */}}
{{- define "desk.webIngressFrom" -}}
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
{{- define "desk.ciliumGatewayPolicy" -}}
{{- $root := .root -}}
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: desk-web-from-gateway
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "desk.labels" $root | nindent 4 }}
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: desk
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

{{/* The web app's /config.json: frontend.config over defaults derived from
config. A key set in frontend.config always wins, even when empty. */}}
{{- define "desk.frontendConfig" -}}
{{- $c := .Values.config -}}
{{- $out := dict "authMode" ($c.AUTH_MODE | default "oidc") "oidcAuthority" ($c.OIDC_ISSUER_URL | default "") "oidcClientId" ($c.OIDC_CLIENT_ID | default "desk-spa") "oidcScope" "openid profile email" "apiBaseUrl" "" "productName" "Desk" -}}
{{- range $k, $v := (.Values.frontend.config | default dict) }}
{{- $_ := set $out $k $v }}
{{- end }}
{{- toPrettyJson $out -}}
{{- end -}}
