# Installing modules with Helm

**Goal:** install, configure, upgrade and roll back a Con Services module
with its Helm chart, and know when to use Helm instead of Kustomize.

**Helm** is a package manager for Kubernetes. A **chart** is a package of
templated manifests; you install it with your own settings (a **values**
file), and Helm keeps track of each installation (a **release**) so you can
upgrade or roll it back with one command.

## Helm or Kustomize?

Both install the same published images. Pick one per module and stick to it;
do not apply a module with both.

| | Kustomize (`deploy/kubernetes/`) | Helm (`deploy/charts/`) |
| --- | --- | --- |
| Platform (Keycloak, PostgreSQL, S3 server) | **Yes**: `base/` plus your overlay. | **No chart.** Use Kustomize (or the operators of your GitOps setup) for the platform. |
| Den | `base/den/` | `charts/den` |
| Stash | `modules/stash/` | `charts/stash` |
| HR, Rally, Finance, Learn, Wiki, Desk, Tasks | Not written yet (see `deploy/kubernetes/modules/README.md`). | `charts/<module>` |
| Upgrade / rollback history | Git history of your overlay. | `helm history`, `helm rollback`. |
| Good fit for | GitOps, one repository describing the whole installation. | Installing one module quickly, Argo CD or Flux with `HelmRelease`. |

The production reference is [Deploy with Argo CD](../deploy/index.md): the
platform comes from operators (CloudNativePG, the Keycloak Operator) and a
managed S3 service, and Argo CD installs Den and the modules with these
charts. The Kustomize platform in `deploy/kubernetes/` is for a local trial.

!!! warning "The charts are a first version"
    Every chart is versioned with its app (Den and the modules all start at
    `1.0.0`, see [Versions and upgrades](versioning.md)), and all are marked
    *STUB: first scaffold, not yet tested on a cluster* in their
    `Chart.yaml`. They render valid manifests
    and follow the same rules as the Kustomize files, but test each one on a
    staging cluster before relying on it, and report problems as issues.

## What every chart does and does not do

Every chart in `deploy/charts/` follows the same rules:

- It **never creates Secrets.** You name an existing Secret with
  `existingSecret`; create it with an `ExternalSecret` from your secret
  manager (see [Secrets](secrets.md)).
- It **never creates the namespace.** Create `conservices-<module>` first,
  with the labels the platform's network policies need.
- It **never uses `latest`.** Image tags are `MAJOR.MINOR.PATCH-BUILD`. HR
  and Rally ship with empty tags on purpose, so the install fails until you
  set one.
- It keeps the module's backend at **one replica** with the `Recreate`
  strategy, because each backend runs its database migrations on start
  (through a `migrate` initContainer, or in-process for Stash). Den, Stash,
  Desk, Tasks and Wiki refuse any other value; see
  [High availability](#high-availability) for why that is safe.
- It exposes the web app through the **Gateway API** (`route.*`): an
  `HTTPRoute` plus a `BackendTLSPolicy`. A plain `Ingress` is still
  available (`ingress.enabled`) but off by default. See
  [Exposing the web app](#exposing-the-web-app-gateway-api).
- It creates the module's **NetworkPolicies** (default deny plus the
  allowed flows from [Network policies](network-policies.md)) unless you
  set `networkPolicy.enabled: false`, including a `CiliumNetworkPolicy`
  that admits Cilium's gateway (`networkPolicy.gateway.cilium`).
- It runs the web app with **two replicas**, a PodDisruptionBudget and
  spreading over nodes (`ha.*`).
- It runs every container under the `restricted` Pod Security rules, with
  no service account token mounted.
- It turns on **internal TLS** (`internalTLS.enabled: true`): it asks
  cert-manager for `<module>-backend-tls` and `<module>-frontend-tls`, the
  backend and the web app serve HTTPS, and both trust the internal CA from
  the `conservices-internal-ca` ConfigMap. cert-manager and trust-manager
  must be installed and the platform's `ClusterIssuer` must exist; see
  [Internal TLS](internal-tls.md#settings) for every `internalTLS.*` value.

Each chart's `version` and `appVersion` are its app's version, released by
the tag `<app>/v<version>` in `con-services` (for example `stash/v1.0.0`),
and its annotation `conservices.io/den-major` names the Den MAJOR it needs.
The default image tag is that version's first build.

| Chart | `version` / `appVersion` | Default image tag | Secret it expects (`existingSecret`) | Migrations | Notes |
| --- | --- | --- | --- | --- | --- |
| `den` | `1.0.0` | `1.0.0-1` | `den-secrets`, and `den-operator-secrets` (`operator.existingSecret`) | `/den-migrate` initContainer (backend image) | Install with the release name `den`. Three certificates (backend, web app, operator). Operator runs as user 70 (`postgres`). |
| `stash` | `1.0.0` | `1.0.0-1` | `stash-secrets` | in the backend at start | |
| `hr` | `1.0.0` | none | `hr-secrets` | `hr-migrate` initContainer | Set all three tags yourself. |
| `rally` | `1.0.0` | none | `rally-secrets` | `rally-migrate` initContainer | Set tags yourself. Pairs with Den as `events`. The published `rally-submit` image has the example sign-in settings; build your own for your domain. |
| `finance` | `1.0.0` | `1.0.0-1` | `finance-secrets` (`DATABASE_URL`, `S3_*` keys) | `finance-migrate` initContainer | No access config file; roles from `FINANCE_*_GROUPS`. Needs an S3 bucket for invoice PDFs. |
| `learn` | `1.0.0` | `1.0.0-1` | `learn-secrets` | `learn-migrate` initContainer | |
| `wiki` | `1.0.0` | `1.0.0-1` | `wiki-secrets` | `wiki-migrate` initContainer | Creates a 1 GiB PersistentVolumeClaim for the live-edit buffer. |
| `desk` | `1.0.0` | `1.0.0-1` | `desk-secrets` | `desk-migrate` initContainer | |
| `tasks` | `1.0.0` | `1.0.0-1` | `tasks-secrets` | `tasks-migrate` initContainer | |

Each chart's `values.yaml` lists every key with a comment; the module's
**Setup** and **Configuration** pages (under [Modules](../modules/index.md))
explain the settings.

## Install a module

This example installs Stash into a cluster where the platform and Den
already run ([How the platform starts](../getting-started/how-the-platform-starts.md)).
For any other module, replace `stash` with the module name.

1. **Install Helm 3** on your computer (<https://helm.sh/docs/intro/install/>)
   and check it:

    ```sh
    helm version --short
    ```

    ```text
    v3.16.3+gcbc5a57
    ```

2. **Register the module in Den** and let it create the database:
   Den → **Admin console → Modules → New module**, tick *Create a database
   for it*, and copy the connection URL Den shows once.

3. **Create the namespace** with the labels the network policies select on:

    ```sh
    kubectl create namespace conservices-stash
    kubectl label namespace conservices-stash \
      conservices.io/tier=module conservices.io/module=stash \
      app.kubernetes.io/part-of=conservices \
      pod-security.kubernetes.io/enforce=restricted \
      pod-security.kubernetes.io/warn=restricted
    ```

4. **Store the secrets** in your secret manager and let the External Secrets
   Operator create `stash-secrets` (procedure in
   [Secrets](secrets.md#add-a-modules-secrets)). Check it exists:

    ```sh
    kubectl get secret -n conservices-stash stash-secrets
    ```

    ```text
    NAME            TYPE     DATA   AGE
    stash-secrets   Opaque   3      12s
    ```

5. **Create the access config** ConfigMap (modules with an access config
   only; the comment in `values.yaml` gives the exact command):

    ```sh
    kubectl create configmap stash-access-config -n conservices-stash \
      --from-file=access-config.toml=stash/infra/access-config.toml
    ```

6. **Write your values file** and keep it in Git (it contains no secrets):

    ```yaml
    # values/stash.yaml
    image:
      backend:  { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
    config:
      APP_BASE_URL: https://stash.con.example.org
      OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://stash.con.example.org
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-stash
      S3_REGION: fsn1
      S3_USE_PATH_STYLE: "false"
    route:
      host: stash.con.example.org
      parentRefs:                       # your Gateway and its HTTPS listener
        - { name: public, namespace: conservices-gateway, sectionName: https }
    networkPolicy:
      data: { enabled: false }          # managed PostgreSQL and S3, not conservices-data
      extraEgress:
        - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your database subnet
          ports: [{ protocol: TCP, port: 5432 }]
        - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]      # managed S3 over HTTPS
          ports: [{ protocol: TCP, port: 443 }]
    ```

7. **Preview** what Helm would create, then install:

    ```sh
    helm template stash deploy/charts/stash -n conservices-stash -f values/stash.yaml | less
    helm install stash deploy/charts/stash -n conservices-stash -f values/stash.yaml
    ```

    ```text
    NAME: stash
    NAMESPACE: conservices-stash
    STATUS: deployed
    REVISION: 1
    NOTES:
    Stash 1.0.0-1 is installed in namespace conservices-stash.
    ...
    ```

8. **Wait for the pods** and check health, as the chart's notes say:

    ```sh
    kubectl get pods -n conservices-stash -w
    kubectl get certificate -n conservices-stash
    kubectl exec -n conservices-stash deploy/stash-frontend -- curl -s --cacert /etc/conservices-internal-ca/ca.crt https://stash-backend:8080/api/health
    ```

    Both certificates must show `READY True`. The health answer:

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":42}
    ```

    Then check that the gateway accepted the route:

    ```sh
    kubectl get httproute,backendtlspolicy -n conservices-stash
    kubectl get httproute stash -n conservices-stash -o jsonpath="{.status.parents[0].conditions[*].type}={.status.parents[0].conditions[*].status}"
    ```

    ```text
    Accepted ResolvedRefs=True True
    ```

9. **Add the module's bucket to backups**: append it to `FILES_S3_BUCKETS`
   in your platform overlay's `den-operator-config` and re-apply the
   platform (see [Backups](databases-and-backups.md#backups)).
10. **Pair it** with Den: Den → **Modules → Pair**, then in the module
    **Settings → Den connection** (see
    [How the platform starts, step 4c](../getting-started/how-the-platform-starts.md#4c-pair-stash-with-den)).
    Until then the module shows *Waiting for Den* and its API answers
    `503 den_pairing_required` (`den.mode: required`, see
    [Den mode](#den-mode)).

Den itself has a chart too (`deploy/charts/den`); its install steps and
values are on [Den configuration → Install with Helm](../modules/den/configuration.md#install-with-helm).

## Den mode

Every module chart sets the backend's `DEN_MODE` from the value `den.mode`
([Required or standalone](../concepts/pairing.md#required-or-standalone)).
Den's chart can list the modules on Den's Modules page in advance.

| Value | Chart | Default | What it does |
| --- | --- | --- | --- |
| `den.mode` | every module | `required` | `required`: the module waits for Den; until it is paired, its API answers `503 den_pairing_required` and its web app shows *Waiting for Den*. `standalone`: the module works without Den (pairing stays optional). Rendered as `DEN_MODE` into `<release>-config`. Any other value, or setting `config.DEN_MODE` as well, stops `helm template` with an error. |
| `preregisterModules` | Den | `[]` | Modules Den lists as unpaired from its first start. This never pairs them: an admin still creates the pairing URL and pastes it into the module ([pairing](../concepts/pairing.md)). Format: `[{slug, display_name, base_url}]` (optional `environment`; Rally's slug is `events`). Rendered as JSON into `DEN_PREREGISTER_MODULES` when not empty. Den adds unknown slugs at start-up and never changes or removes existing ones ([details](../modules/den/configuration.md#modules-registered-at-start-up)). |

A module installed without Den sets:

```yaml
den:
  mode: standalone
```

Den with two modules listed in advance:

```yaml
preregisterModules:
  - { slug: stash, display_name: Stash, base_url: https://stash.con.example.org }
  - { slug: events, display_name: Rally, base_url: https://events.con.example.org }
```

Check what the chart renders:

```sh
helm template stash deploy/charts/stash --set den.mode=standalone | grep DEN_MODE
```

```text
  DEN_MODE: "standalone"
```

A typo fails early:

```sh
helm template stash deploy/charts/stash --set den.mode=optional
```

```text
Error: execution error at (stash/templates/deployment.yaml:49:28): den.mode must be "required" or "standalone", not "optional"
```

## Exposing the web app (Gateway API)

The **Gateway API** is the successor of Ingress in Kubernetes. A cluster
operator runs a **Gateway** (the load balancer with the public certificate
and its listeners); each application attaches an **HTTPRoute** to it ("send
`stash.example.org` to the Service `stash-frontend`"). Con Services is
tested with **Cilium's** Gateway API implementation (Envoy inside Cilium).
No ingress controller is needed.

With `route.enabled: true` (the default) every chart renders:

- an `HTTPRoute` on `route.host`, attached to `route.parentRefs`, sending
  everything to the web app's Service on port 443 (80 without internal TLS);
- with `internalTLS.enabled`, a `BackendTLSPolicy` (`gateway.networking.k8s.io/v1`)
  so the gateway talks HTTPS to the web app and checks its certificate
  against the `conservices-internal-ca` ConfigMap. Details and Cilium's
  limits: [Internal TLS → Gateway API (Cilium)](internal-tls.md#gateway-api-cilium).

Rally renders two of each (staff app on `route.host`, submission site on
`submit.host` when `submit.enabled`). Wiki adds a rule for its live-editing
websockets without a timeout; Den adds one for module removal with a
30-minute timeout.

| Value | Default | What it does |
| --- | --- | --- |
| `route.enabled` | `true` | Render the `HTTPRoute` (and `BackendTLSPolicy`). |
| `route.host` | `<module>.conservices.test` | Public host name. Must match a listener of the Gateway (or the listener has no `hostname`). |
| `route.parentRefs` | `[{name: public, namespace: conservices-gateway, sectionName: https}]` | The Gateway and listener to attach to. The listener's `allowedRoutes` must admit the module's namespace. |
| `route.annotations` | `{}` | Annotations on the `HTTPRoute`. |
| `route.timeout` | `120s` | `timeouts.request` of the main rule. Matches the web app's nginx limit for `/api/` requests (120 s), so the gateway never cuts a request nginx still waits for. Raise both together if long requests (exports, reports) end with `504`. Empty: the gateway's default. |
| `route.websocketTimeout` | `0s` | Timeout of the websocket rule, rendered only when `frontend.websocketPathRegex` is set (Wiki). `0s` disables the timeout so open websockets are never cut. |
| `route.moduleRemovalTimeout` (Den) | `30m` | Timeout of the `/api/v1/modules/<slug>` rule: removing a module backs its database up first. |
| `ingress.enabled` | `false` | Render a plain `Ingress` instead or as well (another controller, for example Traefik; see [Other ingress controllers](internal-tls.md#other-ingress-controllers)). ingress-nginx is no longer maintained; do not use it. |

**Upload size.** Envoy (Cilium's gateway) has no per-route body
limit, so the only limit is nginx in the web app: `client_max_body_size`
from `frontend.clientMaxBodySize` (Stash and Rally `50m`, HR and Finance
`10m`, Learn, Desk and Den `20m`, Tasks `27m`, Wiki `52m`). Raise it there
when uploads fail with `413 Request Entity Too Large`.

**Websockets.** Envoy passes websocket upgrades through by default. Only
the request timeout can cut them, which is why Wiki's live-editing path
gets its own rule with `route.websocketTimeout: 0s`.

## High availability

A pod or a node dying must not take a module down. What the charts do:

- **Web apps run two replicas** (`frontend.replicas: 2`, Rally also
  `submit.replicas: 2`) spread over nodes: `topologySpreadConstraints` on
  `kubernetes.io/hostname` with `whenUnsatisfiable: ScheduleAnyway`, plus a
  soft pod anti-affinity (`ha.topologySpread`). A single-node cluster still
  schedules both.
- **PodDisruptionBudget** `minAvailable: 1` for every component with more
  than one replica (`ha.podDisruptionBudget`), so a node drain never stops
  both web app pods at once.
- **nginx drains before it stops**: a `preStop` pause of
  `frontend.preStopSleepSeconds` (5 s) keeps it serving while the gateway
  removes the pod from its endpoints, so rolling updates do not drop
  requests. Readiness is checked every 5 s.
- **Backends stay singletons** (`replicas: 1`, `Recreate`) where the code
  requires it. They get **no** PodDisruptionBudget: a PDB on one pod would
  block every node drain. When their node dies, Kubernetes starts them
  elsewhere (with Longhorn volumes re-attached for Wiki's buffer); expect
  a short interruption of the API, while the web app keeps serving.

| Component | Replicas | Why |
| --- | --- | --- |
| `den-backend` | exactly 1 | Backup download links live in process memory; two `migrate` initContainers must never run at once. |
| `den-operator` | exactly 1 | Backup scheduler and its lock live in the process. |
| `stash-backend` | exactly 1 | Migrates in-process at start-up. |
| `wiki-backend` | exactly 1 | Live-editing state and the edit buffer live in one process. |
| `desk-backend` | exactly 1 | IMAP fetcher and reply sender assume one process. |
| `tasks-backend` | exactly 1 | In-process rate limiter and due-date sweep. |
| `hr-`, `rally-`, `finance-`, `learn-backend` | 1 (not enforced) | Every pod runs the `migrate` initContainer; several pods starting together would migrate at the same time. |
| every web app | 2 or more | Stateless. |

| Value | Default | What it does |
| --- | --- | --- |
| `ha.podDisruptionBudget` | `true` | PDB (`minAvailable: 1`) for each component with more than one replica. |
| `ha.topologySpread` | `true` | Spread constraints and soft anti-affinity for each component with more than one replica. |
| `priorityClassName` | `""` | PriorityClass for every pod of the release, for example one you create for Con Services so it is not evicted before batch workloads. |
| `frontend.preStopSleepSeconds` | `5` | Pause before nginx stops. `0` turns it off. |
| `frontend.terminationGracePeriodSeconds`, `backend.terminationGracePeriodSeconds` | `30` (Wiki backend `45`) | Time a pod gets to shut down cleanly. |
| `frontend.clientMaxBodySize` | per module | Upload limit in nginx (see above). |
| `frontend.config` | `{}` | The web app's `/config.json`: `authMode`, `oidcAuthority`, `oidcClientId`, `oidcScope`, `apiBaseUrl` and per-module keys. Keys left out come from `config.AUTH_MODE`, `config.OIDC_ISSUER_URL` and `config.OIDC_CLIENT_ID`, so usually nothing extra is needed. Rendered to the ConfigMap `<release>-frontend-config`, mounted at `/etc/conservices`; the pods restart when it changes. Rally's submission site has its own `submit.config`. See each module's *Web app settings* section, for example [Den](../modules/den/configuration.md#web-app-settings-configjson). |

## Network policy values

On top of `networkPolicy.enabled`, `den`, `allowFromNamespaces` and
`extraEgress`, every chart has these keys. The flows they open are listed
in [Network policies](network-policies.md#every-allowed-flow).

| Value | Default | What it does |
| --- | --- | --- |
| `networkPolicy.gateway.cilium` | `true` | Render a `CiliumNetworkPolicy` that admits Cilium's gateway (`fromEntities: [ingress]`) to the web app on 8080. Needed because Envoy's traffic carries Cilium's reserved `ingress` identity, which a Kubernetes NetworkPolicy cannot select. Needs Cilium's CRDs: set `false` on other CNIs. |
| `networkPolicy.gateway.namespace` | `""` | For a Gateway API implementation whose proxies run as pods in a namespace (for example Envoy Gateway): admit that namespace. |
| `networkPolicy.ingressControllerNamespace` | `ingress-nginx` | Admitted to the web app only when `ingress.enabled`. |
| `networkPolicy.oidc.inCluster` | `true` | Allow the backend to reach Keycloak directly for OIDC discovery and keys. CoreDNS rewrites `auth.<domain>` to the Service `keycloak-public.conservices-identity` (443 → Keycloak pods on 8443), whose certificate carries `auth.<domain>`. |
| `networkPolicy.oidc.namespace`, `.podSelector`, `.port` | `conservices-identity`, `{app: keycloak}`, `8443` | Which pods that is (`podSelector` is a `matchLabels` map; the Keycloak Operator labels its pods `app: keycloak`). |
| `networkPolicy.oidcViaIngressController` | `false` | Legacy: reach the issuer through the ingress controller on 443. |
| `networkPolicy.keycloakAdmin` (HR: `keycloak`) | Den, HR, Learn on; others off | Keycloak admin API. Same keys as `oidc`; when namespace, selector and port equal the `oidc` rule, it is rendered only once. |
| `networkPolicy.data.enabled`, `.namespace` | `true`, `conservices-data` | Egress to the database and S3. Set `false` for managed services and add `extraEgress`. |
| `networkPolicy.data.postgres.podSelector`, `.port` | `{cnpg.io/cluster: conservices-pg}`, `5432` | CloudNativePG cluster `conservices-pg` (the read-write Service is `conservices-pg-rw`). |
| `networkPolicy.data.s3.enabled`, `.podSelector`, `.port` | on (Desk off), `{app.kubernetes.io/name: garage}`, `3900` | Garage's S3 API behind its TLS sidecar. |
| `networkPolicy.data.s3.external.fqdns` | `[]` | Host names of an external S3 endpoint (Cilium `matchPattern` syntax, `*` allowed). Renders the `CiliumNetworkPolicy` `<module>-external-s3` for the backend (Den: backend and operator) when `networkPolicy.gateway.cilium` is `true`. See [External S3](#external-s3-hetzner-object-storage). |
| `networkPolicy.data.s3.external.cidrs` | `[]` | Address ranges of the external S3 endpoint, rendered as `ipBlock` rules in the plain NetworkPolicy. For CNIs without FQDN policies. |
| `networkPolicy.data.s3.external.port` | `443` | Port of the external S3 endpoint. |
| `networkPolicy.allowFromModules` (Den) | `true` | Admit module backends (`conservices.io/tier: module`) to `den-backend`. |
| `networkPolicy.operatorExtraEgress` (Den) | `[]` | Extra egress for the operator, for example off-site backup storage. |

To use the **in-cluster PostgreSQL and S3 server (SeaweedFS)** of the local trial in `deploy/kubernetes/base/data`:

```yaml
networkPolicy:
  data:
    postgres: { podSelector: { app.kubernetes.io/name: postgres }, port: 5432 }
    s3:       { podSelector: { app.kubernetes.io/name: s3 }, port: 9000 }
```

The flat keys `data.postgresPort`, `data.s3Port` and a boolean `data.s3`
are accepted too and win over the keys above when set; prefer the keys
above. Helm prints `cannot overwrite table with non table` for a boolean
`data.s3`, which is harmless. A boolean `data.s3` also turns
`data.s3.external` off.

### External S3 (Hetzner Object Storage)

You can keep files in an S3 service outside the cluster, for example
Hetzner Object Storage at `https://<location>.your-objectstorage.com`. The
backend talks to it over HTTPS on port 443. The default-deny policy blocks
that until you allow it. These keys work on their own: they do not need
`data.enabled` or `data.s3.enabled`.

1. Point the module at the endpoint in its configuration (for example
   `S3_ENDPOINT=https://fsn1.your-objectstorage.com`, the bucket and the
   region), and keep the access keys in the module's Secret (see
   [Secrets](secrets.md)).
2. Turn off the in-cluster S3 rule if you do not run Garage, and allow the
   external host. With **Cilium** (the default, `networkPolicy.gateway.cilium: true`):

    ```yaml
    networkPolicy:
      data:
        s3:
          enabled: false
          external:
            fqdns:
              - fsn1.your-objectstorage.com
              - "*.fsn1.your-objectstorage.com"   # bucket-style host names
    ```

    The chart renders a `CiliumNetworkPolicy` named `<module>-external-s3`
    with two egress rules: DNS to `kube-dns` with `rules.dns`, which sends the
    pod's lookups through Cilium's DNS proxy so Cilium learns the addresses
    behind the names, and `toFQDNs` on port 443. Without the DNS rule a
    `toFQDNs` rule never matches.

    **Without Cilium** (`networkPolicy.gateway.cilium: false`), a plain
    NetworkPolicy cannot match host names. List the provider's address
    ranges instead; they can change, so check the provider's documentation:

    ```yaml
    networkPolicy:
      gateway: { cilium: false }
      data:
        s3:
          enabled: false
          external:
            cidrs: ["203.0.113.0/24"]   # placeholder, use the provider's ranges
    ```

3. Preview and look for the new rule:

    ```powershell
    helm template stash deploy/charts/stash -n conservices-stash -f values-stash.yaml | Select-String -Context 0,30 "stash-external-s3"
    ```

    You should see the `CiliumNetworkPolicy` with your host names under
    `toFQDNs` (or the `ipBlock` rule in `stash-backend`).

The backend trusts public certificate authorities even with internal TLS
on, so the provider's certificate is accepted without extra settings; see
[Internal TLS](internal-tls.md#public-certificates-stay-trusted).

## Private images

If the images come from a private registry (for example a private GitHub
Container Registry package), create a pull Secret in the module's namespace
and name it in `imagePullSecrets`. The chart adds it to every pod it
creates (backend, web app, Den's operator, and the `migrate` initContainer
runs in the backend pod).

1. Create the Secret, from your secret manager in production (see
   [Secrets](secrets.md)). For a local trial only:

    ```powershell
    kubectl -n conservices-stash create secret docker-registry ghcr-pull --docker-server=ghcr.io --docker-username=<user> --docker-password=change-me
    ```

2. Set the value:

    ```yaml
    imagePullSecrets:
      - name: ghcr-pull
    ```

3. After the upgrade, `kubectl -n conservices-stash get pods` shows the pods
   `Running` instead of `ErrImagePull` / `ImagePullBackOff`.

| Value | Default | What it does |
| --- | --- | --- |
| `imagePullSecrets` | `[]` | List of `{name: ...}`; set on every pod spec of the release. |

## Upgrade

1. Read the module's `CHANGELOG.md` from your version to the new one
   ([Versions and upgrades](versioning.md#upgrading)). If its *Needs Den*
   line names a newer Den, or a different Den MAJOR, upgrade Den first.
2. Make a backup: Den → **Backups → Back up now**.
3. Use the chart of the new version: check out its release tag, for
   example `git checkout stash/v1.1.0` in your clone of `con-services`.
   Change every image tag of the module in your values file to the same new
   tag (`1.1.0-1`).
4. Look at the difference. The [helm-diff](https://github.com/databus23/helm-diff)
   plugin shows it like `kubectl diff`:

    ```sh
    helm plugin install https://github.com/databus23/helm-diff   # once
    helm diff upgrade stash deploy/charts/stash -n conservices-stash -f values/stash.yaml
    ```

5. Upgrade and wait for it to finish:

    ```sh
    helm upgrade stash deploy/charts/stash -n conservices-stash -f values/stash.yaml --wait --timeout 10m
    ```

    ```text
    Release "stash" has been upgraded. Happy Helming!
    NAME: stash
    STATUS: deployed
    REVISION: 2
    ```

6. Check `/api/health` reports the new version and sign in once.

!!! note "Running behind an ingress controller instead of the Gateway"
    The charts default to the Gateway API: `route.enabled: true`,
    `ingress.enabled: false`, `internalTLS.ingressNginxAnnotations: false`,
    the OIDC rule to Keycloak in-cluster, and data rules that select
    CloudNativePG and Garage pods. ingress-nginx is not maintained; do not
    use it. To use a plain `Ingress` with another controller (for example
    Traefik), set in your values file `route.enabled: false`,
    `ingress.enabled: true`, `ingress.className`,
    `networkPolicy.gateway.cilium: false`,
    `networkPolicy.ingressControllerNamespace` (your controller's
    namespace), `networkPolicy.oidcViaIngressController: true`,
    `networkPolicy.oidc.inCluster: false` and, if needed, data selectors
    that match your database and S3 from
    [Network policy values](#network-policy-values); the controller's HTTPS
    settings are in
    [Internal TLS: Other ingress controllers](internal-tls.md#other-ingress-controllers).

Always pass your values file (`-f`). `helm upgrade` without it resets every
setting to the chart defaults. Do **not** use `--reuse-values` across chart
versions: new chart keys would stay unset.

## Roll back

Helm keeps the previous revisions:

```sh
helm history stash -n conservices-stash
```

```text
REVISION  UPDATED                   STATUS      CHART        APP VERSION  DESCRIPTION
1         Fri Nov  6 10:12:03 2026  superseded  stash-1.0.0  1.0.0        Install complete
2         Fri Nov  6 14:40:51 2026  deployed    stash-1.1.0  1.1.0        Upgrade complete
```

```sh
helm rollback stash 1 -n conservices-stash --wait
```

!!! warning "Rolling back images does not roll back the database"
    Migrations only go forward. If the new version's migration ran, the old
    version may not understand the database any more. Restore the module's
    database from the backup you made before upgrading first; see
    [Rolling back](versioning.md#rolling-back).

After a rollback, put the old tag back in your values file too, or the next
`helm upgrade` brings the new one back.

## Uninstall

```sh
helm uninstall stash -n conservices-stash
```

This removes the Deployments, Services, HTTPRoute, BackendTLSPolicy,
Ingress, PodDisruptionBudgets, ConfigMaps, NetworkPolicies and the
CiliumNetworkPolicy. It does **not** touch the Secret, the access config
ConfigMap, the namespace, the database or the bucket. The Wiki chart's
PersistentVolumeClaim is removed with the release, so make sure Wiki shut
down cleanly first. To also remove the database, remove the module in Den
(**Modules → Remove → Delete its database too**), which backs it up first.

## GitOps with Argo CD or Flux

Point your GitOps tool at the chart folder and at the values file in your
own repository. Argo CD example with two sources (the chart from
`con-services`, the values from your repository):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: conservices-stash
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://github.com/AGlElectronics/con-services.git
      targetRevision: stash/v1.0.0    # the chart release tag <app>/vX.Y.Z, never a branch
      path: deploy/charts/stash
      helm:
        valueFiles:
          - $values/values/stash.yaml
    - repoURL: https://git.example.org/ops/conservices.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: conservices-stash
  syncPolicy:
    syncOptions: ["CreateNamespace=false"]
```

Keep `CreateNamespace=false`: the namespace needs the labels from step 3.

## Troubleshooting

**`Error: execution error at (stash/templates/deployment.yaml): image.backend.tag is required (MAJOR.MINOR.PATCH-BUILD)`**
: The tag is empty (always the case for HR and Rally). Set every tag under
  `image:` in your values file.

**Uploads or backups to external S3 time out**
: The network policy blocks the call. Check that
  `networkPolicy.data.s3.external.fqdns` matches the exact host the backend
  calls (bucket-style hosts need `"*.<location>.your-objectstorage.com"`) and
  that `kubectl get cnp -n <namespace>` lists `<module>-external-s3`. With
  `networkPolicy.gateway.cilium: false`, only `external.cidrs` applies.
  `hubble observe -n <namespace> --verdict DROPPED` shows what Cilium drops.
  `x509: certificate signed by unknown authority` instead means someone set
  `SSL_CERT_FILE`; see [Internal TLS](internal-tls.md#public-certificates-stay-trusted).

**Pods stay in `ErrImagePull` or `ImagePullBackOff` with `401 Unauthorized`**
: The registry needs credentials. Create the pull Secret in the module's
  namespace and set `imagePullSecrets` ([Private images](#private-images)).

**`backend.replicas must be 1 for this module (got 2)`**
: The chart protects the single-replica rule. Scale the frontend instead
  (`frontend.replicas`); see [High availability](#high-availability) and
  [Scaling](running.md#scaling).

**A node drain hangs on `Cannot evict pod as it would violate the pod's disruption budget`**
: A web app runs with only one ready replica, so its PDB allows no
  eviction. Check why the other pod is not ready (`kubectl get pods -n
  <namespace>`), or keep `frontend.replicas` at 2 or more. Singleton
  backends never have a PDB.

**`Error: INSTALLATION FAILED: namespaces "conservices-stash" not found`**
: Create the namespace first (step 3). Do not use `--create-namespace`: it
  creates the namespace without the labels and the module cannot reach Den.

**Pods stay in `CreateContainerConfigError`**
: The Secret or the access config ConfigMap is missing. `kubectl describe pod`
  says which:

    ```sh
    kubectl describe pod -n conservices-stash -l app.kubernetes.io/component=backend | grep -A2 -i error
    ```

    ```text
    Warning  Failed  12s  kubelet  Error: secret "stash-secrets" not found
    ```

**`violates PodSecurity "restricted:latest"`** when you add `extraVolumes` or a sidecar
: Everything you add must also meet the restricted rules; see
  [Pod Security](network-policies.md#pod-security).

**`helm upgrade` hangs and fails with `context deadline exceeded`**
: The new backend did not become ready. Look at the migration and backend
  logs, then roll back if needed:

    ```sh
    kubectl logs -n conservices-stash deploy/stash-backend -c migrate   # modules with a migrate image
    kubectl logs -n conservices-stash deploy/stash-backend
    ```

**The site does not answer at all (`404` from the gateway or connection refused) and the HTTPRoute is not `Accepted`**
: Read the route's status:

    ```sh
    kubectl describe httproute -n conservices-stash stash
    ```

    `NotAllowedByListeners`: the Gateway's listener does not admit routes
    from this namespace (`allowedRoutes.namespaces`) or the host does not
    match the listener's `hostname`. `NoMatchingParent`: `route.parentRefs`
    names a Gateway or `sectionName` that does not exist. `ResolvedRefs
    False` with `RefNotPermitted` or `BackendNotFound`: the Service name or
    port is wrong (it must be the web app on 443, or 80 without internal TLS).

**The gateway answers `503` (`upstream connect error ... TLS error` or `CERTIFICATE_VERIFY_FAILED`)**
: The `BackendTLSPolicy` does not match the web app's certificate.
  `validation.hostname` must be one of the certificate's names,
  `<module>-frontend.<namespace>.svc.cluster.local`; the chart sets that,
  so this happens after renaming the namespace without re-issuing the
  certificate, or with `createCertificates: false` and a certificate
  lacking that name. Also check that the ConfigMap `conservices-internal-ca`
  exists in the namespace and that the policy is `Accepted`:
  `kubectl describe backendtlspolicy -n conservices-stash stash-frontend`.
  A plain `503 no healthy upstream` means no web app pod is ready.

**Browsers get `connection reset` or the gateway times out (`504`, `upstream request timeout`) although the pods are ready**
: The gateway's traffic is dropped by the network policies. With Cilium
  the `CiliumNetworkPolicy` `<module>-web-from-gateway` must exist
  (`networkPolicy.gateway.cilium: true` and Cilium's CRDs installed):

    ```sh
    kubectl get ciliumnetworkpolicy -n conservices-stash
    hubble observe --namespace conservices-stash --verdict DROPPED --from-identity 8
    ```

    Identity 8 is Cilium's reserved `ingress` identity. A `504` after
    exactly `route.timeout` on long requests means the route timeout is
    too short: raise `route.timeout`.

**The backend crashes with `oidc discovery … i/o timeout` or `x509: certificate is valid for keycloak…, not auth.example.org`**
: `i/o timeout`: the backend cannot reach Keycloak. Check
  `networkPolicy.oidc` matches the Keycloak pods' labels
  (`kubectl get pods -n conservices-identity --show-labels`) and that
  Keycloak's namespace admits the module. The `x509` error: CoreDNS
  rewrites `auth.<domain>` to `keycloak-public`, but Keycloak's internal
  certificate lacks `auth.<domain>` as a name; add it to the Keycloak
  certificate.

**`no matches for kind "CiliumNetworkPolicy"`, `"HTTPRoute"` or `"BackendTLSPolicy"`**
: The cluster lacks Cilium's or the Gateway API CRDs (`BackendTLSPolicy`
  `v1` needs Gateway API v1.4 or later). Install them, or set
  `networkPolicy.gateway.cilium: false` / `route.enabled: false`.

**The module shows *Waiting for Den* and its API answers `503 den_pairing_required`**
: Working as designed with `den.mode: required` (the default) until the
  module is paired. Pair it from Den (step 10). If this module runs without
  Den, set `den.mode: standalone` and run `helm upgrade`.

**`den.mode must be "required" or "standalone"`** or **`config.DEN_MODE is not allowed`**
: Set only `den.mode`, to one of the two values; remove `DEN_MODE` from
  `config`.

**Uploads fail with `413 Request Entity Too Large`**
: Raise `frontend.clientMaxBodySize`; the gateway has no limit of its own.

**`another operation (install/upgrade/rollback) is in progress`**
: A previous command was interrupted. Check `helm history`; if the last
  revision is `pending-upgrade`, roll back to the last `deployed` revision.

## Related pages

- [Running on Kubernetes](running.md): the Kustomize side and scaling rules.
- [Versions and upgrades](versioning.md): tags and the upgrade procedure.
- [Secrets](secrets.md): creating `existingSecret` with External Secrets.
- [Network policies](network-policies.md): what `networkPolicy.*` allows.
