# Kubernetes reference manifests

Kustomize manifests for running Con Services on Kubernetes with published,
versioned images (`ghcr.io/aglelectronics/<module>-<component>:<MAJOR.MINOR.PATCH-BUILD>`).
The documentation walks through them step by step:
<https://aglelectronics.github.io/con-services/>

| Path | What it is |
| --- | --- |
| `base/` | The platform: namespaces, Keycloak (`conservices-identity`), PostgreSQL and MinIO (`conservices-data`), Den (`conservices-den`), Ingresses and NetworkPolicies. |
| `modules/stash/` | Stash in `conservices-stash`, the worked example of a module. |
| `modules/README.md` | How the other modules plug in (docs coming soon). |
| `overlays/example/` | Local-cluster overlay for the platform: pinned tags, dev-only plain Secrets (`secrets.yaml`), mkcert certificate. |
| `overlays/example-stash/` | Local-cluster overlay for Stash, applied after Den is up. |
| `overlays/production-external-secrets/` | Production-shaped overlay: secrets from a secret manager via the External Secrets Operator (`external-secrets.yaml` replaces `secrets.yaml`), own host names, own frontend build. |

Bring-up order (Den first):

```sh
kubectl apply -k deploy/kubernetes/overlays/example        # platform + Den
# Den: create the "stash" module and its database, paste the URL into the overlay
kubectl apply -k deploy/kubernetes/overlays/example-stash  # then each module
```

Rules for changing these files:

- Keep them in sync with the docs (`docs/operations/`, `docs/getting-started/`)
  and with the root `docker-compose.yml`. A change here without the matching
  docs change is incomplete.
- Never use `latest`. Pin `MAJOR.MINOR.PATCH-BUILD` tags; all images of one
  module share one tag.
- Never commit real secrets. Values in `overlays/example*` are public dev
  values for a local trial; everything else uses a secret manager
  (docs: operations/secrets).
