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

    On Kubernetes every module **waits for Den by default**
    (`DEN_MODE=required`): until it is paired, its API answers
    `503 den_pairing_required` and the web app shows *Waiting for Den*.
    A standalone module must therefore switch this off with
    `DEN_MODE=standalone` (Helm: `den.mode: standalone`), as shown in step 4.
    See [Required or standalone](../concepts/pairing.md#required-or-standalone).

## What a module needs

Even on its own, a module depends on three services. You provide them:

| Needs | Example | Notes |
| --- | --- | --- |
| A **PostgreSQL** database and login for the module alone | A managed PostgreSQL 16 database, or a [CloudNativePG](https://cloudnative-pg.io) cluster | Without Den, nobody creates it for you: create the database and a login that owns it. |
| An **S3-compatible bucket** and keys for it | A managed S3 service: any S3-compatible one works, for example AWS S3, Hetzner Object Storage, Cloudflare R2 or Backblaze B2 | Stash creates its bucket on first start if the keys allow it. Do not run object storage inside the cluster for real data. |
| An **OpenID Connect** sign-in server | Keycloak, or your existing identity provider | A public client for the module's web app (Stash: `stash-spa`) with your module address as redirect URI, and groups matching the module's access config. |

You also need a way in for browsers: a **Gateway** (Gateway API) with a TLS
certificate for the module's address. We use Cilium's Gateway API; the
chart attaches an `HTTPRoute` to the Gateway you name. If your cluster only
has an ingress controller (for example Traefik), the chart can render a
plain `Ingress` instead; see
[Installing modules with Helm](../operations/helm.md#exposing-the-web-app-gateway-api).

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

    The chart in `deploy/charts/stash` (released with Stash, for example
    the tag `stash/v1.0.0`) never
    creates Secrets or the namespace; it uses what you made in steps 1–3.
    Write your settings into a values file (`route.parentRefs` names your
    Gateway and its HTTPS listener):

    ```yaml
    # my-stash.yaml
    image:
      backend:  { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
    den:
      mode: standalone              # no Den: do not wait for pairing
    config:
      APP_BASE_URL: https://stash.example.org
      OIDC_ISSUER_URL: https://login.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://stash.example.org
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-stash
      S3_REGION: fsn1
      DEN_INTERNAL_URL: ""          # no Den
    route:
      host: stash.example.org
      parentRefs:
        - { name: public, namespace: conservices-gateway, sectionName: https }
    networkPolicy:
      den:  { enabled: false }      # no Den
      data: { enabled: false }      # no in-cluster PostgreSQL/S3
      oidc: { inCluster: false }    # identity provider outside the cluster
      allowFromNamespaces: []
      extraEgress:
        - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your database subnet
          ports: [{ protocol: TCP, port: 5432 }]
        - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]      # managed S3 and the identity provider over HTTPS
          ports: [{ protocol: TCP, port: 443 }]
    ```

    The chart also renders a `CiliumNetworkPolicy` that lets Cilium's
    Gateway reach the web app. On another network plugin set
    `networkPolicy.gateway.cilium: false`.

    ```sh
    helm install stash deploy/charts/stash -n conservices-stash -f my-stash.yaml
    ```

=== "Kustomize"

    Make an overlay on top of `deploy/kubernetes/modules/stash`, like
    `deploy/kubernetes/overlays/example-stash`, and change the `stash-config`
    values with `behavior: merge` (same keys as in the Helm example), and
    patch the `HTTPRoute` `stash` with your host name. Remove the
    `stash-backend` egress rules to `conservices-den`, `conservices-data`
    and `conservices-identity` and add rules for your database, S3 and
    identity provider instead (see
    [Network policies](../operations/network-policies.md#external-services)).

    The base sets `DEN_MODE=required`, so set it to `standalone` in the
    same merge, with a comment why:

    ```yaml
    # deploy/kubernetes/overlays/my-stash/kustomization.yaml (excerpt)
    configMapGenerator:
      - name: stash-config
        namespace: conservices-stash
        behavior: merge
        literals:
          # No Den in this cluster: do not wait for pairing.
          - DEN_MODE=standalone
          - DEN_INTERNAL_URL=
          - APP_BASE_URL=https://stash.example.org
          - OIDC_ISSUER_URL=https://login.example.org/realms/conservices
          - CORS_ALLOWED_ORIGINS=https://stash.example.org
    ```

    ```sh
    kubectl apply -k deploy/kubernetes/overlays/my-stash
    ```

!!! note "The web app's sign-in address comes from `/config.json`"
    The published `stash-frontend` image names no domain. Its sign-in
    address and client id come from the ConfigMap `stash-frontend-config`
    (file `deploy/kubernetes/modules/stash/frontend-config.json`), which
    nginx serves as `/config.json`. For your own identity provider, replace
    it in your overlay:

    ```yaml
    configMapGenerator:
      - name: stash-frontend-config
        namespace: conservices-stash
        behavior: replace
        files:
          - config.json=stash-frontend-config.json
    ```

    with `stash-frontend-config.json` next to the overlay's
    `kustomization.yaml`:

    ```json
    {
      "authMode": "oidc",
      "oidcAuthority": "https://auth.example.org/realms/conservices",
      "oidcClientId": "stash-spa"
    }
    ```

    The keys are listed under
    [Web app settings](../modules/stash/configuration.md#web-app-settings-configjson).

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
replica**. Check that it does not wait for Den:

```sh
curl -s https://stash.example.org/api/den/state
```

```json
{"mode":"standalone","paired":false}
```

Then open your module address and sign in with an account in one
of the groups from the access config.

## Adding Den later

When you later deploy the platform ([How the platform starts](how-the-platform-starts.md)):

1. Set `DEN_INTERNAL_URL=https://den-backend.conservices-den.svc.cluster.local:8080`
   and turn the Den network policy rules back on.
2. In Den, add the module with **New module** (without *Create a database*,
   because the database already exists).
3. Pair it: Den → **Modules** → **Pair**, then Stash → **Settings → Den
   connection**.
4. Optional: switch back to the reference setup with `den.mode: required`
   (Kustomize: drop the `DEN_MODE=standalone` line), so the module would
   wait for Den again if it is ever unpaired.

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

**The web app shows *Waiting for Den* and the API answers `503 den_pairing_required`**
: The module still runs with `DEN_MODE=required`, the Kubernetes default.
  Set `den.mode: standalone` (Kustomize: `DEN_MODE=standalone` in
  `stash-config`) and run `helm upgrade` (or `kubectl apply -k`; the
  ConfigMap's new name restarts the backend).

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
: The ConfigMap `stash-frontend-config` still holds the example address.
  Replace it in your overlay (see the note in step 4) and check with
  `curl -s https://stash.example.org/config.json`.

**Signed in, but no access**
: Your account is not in a group named in the access config. Check the
  groups in your token at your identity provider and the `group` entries in
  `access-config.toml`.

## Related pages

- [Installing modules with Helm](../operations/helm.md)
- [Secrets](../operations/secrets.md#add-a-modules-secrets)
- [Network policies: External services](../operations/network-policies.md#external-services)
- [Databases, backups and restore: Standalone modules](../operations/databases-and-backups.md#standalone-modules)
