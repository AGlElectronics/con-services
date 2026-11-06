# Running on Kubernetes

**Goal:** set up your own installation from the manifests, add modules to
it, keep it running (scaling, resources, restarts, migrations) and fix the
usual problems. Upgrading is on its own page,
[Versions and upgrades](versioning.md); modules installed with Helm are on
[Installing modules with Helm](helm.md).

## Set up your own installation

1. **Prepare the cluster:** a CNI that enforces NetworkPolicy (Cilium
   recommended, [install steps](network-policies.md#installing-cilium)), an
   ingress controller behind a load balancer, cert-manager, and the External
   Secrets Operator ([Production](production.md#the-production-shape)).
2. **Create your overlay** in your own Git repository, starting from the
   production-shaped example:

    ```sh
    cp -r deploy/kubernetes/overlays/production-external-secrets ../my-ops/overlays/production
    ```

    Change `resources: ../../base` to point at a pinned copy of the base,
    for example a Git URL with a tag:
    `https://github.com/AGlElectronics/con-services//deploy/kubernetes/base?ref=v1.0.0`.

3. **Fill in** your host names, image tags, `BACKUP_AGE_RECIPIENTS`, backup
   and file storage endpoints, and your own `den-frontend` image.
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
│   ├── identity/            Keycloak
│   ├── data/                PostgreSQL and MinIO (simple in-cluster option)
│   └── den/                 den-backend, den-frontend, den-operator
├── modules/
│   ├── stash/               Stash, in conservices-stash
│   └── README.md            the other modules (planned)
└── overlays/
    ├── example/             local example installation of the platform
    └── example-stash/       local example installation of Stash
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

## The ingress controller

The manifests use standard Kubernetes `Ingress` objects with
`ingressClassName: nginx` and a few `nginx.ingress.kubernetes.io/*`
annotations (body size, read timeout, buffer size). The quickstart installs
[ingress-nginx](https://kubernetes.github.io/ingress-nginx/) `v1.12.1`,
which is enough for a local trial; the project stopped active development
in 2026.

In production you can use any controller that supports `Ingress`, for
example Traefik, HAProxy Ingress, or the Gateway API implementation of
Cilium or your cloud. When you switch:

1. Set `ingressClassName` on the Ingresses with a patch in your overlay.
2. Translate the annotations: request bodies up to 20 MiB for Den and 50 MiB
   for Stash, a 30-minute read timeout for Den (module removal backs up a
   database first), and large enough response header buffers for Keycloak.
3. Change the network policies that admit `ingress-nginx`: they select the
   controller by its namespace (`kubernetes.io/metadata.name: ingress-nginx`).
4. Run two or more controller replicas behind a load balancer (see
   [Production](production.md#load-balancer-in-front-of-the-ingress-controller)).

## What runs where

| Namespace | Workload | Kind | Replicas | Update strategy | Probes |
| --- | --- | --- | --- | --- | --- |
| `conservices-identity` | `keycloak` | Deployment | 1 | Recreate | `/health/started`, `/health/ready`, `/health/live` on port 9000 |
| `conservices-data` | `postgres` | StatefulSet | 1 | RollingUpdate | `pg_isready` |
| `conservices-data` | `minio` | Deployment | 1 | Recreate | `/minio/health/ready`, `/minio/health/live` |
| `conservices-den` | `den-backend` (+ `migrate` initContainer) | Deployment | **exactly 1** | Recreate | `/livez` (liveness), `/readyz` (readiness) |
| `conservices-den` | `den-frontend` | Deployment | 2 or more | RollingUpdate | `/` on port 8080 |
| `conservices-den` | `den-operator` | Deployment | **exactly 1** | Recreate | `/livez` |
| `conservices-stash` | `stash-backend` | Deployment | **exactly 1** | Recreate | TCP 8080 (liveness), `/api/health` (readiness) |
| `conservices-stash` | `stash-frontend` | Deployment | 2 or more | RollingUpdate | `/` on port 8080 |

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
| `den-backend` | Backup download links (`/api/v1/backup-downloads/{token}`) are kept in the memory of the process that created them; a second replica would answer *download link not found* for half the clicks. The `migrate` initContainer also must never run twice at the same time, which `Recreate` guarantees. |
| `den-operator` | Runs the daily backup on a timer and allows only one backup or database removal at a time, using an in-process lock. Two operators would back up twice and could drop a database during a backup. |
| `stash-backend` | Applies its database migrations in-process at start-up. Two replicas starting together would migrate concurrently. |
| Wiki backend (planned) | Keeps live-editing buffers on local disk. |
| `keycloak` | The example runs Keycloak in development mode without a cluster cache. For several replicas, use the Keycloak Operator; see [Production](production.md#keycloak). |

The frontends are plain nginx with no state; scale them freely:

```sh
kubectl scale -n conservices-den deploy/den-frontend --replicas=3
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
| `minio` | 50m / 128Mi | 500m / 512Mi |
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
: See [Scaling](#scaling): backends must stay at one replica. Scale back:
  `kubectl scale -n conservices-den deploy/den-backend --replicas=1`.

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
