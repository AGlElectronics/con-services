# Getting started

**Goal:** pick the right way to run Con Services, then get Den running and
signed in, so you can look around and try things safely.

Con Services runs on **Kubernetes**, using published, versioned images.
Production installations are managed with **Argo CD**, a GitOps tool: the
cluster's whole configuration lives in a Git repository, and Argo CD keeps
the cluster in line with it. This section is about **trying** the platform
first: it gets the platform and Den running on a small Kubernetes cluster
on your own computer. If you want to know *why* it is built this way first,
the [Design principles](../concepts/design-principles.md) take five minutes.

## Choose your path

There are five ways to run Con Services. Pick the one that matches what you
want to do:

| You want to… | Path | Start here |
| --- | --- | --- |
| Run the **whole suite in production** (Den plus modules) | **(a) Production cluster with Argo CD** (recommended) | [Deploy with Argo CD](../deploy/index.md) |
| **Try the whole suite** on your own computer before you install it for real | **(b) Full platform on Kubernetes (local trial)** | [How the platform starts](how-the-platform-starts.md), then [Run Den on Kubernetes](den-quickstart.md) |
| Run **one module** (for example Stash) without Den | **(c) Standalone module on Kubernetes** | [Run one module on Kubernetes](standalone-kubernetes.md) |
| Run the suite on **one server without Kubernetes** | **(d) Full stack on Docker** | [Full stack on Docker](../operations/docker-production.md) |
| **Work on the code** | **(e) Docker Compose for development** | [Local development](../contributing/local-development.md) |

Paths (a) to (d) use the same published, versioned images; (e) builds
from source with public test passwords and is never for real data. The
local trial (b) uses public test passwords and in-cluster storage too: it
is for trying things out, never for real data. Whatever you choose, keep
secrets in a secret manager outside a local trial
([Secrets](../operations/secrets.md)).

Still unsure? Answer these in order:

1. **Do you want to change the code?** Yes → (e).
2. **Do you only want to look around first?** Yes → (b), on your own
   computer.
3. **Do you need more than one module, a shared portal, or one sign-in
   for everything?** No → (c), one module on its own. You can add Den later
   without reinstalling.
4. **Do you have, or can you get, a few servers for a Kubernetes cluster**
   (three small machines or virtual servers are enough)? Yes → (a). No,
   and it is one small event on one server → (d).

| | (a) Argo CD | (b) Local trial | (c) Standalone module | (d) Docker | (e) Development |
| --- | --- | --- | --- | --- | --- |
| Den portal, branding, pairing | Yes | Yes | No (add later) | Yes | Yes |
| Automatic nightly backups | Yes (Den's operator) | Yes, into local storage | **No, your job** | Yes | No |
| Network isolation between parts | NetworkPolicies (Cilium) | NetworkPolicies (Cilium) | NetworkPolicies | Docker networks only | None |
| Survives a server failure | Yes, with three or more nodes | No | Yes, with several nodes | No | No |
| For real data | Yes | **No** | Yes | Yes | **No** |
| Effort to run | Medium | Low | Low | Low | Not for running |

The rest of this page is about the local trial, path (b). For path (a),
continue with [Deploy with Argo CD](../deploy/index.md).

## Read this first

[How the platform starts](how-the-platform-starts.md) explains the order in
which everything comes up: **Den first**, then the modules one by one, each
in its own namespace. It is short and makes every later step make sense.

## Then try it

[Run Den on Kubernetes](den-quickstart.md) takes you from an empty computer
to a working Den you can sign in to:

- **Den**, the Con Services portal, at <https://den.conservices.test>;
- **Keycloak**, the sign-in server, at <https://auth.conservices.test>, with
  a ready-made test account;
- **PostgreSQL** and an S3-compatible file storage (**SeaweedFS**) inside the cluster, for local use
  only;
- **Cilium**, the network plugin, which also runs the **Gateway**: the
  entry point that sends each web address to the right app (the
  [Gateway API](../concepts/glossary.md#gateway-api), the same way in as
  in production).

!!! warning "This setup is for trying things out"
    The trial uses publicly known passwords, a test realm, plain
    Kubernetes Secrets and file storage inside the cluster. Never expose it
    to the internet or use it for real data. For a real installation follow
    [Deploy with Argo CD](../deploy/index.md).

## What you need

- Windows 10/11, macOS or Linux with at least 8 GB of memory (16 GB is more
  comfortable) and about 15 GB of free disk space.
- Docker Desktop (or Docker Engine on Linux) and
  [kind](https://kind.sigs.k8s.io/), which runs a Kubernetes cluster
  inside Docker. The quickstart installs both.
- An internet connection to download the images.
- Administrator rights once, to add the local web addresses to your hosts
  file and to trust a local certificate.

## After the trial

When the trial works and you want to run it for real, do not grow the
trial into production. Set up a production cluster instead:

1. Follow [Deploy with Argo CD](../deploy/index.md): cluster, secrets,
   databases, sign-in and the apps, all from a Git repository.
2. Use a managed S3 service for file storage and backups. Any
   S3-compatible service works, for example AWS S3, Hetzner Object Storage,
   Cloudflare R2 or Backblaze B2.
3. Read [Production and security](../operations/production.md) and follow
   its go-live procedure.
4. Set up and test backups ([Databases, backups and restore](../operations/databases-and-backups.md)).

## Troubleshooting

If something goes wrong, [Troubleshooting](troubleshooting.md) lists the
usual problems and how to diagnose them. The first command to run is
always:

```sh
kubectl get pods -A -l app.kubernetes.io/part-of=conservices
```

Any pod that is not `Running` with all containers ready (`1/1`) has an
entry there.

!!! note "Contributors"
    Working on the code itself? The Docker Compose stack, which builds
    everything from source, is described in
    [Local development](../contributing/local-development.md).
