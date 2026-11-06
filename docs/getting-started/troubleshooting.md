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

**Fix:** start Docker Desktop and wait until it shows *Kubernetes running*.
Check that kubectl talks to the right cluster:

```sh
kubectl config current-context
```

It should say `docker-desktop` (or your kind/k3d cluster). Switch with
`kubectl config use-context docker-desktop`.

## ImagePullBackOff or ErrImagePull

**You see:** a pod with `ImagePullBackOff`; `kubectl describe pod` shows
`Failed to pull image "ghcr.io/aglelectronics/den-backend:1.0.0-1": ... not found`
or `unauthorized`.

**Why and fix:**

- **Typo or unknown tag.** Check the tag in the overlay's `images:` list
  against the published versions on the repository's *Packages* page. Tags
  look like `1.4.2-17`; there is no `latest`.
- **No internet or a proxy.** The node must reach `ghcr.io` and `quay.io`.
- **Rate limit** (`toomanyrequests`) for Docker Hub images (`postgres`):
  wait a few minutes; Kubernetes retries by itself.

## A pod is Pending

**You see:** `STATUS Pending` for minutes. `kubectl describe pod` shows
`pod has unbound immediate PersistentVolumeClaims` or `Insufficient memory`.

**Fix:**

- **Volume:** your cluster has no default *StorageClass* (the thing that
  creates disks). Check with `kubectl get storageclass`; Docker Desktop has
  `hostpath (default)`. On other clusters install one or set
  `storageClassName` in `base/data/`.
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
| `init oidc verifier: oidc discovery` | Den cannot reach `https://auth.conservices.test`. | Wait for Keycloak (see below). Then check the IP in `den-backend-local.yaml` (step 6 of the quickstart) and that `local/rootCA.pem` is mkcert's root certificate. |
| `x509: certificate signed by unknown authority` | Den does not trust the certificate. | Redo step 5 of the quickstart; make sure the `local-ca` secret is mounted (`SSL_CERT_DIR`). |
| `invalid config: ... is required` | A required setting is missing. | Compare with the [configuration reference](../modules/den/configuration.md). |
| `open db` / `password authentication failed` | Wrong database password, or the database volume was created with other passwords. | See [The migration step failed](#den-backend-stays-in-init-the-migration-step-failed). |
| `check bucket` / `create bucket` | Den cannot reach the S3 storage or the keys are wrong. | Check MinIO runs and the `S3_*` keys match `minio-secrets`. |

The operator logs `invalid operator config: ...` the same way; its
settings are in the [operations guide](../operations/databases-and-backups.md#configuration-reference).

## Keycloak is not ready

**You see:** `keycloak-…` stays `0/1 Running` for several minutes, or keeps
restarting.

**Fix:** Keycloak needs one to three minutes on first start. Watch it:

```sh
kubectl logs -n conservices-identity deploy/keycloak -f
```

It is ready when you see `Keycloak 26.0.7 on JVM (powered by Quarkus)
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

## The browser shows 404 Not Found (nginx)

**You see:** a plain *404 Not Found* page with *nginx* at the bottom.

**Why:** the request reached the ingress controller, but no Ingress matches
the address. Check:

```sh
kubectl get ingress -A
```

You should see `keycloak` with host `auth.conservices.test` and `den` with
`den.conservices.test`, both with class `nginx`. If they are missing, the
apply did not finish; run it again. If `ADDRESS` is empty, the ingress
controller is not running (`kubectl get pods -n ingress-nginx`).

A *503 Service Temporarily Unavailable* instead means the Ingress exists
but no pod behind it is ready yet.

## The browser cannot open the page at all

**You see:** *This site can't be reached* or `ERR_NAME_NOT_RESOLVED`.

**Fix:** the hosts entry from step 7 of the quickstart is missing. Check
with `ping den.conservices.test`; it should answer from `127.0.0.1`. Also
check nothing else uses ports 80 or 443 on your computer (IIS, Apache,
another proxy, or the Docker Compose stack's Caddy proxy).

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

## 502 Bad Gateway or 504 Gateway Time-out

**You see:** the ingress controller answers *502* or *504* for an address,
although the pods are `Running`.

**Why:** the ingress controller cannot reach the frontend pod, almost
always because of a NetworkPolicy: the policies admit the controller from
the namespace `ingress-nginx` only.

**Fix:** check where your controller runs (`kubectl get pods -A | grep -i ingress`).
If it is not `ingress-nginx`, change the namespace selector in the
policies (Helm charts: `networkPolicy.ingressControllerNamespace`); see
[Network policies: Troubleshooting](../operations/network-policies.md#troubleshooting).

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
