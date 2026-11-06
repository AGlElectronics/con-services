# Run one module on Kubernetes (standalone)

Every Con Services module can run **on its own**, without Den and the rest
of the suite. This page installs a single module, using **Stash** (the
inventory module) as the example, into an existing Kubernetes cluster. Use
it when you only need one tool, or want to try a module before planning the
full platform.

!!! info "What "standalone" means"
    A standalone module has its own settings page and its default look. It
    does not show your organisation's brand and does not appear on a portal,
    because there is no Den to pair with. You can add Den later and
    [pair](../concepts/pairing.md) the module then; nothing has to be
    reinstalled.

## What a module needs

Even on its own, a module depends on three services. You provide them:

| Needs | Example | Notes |
| --- | --- | --- |
| A **PostgreSQL** database and login for the module alone | A managed PostgreSQL 16 database, or a [CloudNativePG](https://cloudnative-pg.io) cluster | Without Den, nobody creates it for you: create the database and a login that owns it. |
| An **S3-compatible bucket** and keys for it | AWS S3 or Hetzner Object Storage | Stash creates its bucket on first start if the keys allow it. |
| An **OpenID Connect** sign-in server | Keycloak, or your existing identity provider | A public client for the module's web app (Stash: `stash-spa`) with your module address as redirect URI, and groups matching the module's access config. |

You also need an ingress controller and a TLS certificate for the module's
address, as for any web app on Kubernetes.

!!! warning "Backups are your job"
    Den's operator backs up the whole suite. **A standalone module is not
    covered by it.** Back up its database (`pg_dump` or your provider's
    backups) and its bucket yourself; see
    [Standalone modules](../operations/databases-and-backups.md#standalone-modules).

## Step 1: Create the namespace

The module runs in its own namespace with the labels the Con Services
network policies and Pod Security expect:

```sh
kubectl create namespace conservices-stash
kubectl label namespace conservices-stash \
  conservices.io/tier=module conservices.io/module=stash \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
```

## Step 2: Create the secret

Stash reads `DATABASE_URL`, `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY`
from a Secret named `stash-secrets`. In a real installation let your secret
manager create it with an `ExternalSecret` (see [Secrets](../operations/secrets.md)).
To try things out, you can create it by hand:

```sh
kubectl create secret generic stash-secrets -n conservices-stash \
  --from-literal=DATABASE_URL='postgres://stash:change-me@db.example.org:5432/stash?sslmode=require' \
  --from-literal=S3_ACCESS_KEY_ID=change-me \
  --from-literal=S3_SECRET_ACCESS_KEY=change-me
```

## Step 3: Create the access config

Stash maps sign-in groups to its roles with an access config file. Start from
`stash/infra/access-config.toml` in the Stash repository, adjust the
`group` names to your identity provider's groups, then:

```sh
kubectl create configmap stash-access-config -n conservices-stash \
  --from-file=access-config.toml=access-config.toml
```

## Step 4: Install the module

There are two ways; both use the same published images
(`ghcr.io/aglelectronics/stash-backend` and `stash-frontend`, pinned to an
exact `MAJOR.MINOR.PATCH-BUILD` tag, see [Versions and upgrades](../operations/versioning.md)).

=== "Helm chart"

    The chart in `deploy/charts/stash` (a first version, `0.1.0`) never
    creates Secrets or the namespace; it uses what you made in steps 1–3.
    Write your settings into a values file:

    ```yaml
    # my-stash.yaml
    image:
      backend:  { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
    config:
      APP_BASE_URL: https://stash.example.org
      OIDC_ISSUER_URL: https://login.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://stash.example.org
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-stash
      S3_REGION: fsn1
      DEN_INTERNAL_URL: ""          # no Den
    ingress:
      host: stash.example.org
      tlsSecretName: stash-tls
    networkPolicy:
      den:  { enabled: false }      # no Den
      data: { enabled: false }      # no in-cluster PostgreSQL/MinIO
      allowFromNamespaces: []
      extraEgress:
        - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your database subnet
          ports: [{ protocol: TCP, port: 5432 }]
        - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]      # managed S3 over HTTPS
          ports: [{ protocol: TCP, port: 443 }]
    ```

    ```sh
    helm install stash deploy/charts/stash -n conservices-stash -f my-stash.yaml
    ```

=== "Kustomize"

    Make an overlay on top of `deploy/kubernetes/modules/stash`, like
    `deploy/kubernetes/overlays/example-stash`, and change the `stash-config`
    values with `behavior: merge` (same keys as in the Helm example). Remove
    the `stash-backend` egress rules to `conservices-den` and
    `conservices-data` and add rules for your database and S3 instead (see
    [Network policies](../operations/network-policies.md#external-services)).

    ```sh
    kubectl apply -k deploy/kubernetes/overlays/my-stash
    ```

!!! note "The web app's sign-in address is built into the image"
    Like Den's, Stash's frontend image reads `VITE_OIDC_AUTHORITY` and
    `VITE_OIDC_CLIENT_ID` at **build** time. The published image is built
    for the example installation (`https://auth.conservices.test`). For your
    own identity provider, build `stash-frontend` with your values and point
    the image at your registry.

## Step 5: Check that it runs

```sh
kubectl get pods -n conservices-stash -w
```

```text
NAME                              READY   STATUS    RESTARTS   AGE
stash-backend-5f7d9c6b8-kq2xd     1/1     Running   0          40s
stash-frontend-6c8b5d9f7-7wqzm    1/1     Running   0          40s
stash-frontend-6c8b5d9f7-p4ncs    1/1     Running   0          40s
```

Stash migrates its database when it starts, so keep the backend at **one
replica**. Then open your module address and sign in with an account in one
of the groups from the access config.

## Adding Den later

When you later deploy the platform ([How the platform starts](how-the-platform-starts.md)):

1. Set `DEN_INTERNAL_URL=http://den-backend.conservices-den.svc.cluster.local:8080`
   and turn the Den network policy rules back on.
2. In Den, add the module with **New module** (without *Create a database*,
   because the database already exists).
3. Pair it: Den → **Modules** → **Pair**, then Stash → **Settings → Den
   connection**.

## Other modules

The same steps work for every module; only the secret keys, the access
config file and the chart change. Each module's **Setup** page under
[Modules](../modules/index.md) lists them, and
[Installing modules with Helm](../operations/helm.md) covers the charts.
Modules other than Stash run a separate `migrate` image as an
initContainer, so set its tag too.

## Troubleshooting

Look at the pods and the backend's last log lines first:

```sh
kubectl get pods -n conservices-stash
kubectl logs -n conservices-stash deploy/stash-backend --tail 30
```

**The backend restarts with an OIDC error** (`oidc discovery`, `x509`, `no such host`)
: It cannot reach or does not trust your issuer. Check `OIDC_ISSUER_URL`,
  the egress rule on port 443 to the identity provider, and that the
  issuer's certificate is publicly trusted (otherwise mount your CA and set
  `SSL_CERT_DIR` with `backend.extraEnv`).

**Connections time out** (`i/o timeout`)
: A network policy blocks them. With `networkPolicy.data.enabled: false`,
  your `extraEgress` rules must cover the database and S3; see
  [Timeouts between namespaces](troubleshooting.md#timeouts-between-namespaces).

**`CreateContainerConfigError`**
: `stash-secrets` or `stash-access-config` is missing in the namespace:
  `kubectl describe pod -n conservices-stash -l app.kubernetes.io/component=backend`
  names it.

**`password authentication failed for user "stash"`**
: The password in `DATABASE_URL` does not match the login, or contains
  characters that must be URL-encoded (`@`, `/`, `:`). Use a hex password.

**`create bucket: AccessDenied`**
: The keys may not create buckets. Create the bucket yourself at your
  provider and set `S3_BUCKET` to its name.

**The web app redirects to `auth.conservices.test`**
: You are using the published frontend image, built for the example
  installation. Build `stash-frontend` with your own `VITE_OIDC_AUTHORITY`
  (see the note in step 4).

**Signed in, but no access**
: Your account is not in a group named in the access config. Check the
  groups in your token at your identity provider and the `group` entries in
  `access-config.toml`.

## Related pages

- [Installing modules with Helm](../operations/helm.md)
- [Secrets](../operations/secrets.md#add-a-modules-secrets)
- [Network policies: External services](../operations/network-policies.md#external-services)
- [Databases, backups and restore: Standalone modules](../operations/databases-and-backups.md#standalone-modules)
