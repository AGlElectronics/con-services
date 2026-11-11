# High availability

**Goal:** when one pod or one node dies, users keep working. The reference
setup in [`con-services-gitops`](index.md) follows this rule wherever the
software allows it. This page lists, per component, how it is protected and
what a failure looks like, including the parts that are not highly
available yet and why.

Everything on this page describes the default, `profile: standard`, which
needs **3 or more nodes**. The [small profile](sizing.md#small-profile)
(`profile: small`, for 1 or 2 nodes) runs one copy of PostgreSQL and
Keycloak and is **not** highly available; see
[Fewer than 3 nodes](#fewer-than-3-nodes-the-small-profile).

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

## Why 3 nodes

Two copies on two nodes survive one node failing, so why three?

- **Quorum.** The Kubernetes control plane (etcd) and OpenBao (Raft)
  keep working only while a majority of their members is up. With 2
  members the majority is 2, so losing either one stops them. With 3, the
  majority is 2 and one may fail.
- **PostgreSQL keeps a synchronous standby while one node is down.** With
  3 instances on 3 nodes, losing one still leaves a primary and a standby
  that confirms every commit, so a second failure loses no data.
- **Updates without downtime.** Draining one node for an update leaves two
  nodes that still hold a copy of everything.

That is why PostgreSQL requires its 3 instances on 3 different nodes, and
why Keycloak's pods refuse to share a node in the standard profile.

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
| PostgreSQL (CloudNativePG) | 3 instances on 3 different nodes, 1 synchronous standby, PDB | if the primary dies, a standby is promoted in about 10–30 seconds; apps reconnect | same; no committed transaction is lost (synchronous replica) |
| Object storage (managed S3, for example Hetzner) | run by the provider, outside the cluster | no effect | no effect; the cluster only needs outbound internet access |
| Keycloak | 2+ instances on different nodes, PDB, sessions in the database-backed cache | no effect; signed-in users stay signed in | no effect |
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
| `den-operator` | Runs the daily backup on a timer with an in-process lock. | Leader election (Kubernetes Lease) or a database lock. |
| `stash-backend` | Applies its migrations in-process at start-up. | Move migrations to an initContainer with a lock, like the other modules. |
| Wiki backend | Keeps live-editing buffers on its volume. | Shared buffer store (database or Redis). |
| Other module backends | Run migrations as an initContainer; some keep timers in memory. | Check each module's documentation before raising `replicas`. |

`den-backend` may run several replicas (`backend.replicas` in the Den
chart): backup download links are stored in PostgreSQL, and migrate
initContainers that start together wait on a PostgreSQL advisory lock. Its
rate limits (pairing redeem, public brand, backup downloads) are counted per
replica.

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

## Fewer than 3 nodes: the small profile

With `profile: small` in `cluster.yaml` the template runs:

| Component | Standard profile | Small profile |
| --- | --- | --- |
| PostgreSQL | 3 instances, required on different nodes, PDB | 1 instance, no PDB |
| Keycloak | 2 pods, `DoNotSchedule` spread, PDB | 1 pod, `ScheduleAnyway` spread, no PDB |
| Den and module web apps | 2 replicas, spread, PDB | 2 replicas, no spread rule, no PDB |
| Backends, Den operator | 1 | 1 |

What a failure looks like then:

- **One pod dies:** PostgreSQL or Keycloak is unavailable until Kubernetes
  has restarted it, usually under a minute. Sign-in and the apps fail
  meanwhile.
- **A node reboots or dies:** everything on it is down until the node is
  back, or until the pods have restarted on the other node (if there is
  one and the volumes can follow).
- **The PostgreSQL volume is lost:** restore from the backup in S3
  ([Data: Restore](data.md#restore)).

The PDBs are off on purpose: with one copy, a PDB with `minAvailable: 1`
would block `kubectl drain` forever. Draining a node simply stops the pods
on it. The prerequisites (Argo CD, OpenBao and the others) need their own
non-HA settings; see
[Sizing: the prerequisites are yours to size](sizing.md#the-prerequisites-are-yours-to-size).

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
  control-plane node schedulable, add a node, or switch to
  `profile: small` in `cluster.yaml` (one instance, not highly available;
  see [Small profile](sizing.md#small-profile)).

**The second Keycloak pod stays `Pending` with `didn't match pod topology spread constraints`**
: In the standard profile Keycloak's pods refuse to share a node. With
  only one schedulable node, add a node or use `profile: small`.

**After a full restart of all nodes nothing gets its secrets**
: OpenBao is sealed. Have it unsealed (by its operator, or by its
  auto-unseal); External Secrets then refreshes the Secrets by itself
  within its refresh interval. See
  [Secrets with OpenBao](secrets-openbao.md#troubleshooting).
