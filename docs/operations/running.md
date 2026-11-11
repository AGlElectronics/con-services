# Running on Kubernetes

**Goal:** set up your own installation from the Kustomize manifests, add
modules to it, keep it running (scaling, resources, restarts, migrations)
and fix the usual problems. Upgrading is on its own page,
[Versions and upgrades](versioning.md); modules installed with Helm are on
[Installing modules with Helm](helm.md).

!!! tip "For production, use the Argo CD path"
    The tested production path is [Deploy with Argo CD](../deploy/index.md):
    Argo CD installs everything from a Git repository, with Cilium,
    CloudNativePG, OpenBao and managed S3. Most of this page (scaling,
    resources, logs, migrations, troubleshooting) applies to both; the
    set-up steps below are for running the plain Kustomize manifests
    yourself.

## Set up your own installation

1. **Prepare the cluster:** Cilium with the Gateway API turned on
   ([what it needs](network-policies.md#what-con-services-needs-from-cilium)), a Gateway
   called `public` in the namespace `conservices-gateway` with a
   load-balancer address ([The Gateway](#the-gateway)), cert-manager and
   trust-manager ([Internal TLS](internal-tls.md#set-it-up)), and the
   External Secrets Operator
   ([Production](production.md#the-production-shape)).
2. **Create your overlay** in your own Git repository, starting from the
   production-shaped example:

    ```sh
    cp -r deploy/kubernetes/overlays/production-external-secrets ../my-ops/overlays/production
    ```

    Change `resources: ../../base` to point at a pinned copy of the base,
    for example a Git URL with the `con-services` tag `vX.Y.Z` of the
    shared pieces
    ([which tag to pin](versioning.md#the-main-repositorys-own-tags)):
    `https://github.com/AGlElectronics/con-services//deploy/kubernetes/base?ref=v1.0.0`.

3. **Fill in** your host names (on the HTTPRoutes and Keycloak's
   certificate), image tags, `BACKUP_AGE_RECIPIENTS`, backup and file
   storage endpoints at your managed S3 service, and your own
   `den-frontend` image. Add a CoreDNS rewrite so `auth.<domain>` resolves
   to `keycloak-public.conservices-identity.svc.cluster.local` inside the
   cluster ([Internal TLS](internal-tls.md#gateway-api-cilium)).
4. **Store the secrets** in your secret manager under the paths in
   `external-secrets.yaml` ([Secrets](secrets.md#recommended-external-secrets-operator)).
5. **Check and apply:**

    ```sh
    kubectl kustomize ../my-ops/overlays/production > /tmp/render.yaml   # renders without errors
    kubectl apply -k ../my-ops/overlays/production
    kubectl get pods -A -l app.kubernetes.io/part-of=conservices
    ```

6. Continue with [How the platform starts, step 2](../getting-started/how-the-platform-starts.md#step-2-check-that-den-is-ready).

## The manifests

Everything is in the `deploy/kubernetes/` folder of the
[con-services](https://github.com/AGlElectronics/con-services) repository,
written for **Kustomize** (built into `kubectl`):

```text
deploy/kubernetes/
├── base/                    the platform: never edit, override in an overlay
│   ├── namespaces.yaml      conservices-identity, -data, -den
│   ├── identity/            Keycloak, keycloak-public and its HTTPRoute
│   ├── data/                PostgreSQL and the S3 server (local trial only)
│   └── den/                 den-backend, den-frontend, den-operator, HTTPRoute
├── modules/
│   ├── stash/               Stash, in conservices-stash
│   └── README.md            the other modules (planned)
├── local-cluster/           kind and Cilium settings for the local trial
└── overlays/
    ├── example/             local trial of the platform, with the Gateway
    ├── example-stash/       local trial of Stash
    └── production-external-secrets/   production-shaped example
```

An **overlay** is your installation: a folder with a `kustomization.yaml`
that points at the base and sets your image tags, host names and secrets.
Copy `overlays/example` to start your own, keep it in your own Git
repository, and apply it with:

```sh
kubectl apply -k deploy/kubernetes/overlays/<yours>
```

Before applying, you can see exactly what would be created:

```sh
kubectl kustomize deploy/kubernetes/overlays/<yours>
kubectl diff -k deploy/kubernetes/overlays/<yours>
```

## The Gateway

The manifests publish the web apps with the
[Gateway API](../concepts/glossary.md#gateway-api), not with `Ingress`
objects. Three kinds of objects work together:

| Object | Where | What it does |
| --- | --- | --- |
| `Gateway` `public` | `conservices-gateway` (yours; `overlays/example/gateway.yaml` for the trial) | Listens on ports 80 and 443, holds the public certificate, accepts routes from namespaces labelled `app.kubernetes.io/part-of: conservices`. |
| `HTTPRoute` | each module (`den`, `keycloak`, `stash`) | Sends a host name to the web app's Service, attached to the listener `https`, with request timeouts (30 minutes for removing a module in Den, which backs up a database first). |
| `BackendTLSPolicy` | next to each route | Makes the Gateway talk HTTPS to the web app and check its certificate against the internal CA ([Internal TLS](internal-tls.md#gateway-api-cilium)). |

The Gateway runs on Cilium's Envoy, which reaches pods with Cilium's
reserved identity `ingress`; a `CiliumNetworkPolicy` next to each web app
admits it ([Network policies](network-policies.md)). Keycloak's route only
publishes `/realms/` and `/resources/`; the example overlay adds
`/admin/` for the trial.

To use your own Gateway:

1. Create the Gateway `public` in `conservices-gateway`, or patch the
   routes' `parentRefs` in your overlay to point at yours. Keep a listener
   named `https`, or patch `sectionName` too.
2. Give it a load-balancer address (Cilium LB IPAM on your own servers, the
   cloud's load balancer elsewhere; see
   [Production](production.md#a-load-balancer-address-for-the-gateway)).
3. Put the TLS certificate for all host names in the Secret its listener
   names, for example with cert-manager.

Without Cilium you need another Gateway API implementation and your own
replacements for the `CiliumNetworkPolicy` objects. ingress-nginx is no
longer maintained; do not use it. If you must use an `Ingress` controller,
use Traefik with the Helm charts (`ingress.enabled: true`, see
[Installing modules with Helm](helm.md)).

## What runs where

| Namespace | Workload | Kind | Replicas | Update strategy | Probes |
| --- | --- | --- | --- | --- | --- |
| `conservices-identity` | `keycloak` | Deployment | 1 | Recreate | `/health/started`, `/health/ready`, `/health/live` on port 9000 |
| `conservices-data` | `postgres` | StatefulSet | 1 | RollingUpdate | `pg_isready` |
| `conservices-data` | `s3` (SeaweedFS, local trial only) | Deployment | 1 | Recreate | `/healthz` (readiness); liveness also restarts it when its certificate changes |
| `conservices-den` | `den-backend` (+ `migrate` initContainer) | Deployment | 1 or more | RollingUpdate | `/livez` (liveness), `/readyz` (readiness) |
| `conservices-den` | `den-frontend` | Deployment | 2 or more | RollingUpdate | `/` on port 8080 (HTTPS) |
| `conservices-den` | `den-operator` | Deployment | **exactly 1** | Recreate | `/livez` |
| `conservices-stash` | `stash-backend` | Deployment | **exactly 1** | Recreate | TCP 8080 (liveness), `/api/health` (readiness) |
| `conservices-stash` | `stash-frontend` | Deployment | 2 or more | RollingUpdate | `/` on port 8080 (HTTPS) |

Every pod carries `app.kubernetes.io/part-of: conservices`, so one command
shows all of them:

```sh
kubectl get pods -A -l app.kubernetes.io/part-of=conservices
```

## Scaling

Some parts must run as **exactly one** replica. Scaling them up breaks
things in ways that are not obvious:

| Workload | Why only one |
| --- | --- |
| `den-operator` | Runs the daily backup on a timer and allows only one backup or database removal at a time, using an in-process lock. Two operators would back up twice and could drop a database during a backup. |
| `stash-backend` | Applies its database migrations in-process at start-up. Two replicas starting together would migrate concurrently. |
| Wiki backend (planned) | Keeps live-editing buffers on local disk. |
| `keycloak` | The example runs Keycloak in development mode without a cluster cache. For several replicas, use the Keycloak Operator; see [Production](production.md#keycloak). |

The frontends are plain nginx with no state; scale them freely:

```sh
kubectl scale -n conservices-den deploy/den-frontend --replicas=3
```

`den-backend` may run more than one replica too: backup download links are
stored in PostgreSQL, and when several pods start at once their `migrate`
initContainers wait on a PostgreSQL advisory lock. The rate limits on the
public endpoints count per replica.

```sh
kubectl scale -n conservices-den deploy/den-backend --replicas=2
```

To make that permanent, set `replicas` in your overlay with a patch, since
the next `kubectl apply -k` resets it.

## Resources

Every container has requests and limits. The base values are sized for a
small convention and a local cluster:

| Container | Requests (CPU / memory) | Limits (CPU / memory) |
| --- | --- | --- |
| `keycloak` | 250m / 768Mi | 2 / 1536Mi |
| `postgres` | 100m / 256Mi | 1 / 1Gi |
| `s3` | 50m / 128Mi | 500m / 1Gi |
| `den-backend` | 50m / 64Mi | 500m / 256Mi |
| `migrate` (initContainer) | 25m / 32Mi | 500m / 128Mi |
| `den-frontend`, `stash-frontend` | 10m / 16Mi | 200m / 64Mi |
| `den-operator` | 50m / 64Mi | 1 / 512Mi |
| `stash-backend` | 50m / 64Mi | 500m / 256Mi |

The operator writes database dumps to a temporary volume (`/tmp`, limited to
5 GiB) before encrypting and uploading them. If your databases are larger,
raise that `sizeLimit` with a patch. Watch real usage with
`kubectl top pods -A` (needs metrics-server) and adjust in your overlay.

## Add a module

Den must already run. For each module:

1. **Den:** Admin console → **Modules → New module**, tick *Create a
   database for it*, copy the connection URL shown once.
2. **Secret manager:** store `DATABASE_URL` and the module's other secrets
   ([inventory](secrets.md#inventory)), and add its `ExternalSecret`
   ([procedure](secrets.md#add-a-modules-secrets)).
3. **Storage:** create the module's bucket and keys limited to it at your
   S3 provider (Den does not do this yet), and add the bucket to
   `FILES_S3_BUCKETS` in your platform overlay so it is backed up.
4. **Sign-in:** make sure the module's client exists in Keycloak (the
   imported realm has them for the known modules) with your real redirect
   URI.
5. **Deploy:** with the [Helm chart](helm.md#install-a-module), or with
   Kustomize for Stash (`modules/stash/` plus an overlay like
   `overlays/example-stash`).
6. **Network:** add egress rules for anything external it uses and for
   [integrations](network-policies.md#calls-between-modules).
7. **Pair:** Den → **Modules → Pair**, paste the URL in the module's
   **Settings → Den connection**.
8. **Check:** Den's Modules page shows it as *paired*, and the portal lists
   it under **Your services**.

The worked example with expected output is
[How the platform starts, step 4](../getting-started/how-the-platform-starts.md#step-4-deploy-a-module-stash).

## Logs

More on log formats, collecting logs and monitoring:
[Logs, health and monitoring](observability.md).

```sh
kubectl logs -n conservices-den deploy/den-backend -f            # follow
kubectl logs -n conservices-den deploy/den-backend -c migrate    # the migration step
kubectl logs -n conservices-den deploy/den-operator --since=1h   # last hour
kubectl logs -n conservices-den deploy/den-backend --previous    # before the last crash
```

Den's backend logs one line per request (`method`, `path`, `status`,
`duration`, `request_id`). With `APP_ENV=production`, as in the manifests,
every line is a JSON object, ready for a log collector such as Loki or
Elasticsearch. The `request_id` matches the `X-Request-ID` response header,
so you can find the log line of a failed request.

## Health

Kubernetes uses the probes in the table above. You can check Den by hand
through its web address:

```sh
curl https://den.conservices.test/api/health
```

```json
{"database":"ok","status":"ok","uptime_sec":5321,"version":"1.0.0-1"}
```

`/livez` and `/readyz` are only reachable on the pod itself (see the
[API reference](../modules/den/api.md#health)). The Den admin console also
warns on every page when backups need attention; see
[Backups](../modules/den/admin-guide.md#backups).

## Database migrations

Den's database structure is changed by **migrations**: numbered SQL files
inside the `den-backend` image. The `migrate` initContainer applies any that
are missing every time the pod starts, then exits; the server starts only if
it succeeded. The server itself never changes the database structure. So in
normal use, migrations just happen when you install or upgrade.

To see which migrations are applied, run the migrate binary inside the
running backend container. The binary is in the same image, and the
container already has `DATABASE_URL`:

```sh
kubectl exec -n conservices-den deploy/den-backend -- /den-migrate -status
```

The output lists every migration with the time it was applied, or
`Pending`.

!!! note "Migrations only go forward"
    To undo a bad upgrade, restore the `den` database from a backup taken
    before it (see [Restore](databases-and-backups.md#restore)).

## Restarting

```sh
kubectl rollout restart -n conservices-den deploy/den-backend
kubectl rollout status -n conservices-den deploy/den-backend
```

Because `den-backend` uses `Recreate`, Den is unavailable for the few
seconds between the old pod stopping and the new one becoming ready.

## Keycloak realm changes

Keycloak imports `realm-conservices.json` only when the realm does not exist
yet. If an upgrade changes the realm (for example a new module's sign-in
client) on an existing installation, make the change in the Keycloak admin
console, or run the repository's patch script inside the pod:

```sh
kubectl exec -n conservices-identity deploy/keycloak -- bash /opt/keycloak/data/import/apply-mvp.sh
```

!!! note
    `apply-mvp.sh` is only in the pod if you add it to the `keycloak-realm`
    ConfigMap next to the realm file. The example overlay does not.

## Troubleshooting

Start with an overview, then look closer at whatever is not `Running`:

```sh
kubectl get pods -A -l app.kubernetes.io/part-of=conservices -o wide
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -20
```

**`kubectl apply -k` fails with `no matches for kind "ExternalSecret"`**
: The External Secrets Operator is not installed, or is older than the
  `external-secrets.io/v1` API the overlay uses. Install or upgrade ESO,
  then apply again.

**`kubectl apply -k` fails with `accumulating resources: … no such file or directory`**
: A path in your overlay is wrong, or the `local/` files of the example
  overlay are missing. `kubectl kustomize <overlay>` prints the exact file.

**`Error from server (Forbidden): … violates PodSecurity "restricted:latest"`**
: Something you added (a sidecar, a debug container, a patched
  `securityContext`) breaks the restricted rules; the message lists which
  field. See [Pod Security](network-policies.md#pod-security).

**A pod is `OOMKilled`** (`kubectl describe pod` → *Last State: Terminated, Reason: OOMKilled*)
: Raise that container's memory limit with a patch in your overlay. The
  operator during backups and Keycloak are the usual candidates.

**`den-operator` backups fail with `no space left on device`**
: The dump did not fit into `/tmp` (5 GiB). Raise the `sizeLimit` of the
  operator's `tmp` volume with a patch.

**You scaled a backend to two replicas and things broke**
: See [Scaling](#scaling): the operator and the Stash backend must stay at
  one replica. Scale back, for example:
  `kubectl scale -n conservices-den deploy/den-operator --replicas=1`.

**`kubectl apply -k` fails with `no matches for kind "HTTPRoute"` or `"BackendTLSPolicy"`**
: The Gateway API CRDs are missing or older than v1.4 (BackendTLSPolicy is
  `v1` from Gateway API v1.4 on). Install the standard channel, for example
  `kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml`.
  `no matches for kind "CiliumNetworkPolicy"` means Cilium is not installed.

**A route shows `Accepted: False` with `NotAllowedByListeners`**
: The route's namespace lacks the label `app.kubernetes.io/part-of: conservices`,
  or your Gateway has no listener named `https`. Check with
  `kubectl get httproute -A -o yaml` under `status.parents`.

**Changes made with `kubectl edit` or `kubectl scale` disappear**
: The next `kubectl apply -k` restores what the overlay says. Make every
  lasting change in the overlay.

More symptoms (image pulls, sign-in loops, timeouts between namespaces) are
on the [Troubleshooting](../getting-started/troubleshooting.md) page.

## Related pages

- [Installing modules with Helm](helm.md)
- [Versions and upgrades](versioning.md)
- [Network policies and isolation](network-policies.md)
- [Logs, health and monitoring](observability.md)
- [Production and security](production.md)
