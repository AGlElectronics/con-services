# Getting started

**Goal:** pick the right way to run Con Services, then get Den running and
signed in, so you can look around and try things safely.

Con Services runs on **Kubernetes**, using published, versioned images. This
section gets the platform and Den running on a small Kubernetes cluster on
your own computer. If you want to know *why* it is built this way first,
the [Design principles](../concepts/design-principles.md) take five minutes.

## Choose your path

There are four ways to run Con Services. Pick the one that matches what you
want to do:

| You want to… | Path | Start here |
| --- | --- | --- |
| Run the **whole suite** (Den plus modules) for real, or try it the way it is meant to run | **(a) Full platform on Kubernetes** (recommended) | [How the platform starts](how-the-platform-starts.md), then [Run Den on Kubernetes](den-quickstart.md) to try it locally |
| Run **one module** (for example Stash) without Den | **(b) Standalone module on Kubernetes** | [Run one module on Kubernetes](standalone-kubernetes.md) |
| Run the suite in production on **one server without Kubernetes** | **(c) Full stack on Docker (production)** | [Full stack on Docker](../operations/docker-production.md) |
| **Work on the code** | **(d) Docker Compose for development** | [Local development](../contributing/local-development.md) |

Paths (a), (b) and (c) use the same published, versioned images; (d) builds
from source with public test passwords and is never for real data. Whatever
you choose, keep secrets in a secret manager outside a local trial
([Secrets](../operations/secrets.md)).

Still unsure? Answer these in order:

1. **Do you want to change the code?** Yes → (d).
2. **Do you need more than one module, a shared portal, or one sign-in
   for everything?** No → (b), one module on its own. You can add Den later
   without reinstalling.
3. **Do you have, or can you get, a Kubernetes cluster** (a managed one
   from your cloud provider is enough)? Yes → (a). No, and it is one small
   event on one server → (c).

| | (a) Full platform | (b) Standalone module | (c) Docker | (d) Development |
| --- | --- | --- | --- | --- |
| Den portal, branding, pairing | Yes | No (add later) | Yes | Yes |
| Automatic nightly backups | Yes (Den's operator) | **No, your job** | Yes | No |
| Network isolation between parts | NetworkPolicies | NetworkPolicies | Docker networks only | None |
| Survives a server failure | Yes, with several nodes | Yes, with several nodes | No | No |
| Effort to run | Medium | Low | Low | Not for running |

The rest of this page is about path (a).

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
- **PostgreSQL** and **MinIO** file storage inside the cluster, for local use
  only.

!!! warning "This setup is for trying things out"
    The trial uses publicly known passwords, a test realm and plain
    Kubernetes Secrets. Never expose it to the internet or use it for real
    data. For a real installation read
    [Running on Kubernetes](../operations/running.md),
    [Secrets](../operations/secrets.md) and
    [Production and security](../operations/production.md).

## What you need

- Windows 10/11, macOS or Linux with at least 8 GB of memory (16 GB is more
  comfortable) and about 15 GB of free disk space.
- Docker Desktop with its built-in Kubernetes (or kind, or k3d).
- An internet connection to download the images.
- Administrator rights once, to add the local web addresses to your hosts
  file and to trust a local certificate.

## After the trial

When the trial works and you want to run it for real:

1. Read [Production and security](../operations/production.md) and follow
   its go-live procedure.
2. Set up your own overlay ([Running on Kubernetes](../operations/running.md#set-up-your-own-installation)).
3. Move secrets to a secret manager ([Secrets](../operations/secrets.md)).
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
