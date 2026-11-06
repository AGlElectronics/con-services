# Operations

This section is for whoever runs a Con Services installation: installing,
upgrading, isolating the parts from each other, keeping secrets safe,
backing up, monitoring and recovering.

Start with [How the platform starts](../getting-started/how-the-platform-starts.md):
Den comes first, then each module.

## I want to…

| Task | Page |
| --- | --- |
| Choose between Kubernetes, standalone and Docker | [Getting started: Choose your path](../getting-started/index.md#choose-your-path) |
| Set up my own installation from the manifests | [Running on Kubernetes](running.md#set-up-your-own-installation) |
| Add a module | [Running on Kubernetes: Add a module](running.md#add-a-module), [Installing modules with Helm](helm.md) |
| Pin, upgrade or roll back images | [Versions and upgrades](versioning.md) |
| Install Cilium and check that NetworkPolicies are enforced | [Network policies and isolation](network-policies.md#installing-cilium) |
| Keep secrets in Vault / a cloud secret manager and rotate them | [Secrets](secrets.md) |
| Set up backups and restore a database | [Databases, backups and restore](databases-and-backups.md) |
| Recover from a lost server, cluster or key | [Disaster recovery](disaster-recovery.md) |
| Read logs, check health, set up alerts | [Logs, health and monitoring](observability.md) |
| Prepare for real users (load balancer, managed S3, hardening) | [Production and security](production.md) |
| Run on one server without Kubernetes | [Full stack on Docker](docker-production.md) |
| Fix a problem | [Troubleshooting](../getting-started/troubleshooting.md), and the Troubleshooting section at the end of every page here |

## The pages

- [Running on Kubernetes](running.md): the manifests and overlays, setting
  up your own installation, adding a module, what runs in which namespace,
  replicas and scaling, resources, migrations.
- [Installing modules with Helm](helm.md): the module charts, install,
  upgrade, rollback, GitOps.
- [Versions and upgrades](versioning.md): how images are tagged, how to
  find and pin tags, how to upgrade and roll back.
- [Network policies and isolation](network-policies.md): the namespace
  layout, every allowed connection, Cilium, Pod Security and service
  accounts.
- [Secrets](secrets.md): every secret the platform uses, the External
  Secrets Operator, and rotation.
- [Databases, backups and restore](databases-and-backups.md): how modules
  share a PostgreSQL server, how Den creates and removes module databases,
  what the nightly backups contain and how to restore them.
- [Disaster recovery](disaster-recovery.md): procedures for every kind of
  loss, and how to rehearse them.
- [Logs, health and monitoring](observability.md): health endpoints, log
  format, what to scrape and which alerts to set.
- [Production and security](production.md): the production shape (load
  balancer, Cilium, managed S3), the go-live procedure and a checklist.
- [Full stack on Docker](docker-production.md): a hardened single-server
  setup for organisations without Kubernetes.

!!! warning "The example overlay is for trying things out"
    `deploy/kubernetes/overlays/example` contains public test passwords, a
    Keycloak in development mode, in-cluster MinIO and a test realm with
    known accounts. Real installations use the same base and images, with
    their own overlay, secrets, identity provider and storage. See
    [Production and security](production.md).

## What is not automated yet

Be aware of these gaps when you plan an installation; each page says how
to work around them.

- **Den does not configure storage or the database server from its admin
  console yet.** Both are set in the manifests; Den shows them on the
  Backups page and creates module *databases*, but not buckets or storage
  keys.
- **Kustomize manifests exist for the platform and Stash only.** The other
  modules have Helm charts (first version, untested on a cluster).
- **No Helm chart for the platform or Den.** Use Kustomize for those.
- **No Prometheus metrics** from Con Services programs; monitor through
  Kubernetes, the ingress controller and the health endpoints.
- **Backends run as a single replica** each; only the frontends scale.

## Troubleshooting

Not sure where to start? Run the overview and follow the state of the
failing pod to the matching entry in
[Troubleshooting](../getting-started/troubleshooting.md):

```sh
kubectl get pods -A -l app.kubernetes.io/part-of=conservices
```
