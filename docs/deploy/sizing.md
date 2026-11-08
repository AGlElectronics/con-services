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

| | Requests | Limits |
| --- | --- | --- |
| CPU | **2.3 cores** | 21.4 cores |
| Memory | **6.6 GiB** | 13.5 GiB |
| Volumes | 91 GiB (7 volumes) | |

Requests are what the cluster must have free. Limits are a ceiling per
container that is never reached by all containers at once, so their sum can
be far above the cluster's size. Not included: Kubernetes itself, Cilium,
Longhorn, CoreDNS and the platform services (Argo CD, cert-manager,
trust-manager, External Secrets Operator, OpenBao, CloudNativePG; see
[Prerequisites](prerequisites.md) and
[Platform services](#platform-services) below), and short-lived jobs and
init containers.

Recommended for the defaults: **3 nodes with 4 cores and 16 GiB each**
([Prerequisites](prerequisites.md#1-kubernetes-and-nodes)).

## Every component

"Replicas" is the number of pods; requests and limits are per container.
The `cluster.yaml` column names the key that changes it.

### Data and identity

| Component | Container | Replicas | Requests | Limits | `cluster.yaml` |
| --- | --- | --- | --- | --- | --- |
| PostgreSQL | postgres | 3 | 250m, 1Gi | 2, 1Gi | `postgres.resources` |
| | backup sidecar | 3 (one per instance) | 50m, 128Mi | 500m, 512Mi | `postgres.backup.sidecarResources` |
| Keycloak operator | keycloak-operator | 1 | 100m, 256Mi | 500m, 512Mi | `keycloakOperator.resources` |
| Keycloak | keycloak | 2 | 250m, 1Gi | 2, 2Gi | `keycloak.resources` |

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
| PostgreSQL data | 3 | 20Gi | `postgres.storage.size` |
| PostgreSQL WAL | 3 | 10Gi | `postgres.storage.walSize` |
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

## Profiles

Two starting points. Copy the block into `cluster.yaml` and adjust.

### Small (evaluation, a few dozen users)

Fewer modules and smaller limits; still 3 nodes, because PostgreSQL and
Redis need 3 different nodes. Fits on 3 nodes with 2 cores and 8 GiB each,
platform services included.

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

**The values in `cluster.yaml` have no effect**
:   The key is in the wrong place (it must be nested exactly as in the
    reference) or the change is not pushed. A misspelt key fails the
    schema check: run `helm template root charts/root -f cluster.yaml > /dev/null`.
