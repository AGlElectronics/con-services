# Kubernetes reference manifests

Kustomize manifests for trying Con Services on a local Kubernetes cluster
with published, versioned images
(`ghcr.io/aglelectronics/<module>-<component>:<MAJOR.MINOR.PATCH-BUILD>`).
Production clusters use the Argo CD path (the `con-services-gitops`
repository and the Helm charts in `deploy/charts/`). The documentation walks
through both: <https://aglelectronics.github.io/con-services/>

| Path | What it is |
| --- | --- |
| `base/` | The platform: namespaces, Keycloak (`conservices-identity`), PostgreSQL and an S3 server (SeaweedFS) (`conservices-data`, local trial only), Den (`conservices-den`), Gateway API `HTTPRoute`s with `BackendTLSPolicy`s, and NetworkPolicies (plus Cilium policies for the gateway). |
| `modules/stash/` | Stash in `conservices-stash`, the worked example of a module. |
| `modules/README.md` | How the other modules plug in. Helm setup: [HR](../../docs/modules/hr/setup.md), [Rally](../../docs/modules/rally/setup.md), [Finance](../../docs/modules/finance/setup.md), [Learn](../../docs/modules/learn/setup.md), [Wiki](../../docs/modules/wiki/setup.md), [Desk](../../docs/modules/desk/setup.md), [Tasks](../../docs/modules/tasks/setup.md). Stash also has Kustomize in `modules/stash/` ([standalone Kubernetes](../../docs/getting-started/standalone-kubernetes.md)). |
| `overlays/example/` | Local-cluster overlay for the platform: the Cilium `Gateway` `public` in `conservices-gateway`, pinned tags, dev-only plain Secrets (`secrets.yaml`), mkcert certificate. |
| `overlays/example-stash/` | Local-cluster overlay for Stash, applied after Den is up. |
| `overlays/production-external-secrets/` | Production-shaped overlay: secrets from a secret manager via the External Secrets Operator (`external-secrets.yaml` replaces `secrets.yaml`), own host names, including the web app's sign-in address (`den-frontend-config.json`, served as `/config.json`). Expects your cluster's Gateway. |
| `local-cluster/` | The kind cluster and Cilium settings the local quickstart uses. |

Every `HTTPRoute` attaches to the Gateway `public` in the namespace
`conservices-gateway`, listener `https`. The example overlay creates that
Gateway; in production it comes from your cluster setup.

Bring-up order (Den first):

```sh
kubectl apply -k deploy/kubernetes/overlays/example        # platform + Den
# Den: create the "stash" module and its database, paste the URL into the overlay
kubectl apply -k deploy/kubernetes/overlays/example-stash  # then each module
```

Rules for changing these files:

- Keep them in sync with the docs (`docs/operations/`, `docs/getting-started/`),
  the Helm charts (`deploy/charts/`) and the root `docker-compose.yml`. A
  change here without the matching docs change is incomplete.
- Never use `latest`. Pin `MAJOR.MINOR.PATCH-BUILD` tags; all images of one
  module share one tag.
- Never commit real secrets. Values in `overlays/example*` are public dev
  values for a local trial; everything else uses a secret manager
  (docs: operations/secrets).
