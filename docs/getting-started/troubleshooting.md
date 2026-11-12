# Troubleshooting

Problems people commonly hit when running Con Services on Kubernetes, and how
to fix them. Each entry starts with what you see. For the Docker Compose
development stack, see
[Local development](../contributing/local-development.md#troubleshooting).

!!! tip "The three commands that answer most questions"
    ```sh
    kubectl get pods -A -l app.kubernetes.io/part-of=conservices
    kubectl describe pod -n conservices-den <pod-name>
    kubectl logs -n conservices-den <pod-name> --tail 100
    ```

    `get pods` shows what is wrong, `describe` shows why Kubernetes thinks so
    (look at **Events** at the bottom), and `logs` shows what the program
    itself said. Add `--previous` to `logs` to see the output of the last
    crashed run, and `-c migrate` to see Den's migration step.

## kubectl cannot connect to the cluster

**You see:** `Unable to connect to the server` or
`The connection to the server localhost:6443 was refused`.

**Fix:** start Docker Desktop (Linux: Docker) and wait until it shows
*Engine running*. Check that the cluster's container runs and that kubectl
talks to the right cluster:

```sh
docker ps --filter name=conservices-control-plane --format "{{.Names}} {{.Status}}"
kubectl config current-context
```

The first line should say `conservices-control-plane Up …`; if it prints
nothing, start it with `docker start conservices-control-plane`. The
context should be `kind-conservices`. Switch with
`kubectl config use-context kind-conservices`.

## Cilium does not start on the kind cluster

**You see:** after step 4c of the quickstart the node stays `NotReady`, or
`kubectl get pods -n kube-system -l k8s-app=cilium` shows
`CrashLoopBackOff`.

**Fix:** read the agent's log:

```sh
kubectl logs -n kube-system daemonset/cilium --tail 30
```

- `unable to contact k8s api-server` or `dial tcp …:6443: i/o timeout`:
  `k8sServiceHost` in `deploy/kubernetes/local-cluster/cilium-values.yaml`
  must be the node's name, `conservices-control-plane`. If you changed the
  cluster name in `kind-config.yaml`, change it there too and run
  `helm upgrade cilium cilium/cilium --version 1.20.4 -n kube-system -f deploy/kubernetes/local-cluster/cilium-values.yaml`.
- The cluster was created without `kind-config.yaml` (it then already has
  a network plugin and kube-proxy). Delete it with
  `kind delete cluster --name conservices` and start again at step 4a.

## The Gateway is not programmed

**You see:** `kubectl get gateway -n conservices-gateway` shows
`PROGRAMMED False` or `Unknown`, and the browser cannot connect.

**Fix:** read the Gateway's conditions:

```sh
kubectl describe gateway -n conservices-gateway public
```

- `GatewayClass "cilium" not found` or no status at all: Cilium's Gateway
  support is off. Check `kubectl get gatewayclass`; if it is empty, the
  Gateway API definitions were installed after Cilium. Restart the operator
  with `kubectl -n kube-system rollout restart deployment/cilium-operator`.
- `InvalidCertificateRef` or `secret "conservices-tls" not found`: the
  certificate from step 5 is missing. Check
  `kubectl get secret -n conservices-gateway conservices-tls`, redo step 5
  and apply again.
- The Gateway is `True` but nothing answers on port 443: Envoy could not
  bind the port. Check `kubectl logs -n kube-system daemonset/cilium-envoy --tail 30`
  for `Permission denied`; the `envoy.securityContext` settings in
  `cilium-values.yaml` must be in place (`helm upgrade` as above).

## The s3 storage pod is not ready

**You see:** `s3-…` in `conservices-data` stays `0/1 Running` or
`ContainerCreating`, or restarts. Den logs `check bucket`.

The trial's file storage is [SeaweedFS](https://github.com/seaweedfs/seaweedfs)
(image `chrislusf/seaweedfs:4.52`), a stand-in for a laptop only;
production uses a managed S3 service such as AWS S3, Hetzner Object
Storage, Cloudflare R2 or Backblaze B2.

**Fix:**

- **`ContainerCreating` with `secret "s3-tls" not found`:** cert-manager has
  not issued the certificate yet. Check
  `kubectl get certificate -n conservices-data s3-tls`; it must say
  `READY True` within a minute (see [Internal TLS](../operations/internal-tls.md)).
- **`CreateContainerConfigError` with `secret "s3-secrets" not found`:** the
  overlay's `secrets.yaml` was not applied. Apply the overlay again.
- **Restarts roughly once every 60 days:** expected. SeaweedFS reads its
  certificate only at start, so the liveness check restarts the pod when
  cert-manager renews `s3-tls`.
- **Anything else:** read `kubectl logs -n conservices-data deploy/s3`. The
  last lines should include `Added admin identity from AWS environment variables`
  and one line per bucket.

## ImagePullBackOff or ErrImagePull

**You see:** a pod with `ImagePullBackOff`; `kubectl describe pod` shows
`Failed to pull image "ghcr.io/aglelectronics/den-backend:1.0.0-1": ... not found`
or `unauthorized`.

**Why and fix:**

- **Typo or unknown tag.** Check the tag in the overlay's `images:` list
  against the published versions on the repository's *Packages* page. Tags
  look like `1.4.2-17`; there is no `latest`.
- **No internet or a proxy.** The node must reach `ghcr.io` and `quay.io`.
- **Rate limit** (`toomanyrequests`) for Docker Hub images (`postgres`,
  `chrislusf/seaweedfs`):
  wait a few minutes; Kubernetes retries by itself.

## A pod is Pending

**You see:** `STATUS Pending` for minutes. `kubectl describe pod` shows
`pod has unbound immediate PersistentVolumeClaims` or `Insufficient memory`.

**Fix:**

- **Volume:** your cluster has no default *StorageClass* (the thing that
  creates disks). Check with `kubectl get storageclass`; the quickstart's
  kind cluster has `standard (default)`. On other clusters install one or
  set `storageClassName` in `base/data/`.
- **Memory or CPU:** the cluster is too small. Give Docker Desktop more
  memory (Settings → Resources; 6 GB or more) and try again.

## CrashLoopBackOff

**You see:** a pod restarting again and again. Read its last run:

```sh
kubectl logs -n conservices-den deploy/den-backend --previous
```

Look at the last line:

| Last log line contains | Meaning | Fix |
| --- | --- | --- |
| `init oidc verifier: oidc discovery` | Den cannot reach `https://auth.conservices.test`. | Wait for Keycloak (see below). Inside the cluster that name points at the Service `keycloak-public`: `kubectl get service -n conservices-identity keycloak-public` must show `CLUSTER-IP 10.96.0.100`, the address in `den-backend-local.yaml`. |
| `x509: certificate signed by unknown authority` or `certificate is valid for keycloak…, not auth.conservices.test` | Den does not trust Keycloak's certificate, or the certificate lacks the name. | Keycloak's internal certificate must list `auth.conservices.test`: `kubectl get certificate -n conservices-identity keycloak-tls -o jsonpath="{.spec.dnsNames}"`. After a change, delete the Secret `keycloak-tls` and restart Keycloak and Den ([Internal TLS](../operations/internal-tls.md#renewal)). |
| `invalid config: ... is required` | A required setting is missing. | Compare with the [configuration reference](../modules/den/configuration.md). |
| `open db` / `password authentication failed` | Wrong database password, or the database volume was created with other passwords. | See [The migration step failed](#den-backend-stays-in-init-the-migration-step-failed). |
| `check bucket` / `create bucket` | Den cannot reach the S3 storage or the keys are wrong. | Check the `s3` pod in `conservices-data` is ready and the `S3_*` keys match `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `s3-secrets` ([The s3 storage pod is not ready](#the-s3-storage-pod-is-not-ready)). |

The operator logs `invalid operator config: ...` the same way; its
settings are in the [operations guide](../operations/databases-and-backups.md#configuration-reference).

## Keycloak is not ready

**You see:** `keycloak-…` stays `0/1 Running` for several minutes, or keeps
restarting.

**Fix:** Keycloak needs one to three minutes on first start. Watch it:

```sh
kubectl logs -n conservices-identity deploy/keycloak -f
```

It is ready when you see `Keycloak 26.8.2 on JVM (powered by Quarkus)
started`. Typical errors:

- `password authentication failed for user "keycloak"`: `KC_DB_PASSWORD`
  differs from `KEYCLOAK_DB_PASSWORD` in `postgres-secrets`, or the database
  volume is older than your passwords (see next entry).
- `OOMKilled` in `kubectl describe pod`: give the cluster more memory.

## Den backend stays in Init: the migration step failed

**You see:** `den-backend-…` shows `Init:Error` or `Init:CrashLoopBackOff`.
The `migrate` initContainer applies Den's database changes before Den
starts.

```sh
kubectl logs -n conservices-den deploy/den-backend -c migrate
```

- `password authentication failed for user "den"`: PostgreSQL creates the
  `den` and `keycloak` logins only the **first** time its volume starts. If
  you changed passwords afterwards, the old ones are still in the database.
  On a trial cluster, start fresh (this **deletes all data**):

    ```sh
    kubectl delete -k deploy/kubernetes/overlays/example
    kubectl delete namespace conservices-data --ignore-not-found
    kubectl apply -k deploy/kubernetes/overlays/example
    ```

- `connection refused` or `timeout`: PostgreSQL is not ready yet (wait) or a
  NetworkPolicy blocks it (see [Timeouts between namespaces](#timeouts-between-namespaces)).
- `apply migrations: ...` with an SQL error: a migration failed. Do not
  retry blindly; keep the log and open an issue. On a production system
  [roll back](../operations/versioning.md#rolling-back) the image tag.

## The browser shows an empty page with 404

**You see:** a blank page, and the browser's developer tools show status
*404* for the address.

**Why:** the request reached the Gateway, but no HTTPRoute matches the
address. Check:

```sh
kubectl get httproute -A
```

You should see `keycloak` with `auth.conservices.test` and `den` with
`den.conservices.test`. If they are missing, the apply did not finish; run
it again. If they are there, check that the Gateway accepted them:

```sh
kubectl describe httproute -n conservices-den den
```

Under `Status → Parents` the conditions `Accepted` and `ResolvedRefs` must
be `True`. `NotAllowedByListeners` means the route's namespace lacks the
label `app.kubernetes.io/part-of=conservices`.

On Keycloak's address, only `/realms/`, `/resources/` and (local trial)
`/admin/` are routed; other paths give 404 on purpose.

*no healthy upstream* (503) instead means the route exists but no pod
behind it is ready yet.

## The browser cannot open the page at all

**You see:** *This site can't be reached* or `ERR_NAME_NOT_RESOLVED`.

**Fix:** the hosts entry from step 6 of the quickstart is missing. Check
with `ping den.conservices.test`; it should answer from `127.0.0.1`. Also
check nothing else uses ports 80 or 443 on your computer (IIS, Apache,
another proxy, or the Docker Compose stack's Caddy proxy), and that the
Gateway is programmed ([The Gateway is not programmed](#the-gateway-is-not-programmed)).

## Certificate warnings

**You see:** *Your connection isn't private* or
`NET::ERR_CERT_AUTHORITY_INVALID`.

**Fix:** run `mkcert -install` again, then fully quit and reopen the
browser. Firefox: on Windows set `security.enterprise_roots.enabled` to
`true` in `about:config`; on macOS and Linux install `nss` / `libnss3-tools`
before `mkcert -install`.

## Sign-in loops back to the Sign in page

**You see:** you enter your password, return to Den, and land on **Sign in**
again.

**Why:** Den's backend rejected the token. Look at its log while you sign
in; lines with `"status":401` confirm it:

```sh
kubectl logs -n conservices-den deploy/den-backend -f
```

Typical reasons:

1. **Issuer mismatch.** Keycloak's `KC_HOSTNAME` (in `keycloak-config`) must
   produce exactly the `OIDC_ISSUER_URL` Den is configured with:
   `https://auth.conservices.test/realms/conservices`. Check what Keycloak
   says:

    ```sh
    curl https://auth.conservices.test/realms/conservices/.well-known/openid-configuration
    ```

    The `"issuer"` value must match `OIDC_ISSUER_URL` character for
    character.

2. **Wrong clock** on your computer: set date and time automatically.
3. **Old sign-in data** in the browser: clear site data for
   `den.conservices.test` and `auth.conservices.test`, or use a private
   window.

## "Invalid parameter: redirect_uri"

**You see:** Keycloak shows *Invalid parameter: redirect_uri* instead of the
login form.

**Why:** the address you opened Den at is not in the `den-spa` client's
list of allowed redirect addresses. The test realm allows
`https://den.conservices.test/*` and `http://localhost:3001/*`.

**Fix:** open Den at exactly `https://den.conservices.test`. If you use
your own host name, add it to the client in the Keycloak admin console
(**Clients → den-spa → Valid redirect URIs** and **Web origins**). The
admin console is at <https://auth.conservices.test/admin/> (trial login
`admin` / `admin`).

## Signed in, but "Failed to load your services" or no Admin console

**Why:** Den gives access by Keycloak group. `den-member` may use the
portal; `den-admin` is an administrator. An account in neither group can
sign in but sees nothing.

**Fix:** sign in with `admin` / `adminadmin`, or add the user to a group in
the Keycloak admin console: **Users** → user → **Groups** → **Join group**.
See [Authentication](../concepts/authentication.md#from-groups-to-roles).

## Timeouts between namespaces

**You see:** a connection that *hangs* and then fails, for example
`dial tcp 10.96.12.34:5432: i/o timeout` in a module's log, or Stash saying
it cannot reach Den when you paste a pairing URL.

**Why:** a NetworkPolicy blocks the connection. Every namespace starts from
"deny everything" and only the flows listed in
[Network policies](../operations/network-policies.md#every-allowed-flow) are
allowed. A **refused** connection (`connection refused`) is a different
problem: nothing is listening.

**Fix:**

1. Check the module's namespace has the label `conservices.io/tier=module`:

    ```sh
    kubectl get namespace conservices-stash --show-labels
    ```

2. List the policies of the namespaces involved:

    ```sh
    kubectl get networkpolicy -n conservices-den
    kubectl describe networkpolicy -n conservices-den den-backend
    ```

3. Check pod labels match what the policies select
   (`kubectl get pods -n conservices-stash --show-labels`).
4. A new integration between modules needs its own allow rule; see
   [Calls between modules](../operations/network-policies.md#calls-between-modules).

## Den shows "Can't reach the operator"

**You see:** Admin console → Backups shows *Can't reach the operator* or
*can't reach the database server*.

**Fix:** check `den-operator` runs and its log
(`kubectl logs -n conservices-den deploy/den-operator`). Check that
`OPERATOR_TOKEN` is the same in `den-secrets` and `den-operator-secrets`
(a mismatch shows as `unauthorized`). *Can't reach the database server*
means the operator's `PG_ADMIN_URL` is wrong or PostgreSQL is not ready.

## A changed secret has no effect

**Why:** programs read their settings when they start. Kubernetes does not
restart pods when a Secret changes.

**Fix:** restart the pods that use it:

```sh
kubectl rollout restart -n conservices-den deploy/den-backend deploy/den-operator
```

See [Secrets](../operations/secrets.md#rotating-secrets).

## CreateContainerConfigError

**You see:** a pod with `CreateContainerConfigError`.

**Why:** a Secret, a ConfigMap or a key in one of them is missing.
`kubectl describe pod` says which, near the bottom:

```text
Warning  Failed  8s  kubelet  Error: secret "den-secrets" not found
```

**Fix:** with the example overlay, apply it again. With External Secrets,
check the `ExternalSecret` (next entry). With Helm, create the Secret named
in `existingSecret` and the access config ConfigMap before installing.

## ExternalSecret not synced

**You see:** `kubectl get externalsecret -A` shows `SecretSyncedError` or
`READY False`, and pods wait in `CreateContainerConfigError`.

**Fix:** read the reason and follow
[Secrets: Troubleshooting](../operations/secrets.md#troubleshooting):

```sh
kubectl describe externalsecret -n conservices-den den-secrets | tail -5
kubectl get secretstore -A
```

## Pods are refused: violates PodSecurity

**You see:** `kubectl apply` or a ReplicaSet's events say
`violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false …`.

**Why:** every Con Services namespace enforces the restricted Pod Security
Standard. Something you added (a sidecar, a debug pod, a patched
`securityContext`, a chart's `extraVolumes`) breaks it.

**Fix:** make the added container meet the rules listed in
[Pod Security](../operations/network-policies.md#pod-security). For
debugging, use `kubectl debug --profile=restricted`.

## 503 or "upstream connect error" from the Gateway

**You see:** the browser shows *upstream connect error or disconnect/reset
before headers*, *503*, or a gateway time-out for an address, although the
pods are `Running`.

**Why:** the Gateway cannot reach the web app pod or cannot complete TLS
with it. Usually one of:

- **Network policy.** Cilium's Gateway reaches the web apps with Cilium's
  reserved identity `ingress`, which only a `CiliumNetworkPolicy` with
  `fromEntities: [ingress]` admits. Check it exists:
  `kubectl get ciliumnetworkpolicy -A` should list
  `den-web-from-gateway`, `keycloak-from-gateway` and one per module.
- **TLS to the web app.** The `BackendTLSPolicy` must be accepted and point
  at the ConfigMap `conservices-internal-ca`; see
  [Internal TLS: Troubleshooting](../operations/internal-tls.md#troubleshooting).

**Fix:** apply the overlay again so the missing object is created, then
see [Network policies: Troubleshooting](../operations/network-policies.md#troubleshooting).
With another gateway or ingress controller (for example Traefik) instead
of Cilium, admit its namespace in the web apps' NetworkPolicies.

## Helm install or upgrade fails

See [Installing modules with Helm: Troubleshooting](../operations/helm.md#troubleshooting)
for missing tags, the single-replica guard, missing namespaces and stuck
releases.

## Backups fail

See [Databases, backups and restore: Troubleshooting](../operations/databases-and-backups.md#troubleshooting).

## Start again from scratch

On a trial cluster, when everything else fails:

```sh
kubectl delete -k deploy/kubernetes/overlays/example
kubectl delete namespace conservices-data conservices-den conservices-identity --ignore-not-found
kubectl apply -k deploy/kubernetes/overlays/example
```

This **deletes all data**. Still stuck? Open an issue in the
[con-services repository](https://github.com/AGlElectronics/con-services/issues)
with the output of `kubectl get pods -A -l app.kubernetes.io/part-of=conservices`
and the log of the failing pod.
