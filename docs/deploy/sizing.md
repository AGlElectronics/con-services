# Sizing and resources

Every container the template deploys has CPU and memory **requests** and
**limits**. This page lists them all, adds them up, and shows how to change
them for a smaller or larger installation. The numbers come from rendering
the template with its defaults; the template's CI fails if any container
lacks a request or limit.

## Terms used on this page

**Request**
:   What Kubernetes reserves for a container when it places the pod. A pod
    only starts on a node with that much unreserved CPU and memory.

**Limit**
:   The most a container may use. Above its CPU limit it is slowed down;
    above its memory limit it is killed (`OOMKilled`) and restarted.

**CPU units**
:   `1` is one core; `250m` ("millicores") is a quarter of a core.

**Memory units**
:   `Mi` and `Gi` are mebibytes and gibibytes (1 Gi = 1024 Mi).

## Totals

With all 8 modules on:

| | Requests | Limits | Requests with the [small profile](#small-profile) |
| --- | --- | --- | --- |
| CPU | **2.2 cores** | 21.6 cores | 1.4 cores |
| Memory | **6.6 GiB** | 13.4 GiB | 3.3 GiB |
| Volumes | 91 GiB (7 volumes) | | 31 GiB (3 volumes) |

Requests are what the cluster must have free. Limits are a ceiling per
container that is never reached by all containers at once, so their sum can
be far above the cluster's size. Not included: Kubernetes itself, Cilium,
Longhorn, CoreDNS and the platform services (Argo CD, cert-manager,
trust-manager, External Secrets Operator, OpenBao, CloudNativePG; see
[Prerequisites](prerequisites.md) and
[Platform services](#platform-services) below), and short-lived jobs and
init containers.

Recommended for the defaults: **3 nodes with 4 cores and 16 GiB each**
([Prerequisites](prerequisites.md#1-kubernetes-and-nodes)). For 1 or 2
nodes, use the [small profile](#small-profile).

## Every component

"Replicas" is the number of pods; requests and limits are per container.
The `cluster.yaml` column names the key that changes it.

### Data and identity

| Component | Container | Replicas | Requests | Limits | `cluster.yaml` |
| --- | --- | --- | --- | --- | --- |
| PostgreSQL | postgres | 3 (small profile: 1) | 250m, 1Gi | 2, 1Gi | `postgres.resources` |
| | backup sidecar | one per instance | 50m, 128Mi | 500m, 512Mi | `postgres.backup.sidecarResources` |
| Keycloak operator | keycloak-operator | 1 | 100m, 256Mi | 500m, 512Mi | `keycloakOperator.resources` |
| Keycloak | keycloak | 2 (small profile: 1) | 250m, 1Gi | 2, 2Gi | `keycloak.resources` |

PostgreSQL's memory request equals its limit on purpose: PostgreSQL sizes
its caches from the memory it is given, and a pod that may be squeezed
below its limit risks being killed under memory pressure.

### Den and the modules

| App | Container | Replicas | Requests | Limits |
| --- | --- | --- | --- | --- |
| Den | backend | 1 | 50m, 64Mi | 500m, 256Mi |
| | operator | 1 | 50m, 64Mi | 1, 512Mi |
| | frontend | 2 | 10m, 16Mi | 200m, 64Mi |
| Stash, HR, Finance, Learn, Desk, Tasks | backend | 1 | 50m, 64Mi | 500m, 256Mi |
| | frontend | 2 | 10m, 16Mi | 200m, 64Mi |
| Wiki | backend | 1 | 50m, 64Mi | 500m, 512Mi |
| | frontend | 2 | 10m, 16Mi | 200m, 64Mi |
| Rally | backend | 1 | 100m, 128Mi | 1, 512Mi |
| | web | 2 | 10m, 16Mi | 200m, 64Mi |

These defaults come from each chart in the main repository. Change them
with `den.values` or `modules.<name>.values`, using the chart's keys
(`backend.resources`, `frontend.resources`, `frontend.replicas`, and for
Den also `operator.resources`). Why backends run one replica is explained
in [High availability](high-availability.md#why-some-backends-run-one-replica).

### Volumes

| Volume | Count | Size | `cluster.yaml` |
| --- | --- | --- | --- |
| PostgreSQL data | one per instance (3, small profile: 1) | 20Gi | `postgres.storage.size` |
| PostgreSQL WAL | one per instance (3, small profile: 1) | 10Gi | `postgres.storage.walSize` |
| Wiki editing buffers | 1 | 1Gi | `modules.wiki.values` (chart key `backend.buffer.persistence.size`) |

Volumes can grow later (Longhorn and most cloud classes allow it) but
never shrink. Files and backups are in S3, not on these volumes.

### Platform services

The platform services are [prerequisites](prerequisites.md):
the cluster operator installs and sizes them, and they are shared with
anything else on the cluster. Plan for roughly the following, which is the
tested installation (two replicas of each controller, three OpenBao pods,
Argo CD with `bootstrap/argocd/values.yaml`):

| Service | Requests | Limits | Volumes |
| --- | --- | --- | --- |
| Argo CD (application-controller 1, server 2, repo-server 2, applicationset-controller 2, notifications 1, Redis HA 3, HAProxy 3) | 910m, 2.2Gi | 8.6, 8.75Gi | |
| cert-manager (controller, webhook, cainjector, 2 each) | 240m, 640Mi | 2.4, 2.25Gi | |
| trust-manager (2) | 50m, 128Mi | 400m, 512Mi | |
| External Secrets Operator (controller, webhook, cert-controller, 2 each) | 180m, 512Mi | 1.8, 1.75Gi | |
| OpenBao (3) | 300m, 768Mi | 3, 1.5Gi | 3 × 10Gi data, 3 × 5Gi audit |
| CloudNativePG operator (2) | 200m, 256Mi | 1, 1Gi | |
| Barman Cloud plugin (1) | 50m, 64Mi | 200m, 256Mi | |
| **Total** | **about 1.9 cores, 4.5 GiB** | 17.4 cores, 16 GiB | 45 GiB |

## Changing resources

Copy the key into `cluster.yaml` with your values; give all four numbers.
Example, a busier PostgreSQL:

```yaml
postgres:
  resources:
    requests: { cpu: "1", memory: 4Gi }
    limits: { cpu: "4", memory: 4Gi }
  storage:
    size: 100Gi
```

Check and push:

```sh
helm template root charts/root -f cluster.yaml > /dev/null && git commit -am "Bigger PostgreSQL" && git push
```

CloudNativePG restarts the instances one at a time (standbys first, then a
switchover), so the database stays available.

## Small profile

A **profile** is a single `cluster.yaml` setting that switches several
others at once. There are two:

- `profile: standard` (the default) is **highly available**: every
  component with state runs several copies on different nodes, so one node
  can fail or reboot without anyone noticing. It needs **3 or more nodes**.
- `profile: small` is for **1 or 2 nodes**: a trial, a lab, or a small
  event. It runs one copy of PostgreSQL and Keycloak and drops every rule
  that refuses to put two copies on the same node. It is **not highly
  available**.

### Why the standard profile needs 3 nodes

PostgreSQL runs 3 instances and refuses to place two of them on the same
node (`podAntiAffinityType: required`), and Keycloak's 2 pods are spread
with `DoNotSchedule`. On 2 nodes the third PostgreSQL instance stays
`Pending` forever, the `postgres` Application never becomes `Healthy`, and
the sync waves after it never start. Three is also the smallest number of
members that keeps a majority (2 of 3) when one fails, which the
Kubernetes control plane and OpenBao need. See
[High availability](high-availability.md).

### What the small profile changes

| Setting | `standard` | `small` | Override in `cluster.yaml` |
| --- | --- | --- | --- |
| PostgreSQL instances | 3 | 1 | `postgres.instances` |
| PostgreSQL instances on different nodes | required | preferred (allowed on one node) | none |
| PostgreSQL PodDisruptionBudget | on | off | none |
| Keycloak pods | 2 | 1 | `keycloak.instances` |
| Keycloak pods on different nodes | required (`DoNotSchedule`) | preferred (`ScheduleAnyway`) | none |
| Keycloak PodDisruptionBudget | on | off | none |
| Den and module PodDisruptionBudgets and spread over nodes | on | off | `den.values.ha`, `modules.<name>.values.ha` |

Web apps keep their 2 replicas in both profiles; they are small and make
updates without a blank page possible. A value you set yourself always
wins over the profile, for example `postgres.instances: 2` with
`profile: small` on 2 nodes.

Turn it on:

1. Add the line to `cluster.yaml`:

    ```yaml
    profile: small
    ```

2. Check, commit and push:

    ```sh
    helm template root charts/root -f cluster.yaml > /dev/null && git commit -am "Small profile" && git push
    ```

    No output from `helm template` means the file is valid.

3. After Argo CD has synced, PostgreSQL has one instance:

    ```sh
    kubectl -n conservices-data get cluster.postgresql.cnpg.io
    ```

    ```text
    NAME             AGE   INSTANCES   READY   STATUS                     PRIMARY
    conservices-pg   12m   1           1       Cluster in healthy state   conservices-pg-1
    ```

You can switch between the profiles later. Going from `standard` to
`small`, CloudNativePG removes the standbys and keeps the primary. Going
from `small` to `standard`, it clones new standbys from the primary; you
need 3 schedulable nodes first, or the new instances stay `Pending`.

### What you lose

- **No failover.** When the node with PostgreSQL or Keycloak goes down,
  sign-in and every app stop until the pod runs again. Kubernetes restarts
  it, on another node if there is one and its volume can move there.
- **Downtime on every node reboot.** Operating system and Kubernetes
  updates mean a short outage (usually a few minutes) instead of none.
  `kubectl drain` no longer waits for a second copy, because there is none.
- **PostgreSQL relies on backups alone.** There is no standby with a copy
  of the data. If the instance's volume is lost, you restore from the
  backup in S3 ([Data: Restore](data.md#restore)). The write-ahead log is
  still archived to S3 continuously, so you lose at most the last few
  minutes. Keep the [backups](data.md#backups) working and test a restore.

### Resources with the small profile

Requests of the template's own containers (prerequisites not included):

| Modules | CPU requests | Memory requests | Volumes |
| --- | --- | --- | --- |
| Den only | 0.8 cores | 2.5 GiB | 30 GiB (2 volumes) |
| All 8 modules | 1.4 cores | 3.3 GiB | 31 GiB (3 volumes) |
| All 8 modules, `standard` profile, for comparison | 2.2 cores | 6.6 GiB | 91 GiB (7 volumes) |

One node with **4 cores and 16 GiB** runs everything, prerequisites
included, if you size the prerequisites down as described next. You can
lower the per-container numbers as well; see
[Fewer resources](#fewer-resources-evaluation-a-few-dozen-users).

### The prerequisites are yours to size

The profile only changes what the template deploys. Argo CD, cert-manager,
trust-manager, External Secrets Operator, OpenBao, CloudNativePG and the
storage are [prerequisites](prerequisites.md), configured by whoever
installs them. Their tested settings are highly available and do **not**
fit on 1 or 2 nodes:

| Prerequisite | Highly available setting that needs 3 nodes | For 1 or 2 nodes |
| --- | --- | --- |
| Argo CD ([step 9](prerequisites.md#9-argo-cd)) | `redis-ha.enabled: true` in `bootstrap/argocd/values.yaml` (3 Redis and 3 HAProxy pods on separate nodes) | `redis-ha.enabled: false` (one Redis pod); `server.replicas`, `repoServer.replicas` and `applicationSet.replicas` may stay 2 or go to 1 |
| OpenBao ([step 7](prerequisites.md#7-external-secrets-operator-and-openbao)) | 3 Raft voters on separate nodes | 1 pod (`server.ha.replicas: 1` in the OpenBao chart). Do not run 2: a 2-member Raft cluster stops when either member is down |
| cert-manager, trust-manager, External Secrets Operator, CloudNativePG operator ([steps 6 to 8](prerequisites.md#6-cert-manager-and-trust-manager)) | 2 replicas each | 1 replica each (`replicaCount: 1` and the matching webhook and cainjector settings in their charts) |
| Longhorn ([step 4](prerequisites.md#4-storage)) | 3 replicas per volume | at most one replica per node, for example Longhorn's `persistence.defaultClassReplicaCount: 1`; otherwise volumes stay `Degraded` |

The Argo CD Application health check in `argocd-cm` is needed in both
profiles; keep it when you change those values.

## Example settings

Two starting points for the per-container resources. Copy the block into
`cluster.yaml` and adjust. They work with either profile.

### Fewer resources (evaluation, a few dozen users)

Fewer modules and smaller limits. With the standard profile this fits on 3
nodes with 2 cores and 8 GiB each, platform services included; for fewer
nodes, add `profile: small` ([Small profile](#small-profile)).

```yaml
modules:
  finance: { enabled: false }
  desk: { enabled: false }
  tasks: { enabled: false }
postgres:
  resources:
    requests: { cpu: 100m, memory: 512Mi }
    limits: { cpu: "1", memory: 512Mi }
  storage: { size: 10Gi, walSize: 5Gi }
keycloak:
  resources:
    requests: { cpu: 100m, memory: 768Mi }
    limits: { cpu: "1", memory: 1Gi }
```

### Large (a convention with thousands of attendees)

More CPU and memory for the database and sign-in, a third Keycloak pod,
and more web app replicas.

```yaml
postgres:
  resources:
    requests: { cpu: "2", memory: 8Gi }
    limits: { cpu: "4", memory: 8Gi }
  storage: { size: 200Gi, walSize: 50Gi }
keycloak:
  instances: 3
  resources:
    requests: { cpu: "1", memory: 2Gi }
    limits: { cpu: "4", memory: 4Gi }
modules:
  rally:
    values:
      frontend: { replicas: 3 }
      backend:
        resources:
          requests: { cpu: 500m, memory: 512Mi }
          limits: { cpu: "2", memory: 1Gi }
```

Plan 3 nodes with 8 cores and 32 GiB each, or more nodes.

## Troubleshooting

**Pods stay `Pending` with `Insufficient cpu` or `Insufficient memory`**
:   The nodes do not have enough unreserved capacity for the requests.
    `kubectl describe node` shows "Allocated resources" per node. Add
    capacity, or lower requests in `cluster.yaml`.

**A container restarts with `OOMKilled`**
:   It needed more memory than its limit. Find it with
    `kubectl get pods -A | grep -v Running` and
    `kubectl describe pod <pod> -n <namespace>` (`Last State: Terminated,
    Reason: OOMKilled`), then raise its memory limit.

**On 1 or 2 nodes, a PostgreSQL or Keycloak pod stays `Pending` and the sync waves stop at `postgres` or `keycloak`**
:   The standard profile is active. `kubectl describe pod <pod> -n <namespace>`
    shows `didn't match pod anti-affinity rules` or
    `didn't match pod topology spread constraints`. Add `profile: small`
    to `cluster.yaml` and push. If `postgres.instances` or
    `keycloak.instances` is set in `cluster.yaml`, lower it too: your own
    value wins over the profile.

**With the small profile, Argo CD's Redis or OpenBao pods stay `Pending`**
:   These prerequisites still use their highly available settings. Size
    them down as in [The prerequisites are yours to size](#the-prerequisites-are-yours-to-size).

**`profile: small` is rejected with `value must be one of 'standard', 'small'`**
:   The value is misspelt or quoted wrongly. Write `profile: small` in
    lowercase.

**The values in `cluster.yaml` have no effect**
:   The key is in the wrong place (it must be nested exactly as in the
    reference) or the change is not pushed. A misspelt key fails the
    schema check: run `helm template root charts/root -f cluster.yaml > /dev/null`.
