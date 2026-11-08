# High availability

**Goal:** when one pod or one node dies, users keep working. The reference
setup in [`con-services-gitops`](index.md) follows this rule wherever the
software allows it. This page lists, per component, how it is protected and
what a failure looks like, including the parts that are not highly
available yet and why.

## Terms

**Replica**
:   One running copy of a program. Two replicas on different nodes mean one
    can die while the other keeps serving.

**PodDisruptionBudget (PDB)**
:   A rule that stops Kubernetes from taking down too many replicas at once
    during planned work, such as draining a node for an upgrade.

**Topology spread / anti-affinity**
:   Rules that place replicas on different nodes, so one node failing never
    takes all of them.

**Quorum**
:   A majority of members (2 of 3). etcd and OpenBao keep working as
    long as a majority is up. With 3 members you can lose 1.

## What survives what

Argo CD, cert-manager, trust-manager, External Secrets, OpenBao and the
CloudNativePG operator are [prerequisites](prerequisites.md): how highly
available they are depends on how your cluster runs them. The rows below
show the tested installation (2 replicas of each controller, 3 OpenBao
voters); the template only needs them to be there.

| Component | Replicas | Losing one pod | Losing one node (of 3) |
| --- | --- | --- | --- |
| Kubernetes control plane (k3s, embedded etcd) | 3 servers | n/a | keeps working (2 of 3 etcd members) |
| Cilium agent / operator | 1 per node / 2 | the node's networking pauses until the agent restarts (seconds) | traffic moves to the other nodes |
| Cilium Gateway (Envoy) | on every node, one LB IP announced by one node | n/a | the IP moves to another node within seconds (L2 announcement lease) |
| Longhorn volumes | 3 replicas (`longhorn` class) | n/a | volume keeps working from the other replicas, rebuilds when the node returns |
| Argo CD (prerequisite) | server 2, repo-server 2, Redis HA 3 | no effect | no effect; syncing continues |
| cert-manager, trust-manager, External Secrets, CloudNativePG operator (prerequisites) | 2 each | no effect | no effect |
| OpenBao (prerequisite) | 3 Raft voters | no effect (a standby takes over) | keeps working; unless OpenBao auto-unseals, the restarted pod must be **unsealed** by its operator before it rejoins |
| PostgreSQL (CloudNativePG) | 3 instances, 1 synchronous standby | if the primary dies, a standby is promoted in about 10–30 seconds; apps reconnect | same; no committed transaction is lost (synchronous replica) |
| Object storage (managed S3, for example Hetzner) | run by the provider, outside the cluster | no effect | no effect; the cluster only needs outbound internet access |
| Keycloak | 2+ instances, sessions in the database-backed cache | no effect; signed-in users stay signed in | no effect |
| Web apps (`*-frontend`) | 2+, PDB, spread over nodes | no effect | no effect |
| Den backend, module backends | **1** | requests fail until the pod is back, usually under a minute | the pod restarts on another node; under two minutes including volume reattach |
| Den operator | **1** | backups and database actions wait until it is back | same |

Because the backends store everything in PostgreSQL and S3, a restarted
backend continues where the old one stopped. Signed-in users keep their
session (it lives in Keycloak and the browser); they may see one failed
request.

## Why some backends run one replica

These run exactly one replica on purpose, with the `Recreate` strategy, so
two copies never run at the same time:

| Workload | Reason | What it would take to scale |
| --- | --- | --- |
| `den-backend` | Backup download links are kept in process memory; database migrations must not run twice at once. | Store download tokens in PostgreSQL; run migrations with a database lock. |
| `den-operator` | Runs the daily backup on a timer with an in-process lock. | Leader election (Kubernetes Lease) or a database lock. |
| `stash-backend` | Applies its migrations in-process at start-up. | Move migrations to an initContainer with a lock, like the other modules. |
| Wiki backend | Keeps live-editing buffers on its volume. | Shared buffer store (database or Redis). |
| Other module backends | Run migrations as an initContainer; some keep timers in memory. | Check each module's documentation before raising `replicas`. |

Kubernetes restarts a failed singleton automatically, and the readiness
probe keeps traffic away until it is ready. The charts refuse higher
replica counts where they would break something.

## Planned maintenance without downtime

Upgrading a node (k3s, the operating system) is safe one node at a time:

1. Drain the node. The PDBs make Kubernetes move pods one at a time:

    ```sh
    kubectl drain node-2 --ignore-daemonsets --delete-emptydir-data
    ```

    You should see each pod evicted, and singletons restarting on another
    node. If a PDB blocks the drain, the command waits and says
    `Cannot evict pod as it would violate the pod's disruption budget`;
    that means another replica is not ready yet. Wait, it continues by
    itself.
2. Upgrade and reboot the node.
3. Bring it back:

    ```sh
    kubectl uncordon node-2
    ```

4. If OpenBao ran on that node and does not auto-unseal, have its pod
   unsealed (`bao status` must show `Sealed false`).
5. Wait until `kubectl get pods -A` shows everything ready and Longhorn
   shows all volumes `Healthy` before you start the next node.

## What HA does not replace

- **Backups.** Replication copies mistakes too: a dropped table is dropped on
  every replica. Keep the PostgreSQL backups and Den's backups, and store
  them **off-site**; see [Data](data.md#backups) and
  [Disaster recovery](../operations/disaster-recovery.md).
- **A second physical host.** Three VMs on one server do not survive that
  server failing.
- **OpenBao's unseal keys and backups.** They belong to whoever runs
  OpenBao, but without them a fully restarted cluster cannot read Con
  Services' secrets. Make sure they exist and are kept offline.

## Troubleshooting

**A node drain hangs forever**
: A PDB cannot be satisfied, usually because a component has only one
  ready replica (for example a web app whose second pod is `Pending`). Run
  `kubectl get pdb -A` and look for `ALLOWED DISRUPTIONS 0`, then fix the
  pending pod (`kubectl describe pod`) instead of forcing the drain.

**Pods of one component all landed on the same node**
: Topology spread uses `ScheduleAnyway`, so if other nodes were full or not
  ready, replicas may share a node. Once all nodes are ready, run
  `kubectl rollout restart deployment/<name> -n <namespace>` to spread them
  again.

**CloudNativePG instances stay `Pending` after adding the cluster**
: They require different nodes (`podAntiAffinityType: required`). With fewer
  than 3 schedulable nodes, the third instance cannot be placed. Make the
  control-plane node schedulable or lower `postgres.instances` in
  `cluster.yaml` (and accept less redundancy).

**After a full restart of all nodes nothing gets its secrets**
: OpenBao is sealed. Have it unsealed (by its operator, or by its
  auto-unseal); External Secrets then refreshes the Secrets by itself
  within its refresh interval. See
  [Secrets with OpenBao](secrets-openbao.md#troubleshooting).
