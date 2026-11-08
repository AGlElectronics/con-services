# Prerequisites

The template installs Con Services **on top of** a running, hardened
Kubernetes cluster: Den, the modules, Keycloak, the PostgreSQL database
and the configuration that ties them together. It does not build the
cluster, and it does not install cluster-wide services that a production
cluster normally already runs (Argo CD, certificates, secret management,
the PostgreSQL operator, load balancer addresses, cluster DNS). This page lists what you must have before you start,
and gives a command for each item so you can check it.

!!! note "Installing the prerequisites is not covered"
    How to install and run Kubernetes, Cilium, Argo CD, cert-manager,
    OpenBao and the other prerequisites is beyond the scope of these guides. Each item
    below links to its upstream documentation and says what the template
    needs from it; the rest is up to whoever runs the cluster.

## Terms used on this page

**CNI**
:   The Container Network Interface plugin: the component that gives pods
    their network. Here it is [Cilium](https://cilium.io).

**Gateway API**
:   The Kubernetes standard for bringing HTTP traffic into the cluster
    (objects `Gateway`, `HTTPRoute`, `BackendTLSPolicy`). Its object types
    are installed as CRDs (custom resource definitions); Cilium implements
    them. See the [glossary](../concepts/glossary.md#gateway-api).

**StorageClass**
:   Tells Kubernetes how to create disks (volumes) for pods. The *default*
    StorageClass is used when a volume does not name one.

**LoadBalancer IP**
:   The address a `Service` of type `LoadBalancer` gets, reachable from
    outside the cluster. The two Gateways each need one.

**Platform service**
:   A cluster-wide service that many applications share, run by whoever
    runs the cluster: here Argo CD, cert-manager, trust-manager, External
    Secrets Operator, OpenBao and CloudNativePG. The template uses them but
    never installs, upgrades or removes them.

## At a glance

| Item | Version | Installed by | Check |
| --- | --- | --- | --- |
| Kubernetes, 3 or more schedulable nodes | 1.37 (validated); 1.35 or newer | you | [1](#1-kubernetes-and-nodes) |
| Cilium with kube-proxy replacement and Gateway API | 1.20.4 (1.20 or newer) | you | [2](#2-cilium) |
| Gateway API CRDs, standard channel | v1.6.3 | you (k3s ships them) | [3](#3-gateway-api-crds) |
| A replicated default StorageClass | Longhorn 1.13.0 recommended | you | [4](#4-storage) |
| Two LoadBalancer IPs; pods reach `https://auth.<domain>` | | you | [5](#5-loadbalancer-ips-dns-and-ports) |
| cert-manager and trust-manager | v1.21.3 and v0.26.0 | you | [6](#6-cert-manager-and-trust-manager) |
| External Secrets Operator | chart 2.14.0 (API `external-secrets.io/v1`) | you | [7](#7-external-secrets-operator-and-openbao) |
| OpenBao, initialised and unsealed | 2.7.2 (chart `openbao` 0.30.7) | you | [7](#7-external-secrets-operator-and-openbao) |
| CloudNativePG operator and Barman Cloud plugin | 1.30.1 (chart 0.29.1) and v0.15.1 (chart 0.8.1) | you | [8](#8-cloudnativepg-and-the-barman-cloud-plugin) |
| Argo CD with the Application health check | v3.6.1 (chart `argo-cd` 10.14.0) | you | [9](#9-argo-cd) |
| Accounts: DNS, S3, mail, Git hosting | | you | [11](#11-accounts) |
| A cluster run along common practice (HA control plane, etcd backups, updates, ...) | | you | [12](#12-how-the-cluster-is-run) |

The template installs the rest: the Keycloak operator and Keycloak, the
PostgreSQL cluster, the internal certificate authority (CA), the Let's
Encrypt issuers, the Gateways, Den and the modules.

"Validated" means the CI of the template renders every manifest and checks
it against the Kubernetes 1.37 API schemas and the CRDs (custom resource
definitions) of the versions in this table, and the project's test
cluster runs those versions. Newer patch releases normally work; older
versions are not checked.

`bootstrap/install-root.sh` checks Argo CD and items 6 to 8 before it does
anything (see [Argo CD](argocd.md#5-apply-the-root-application)).

## 1. Kubernetes and nodes

You need **at least 3 schedulable nodes**. PostgreSQL, OpenBao and Argo
CD's Redis each place their 3 copies on 3 different nodes, and refuse to
put two on the same node; with 2 nodes the third copy stays `Pending`.

Capacity for the default settings (all modules on, from
[Sizing and resources](sizing.md)):

| | Requested by the template | Recommended per node (3 nodes) |
| --- | --- | --- |
| CPU | about 2.3 cores | 4 cores |
| Memory | about 6.6 GiB | 16 GiB |
| Disk for volumes | 91 GiB of volumes (see [Storage](#4-storage)) | 150 GiB free for Longhorn (including OpenBao's), plus the operating system |

The recommendation leaves room for Kubernetes itself, Cilium, Longhorn,
CoreDNS, the prerequisites below (Argo CD, cert-manager, External Secrets
Operator, OpenBao, CloudNativePG; together about 1.9 cores and 4.5 GiB of
requests, see [Sizing](sizing.md#platform-services)) and load peaks.

Check:

```sh
kubectl version
kubectl get nodes -o wide
```

```text
Client Version: v1.36.1
Kustomize Version: v5.8.1
Server Version: v1.37.2+k3s1

NAME     STATUS   ROLES                       AGE   VERSION        INTERNAL-IP
node-1   Ready    control-plane,etcd,master   2d    v1.37.2+k3s1   10.0.0.11
node-2   Ready    control-plane,etcd,master   2d    v1.37.2+k3s1   10.0.0.12
node-3   Ready    control-plane,etcd,master   2d    v1.37.2+k3s1   10.0.0.13
```

All nodes must be `Ready`, and **at least 3** of them must accept
workloads (no `NoSchedule` taint). Tainted control-plane nodes are fine,
and recommended when you have dedicated worker nodes:

```sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

```text
NAME       TAINTS
cp-1       [map[effect:NoSchedule key:node-role.kubernetes.io/control-plane value:true]]
cp-2       [map[effect:NoSchedule key:node-role.kubernetes.io/control-plane value:true]]
cp-3       [map[effect:NoSchedule key:node-role.kubernetes.io/control-plane value:true]]
worker-1   <none>
worker-2   <none>
worker-3   <none>
```

On a 3-node cluster every node runs workloads, so all three show `<none>`.

## 2. Cilium

Cilium must run with:

- `kubeProxyReplacement: true` (the Gateway needs it);
- `gatewayAPI.enabled: true`, which creates the GatewayClass `cilium`;
- `l7Proxy: true` (the default), because the Gateway is served by Envoy;
- `l2announcements.enabled: true` **only** if Cilium hands out the Gateway
  IPs on your LAN (see [step 5](#5-loadbalancer-ips-dns-and-ports)).

How to install it: [Cilium documentation](https://docs.cilium.io/en/stable/installation/k8s-install-helm/).
The template's network policies use Cilium features (DNS-based egress
rules for S3), so another CNI is not supported.

Check:

```sh
kubectl -n kube-system get ds cilium
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.kube-proxy-replacement} {.data.enable-gateway-api}{"\n"}'
kubectl get gatewayclass cilium
```

```text
NAME     DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
cilium   3         3         3       3            3           kubernetes.io/os=linux   2d
true true
NAME     CONTROLLER                     ACCEPTED   AGE
cilium   io.cilium/gateway-controller   True       2d
```

## 3. Gateway API CRDs

The Gateways and the apps' routes use the Gateway API **v1.6.3, standard
channel**, which contains `Gateway`, `HTTPRoute` and `BackendTLSPolicy`
(`gateway.networking.k8s.io/v1`). k3s installs exactly these with its
`gateway-api-crd` add-on; elsewhere see the
[Gateway API installation guide](https://gateway-api.sigs.k8s.io/guides/getting-started/#installing-gateway-api).
Cilium only creates its GatewayClass if the CRDs exist when its operator
starts.

Check:

```sh
kubectl get crd backendtlspolicies.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version} {.metadata.annotations.gateway\.networking\.k8s\.io/channel}{"\n"}'
```

```text
v1.6.3 standard
```

## 4. Storage

The template needs a **default StorageClass whose volumes are replicated**
across nodes, so a volume survives the loss of a node. Longhorn 1.13 is
recommended and tested; a cloud provider's replicated block
storage works too.

Volumes the template creates (default sizes, all changeable in
`cluster.yaml`):

| Volume | Count | Size each | Total |
| --- | --- | --- | --- |
| PostgreSQL data | 3 | 20 GiB | 60 GiB |
| PostgreSQL WAL (write-ahead log) | 3 | 10 GiB | 30 GiB |
| Wiki editing buffers | 1 | 1 GiB | 1 GiB |
| | | | **91 GiB** |

PostgreSQL copies its data to its other instances itself. On a storage
layer that also keeps 3 copies, every byte is stored 9 times. With
Longhorn, set `storage.longhornSingle.enabled: true` in `cluster.yaml`: the
template creates the StorageClass `longhorn-single` (one copy, on the pod's
node) and uses it for PostgreSQL. The 91 GiB then need about 93 GiB of
disk; with the default 3-copy class they need about 273 GiB. The volumes of
the prerequisites (OpenBao's, for example) come on top.

Check:

```sh
kubectl get storageclass
```

```text
NAME                 PROVISIONER          RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
longhorn (default)   driver.longhorn.io   Delete          Immediate           true                   2d
```

Exactly one class must say `(default)`.

## 5. LoadBalancer IPs, DNS and ports

The template creates two Gateways, each a `Service` of type
`LoadBalancer`:

| Gateway | Serves | Reachable from |
| --- | --- | --- |
| `public` | Den, the modules, Keycloak | the internet: forward TCP 80 and 443 to it |
| `internal` | the Keycloak admin console, and optionally the Longhorn and Hubble UIs | your LAN or VPN only |

The cluster must give them addresses: a cloud load balancer, MetalLB, or a
Cilium [LB IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/) pool
(with [L2 announcements](https://docs.cilium.io/en/stable/network/l2-announcements/)
on bare metal). With Cilium you
can pin the two addresses from the pool with
`gateway.public.loadBalancerIP` and `gateway.internal.loadBalancerIP`.

**Pods must reach Keycloak at its public address.** Backends check
sign-in tokens against `https://auth.<domain>`. If pods cannot reach the
public Gateway IP from inside the cluster (common behind a home or office
router without NAT hairpinning), make the cluster's DNS answer
`auth.<domain>` with the in-cluster Service
`keycloak-public.conservices-identity.svc.cluster.local`
([how](dns-and-certificates.md#inside-the-cluster-reaching-keycloak)).

The cluster also needs **outbound** HTTPS to your S3 provider, Let's
Encrypt, your DNS provider's API, `ghcr.io` and the chart repositories.

## 6. cert-manager and trust-manager

[cert-manager](https://cert-manager.io/docs/installation/) issues
certificates; [trust-manager](https://cert-manager.io/docs/trust/trust-manager/installation/)
copies a CA certificate into many namespaces. The template uses them for
the Let's Encrypt wildcard certificate of the Gateways and for its own
internal CA, which encrypts every connection inside the cluster
([Internal TLS](../operations/internal-tls.md)).

What the template needs:

- cert-manager **v1.21** with its CRDs, whose *cluster resource
  namespace* (where ClusterIssuers read their Secrets) is
  **`cert-manager`**. That is the default when cert-manager is installed in
  the namespace `cert-manager`. The template creates its CA and the DNS
  provider token (an ExternalSecret) there.
- trust-manager **v0.26** reading its sources from `cert-manager`
  (`app.trust.namespace: cert-manager`, the chart's default). The template
  creates the Bundle `conservices-internal-ca`, which copies the CA into
  every namespace labelled `app.kubernetes.io/part-of=conservices`.
- For the Let's Encrypt DNS-01 check: if the cluster's DNS answers
  differently from the internet for your domain (split-horizon DNS), point
  cert-manager at public resolvers with the chart values
  `dns01RecursiveNameservers: "1.1.1.1:53,8.8.8.8:53"` and
  `dns01RecursiveNameserversOnly: true`. Otherwise certificates wait
  forever ([DNS and certificates](dns-and-certificates.md#troubleshooting)).

You can keep the cluster's own ClusterIssuers; the template adds
`conservices-internal-ca`, `letsencrypt-staging` and `letsencrypt-prod` next
to them.

Check:

```sh
kubectl -n cert-manager get deploy
kubectl get crd certificates.cert-manager.io bundles.trust.cert-manager.io
```

```text
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
cert-manager              2/2     2            2           12d
cert-manager-cainjector   2/2     2            2           12d
cert-manager-webhook      2/2     2            2           12d
trust-manager             2/2     2            2           12d
NAME                            CREATED AT
certificates.cert-manager.io    2026-10-26T09:12:44Z
bundles.trust.cert-manager.io   2026-10-26T09:13:02Z
```

## 7. External Secrets Operator and OpenBao

Secrets never go into Git. [OpenBao](https://openbao.org/docs/platform/k8s/helm/)
stores them, and the [External Secrets Operator](https://external-secrets.io/latest/introduction/getting-started/)
(ESO) copies them into ordinary Kubernetes Secrets. The template creates one
`ClusterSecretStore` named `openbao` and an `ExternalSecret` for every
Secret it needs.

What the template needs:

- **ESO** with the `external-secrets.io/v1` API (chart 2.14 or newer). Note
  its namespace and service account (chart defaults:
  `external-secrets`/`external-secrets`); the ClusterSecretStore logs in to
  OpenBao as that service account.
- **OpenBao**, initialised and unsealed, reachable from ESO over HTTPS.
  Unsealing after restarts, backups and upgrades are the job of whoever
  runs OpenBao; the template never touches them.
- If OpenBao's certificate is not publicly trusted: its CA certificate in a
  ConfigMap or Secret that ESO can read (default: ConfigMap `openbao-ca`,
  key `ca.crt`, in ESO's namespace).
- A token that may enable a secrets engine and an auth method and write
  policies, once, for `bootstrap/scripts/openbao-configure.sh`. It sets up
  the KV engine, the Kubernetes login and the read-only policy Con Services
  uses ([Secrets with OpenBao](secrets-openbao.md)).

Tell the template where they are in `cluster.yaml` if they are not at the
defaults (`openbao.*`, `externalSecrets.*`; see the
[reference](argocd.md#cluster-prerequisites)).

!!! note "A Vault or OpenBao you already run"
    HashiCorp Vault works the same way: the store uses ESO's `vault`
    provider, which speaks to both. The scripts run the `bao` command inside
    the OpenBao pods; with Vault, run the same steps by hand with `vault`.

Check:

```sh
kubectl get crd clustersecretstores.external-secrets.io
kubectl -n external-secrets get serviceaccount external-secrets
kubectl -n openbao exec openbao-0 -- bao status
```

```text
NAME                                      CREATED AT
clustersecretstores.external-secrets.io   2026-10-26T09:20:11Z
NAME               SECRETS   AGE
external-secrets   0         12d
...
Initialized     true
Sealed          false
HA Enabled      true
```

## 8. CloudNativePG and the Barman Cloud plugin

[CloudNativePG](https://cloudnative-pg.io/documentation/current/installation_upgrade/)
(CNPG) is the operator that runs PostgreSQL in Kubernetes; the template
creates the PostgreSQL cluster `conservices-pg` with it. The
[Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/)
adds backups to S3.

What the template needs:

- the CNPG operator **1.30** with its CRDs;
- the Barman Cloud plugin **v0.15** in the **same namespace** as the
  operator (CNPG only finds plugins in its own namespace); the plugin needs
  cert-manager;
- the operator's namespace in `postgres.operatorNamespace` (default
  `cnpg-system`). The database's network policy lets only that namespace
  in.

Check:

```sh
kubectl -n cnpg-system get deploy
kubectl get crd clusters.postgresql.cnpg.io objectstores.barmancloud.cnpg.io
```

```text
NAME                     READY   UP-TO-DATE   AVAILABLE   AGE
barman-cloud             1/1     1            1           12d
cnpg-cloudnative-pg      2/2     2            2           12d
NAME                                CREATED AT
clusters.postgresql.cnpg.io         2026-10-26T09:31:40Z
objectstores.barmancloud.cnpg.io    2026-10-26T09:32:05Z
```

## 9. Argo CD

[Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/)
reads your copy of the template from Git and installs everything in it,
in order. The template only creates Applications in it; it does not
install, upgrade or expose Argo CD.

What the template needs:

- Argo CD **v3.6** with its Applications in the namespace `argocd`.
- The **health check for Application objects** in `argocd-cm`. Argo CD has
  none built in; without it the root Application does not wait for one
  sync wave to be Healthy before starting the next, and every component
  starts at once:

    ```yaml
    resource.customizations.health.argoproj.io_Application: |
      hs = {}
      hs.status = "Progressing"
      hs.message = ""
      if obj.status ~= nil then
        if obj.status.health ~= nil then
          hs.status = obj.status.health.status
          if obj.status.health.message ~= nil then
            hs.message = obj.status.health.message
          end
        end
      end
      return hs
    ```

    With the upstream Helm chart this goes under `configs.cm`. The template's
    `bootstrap/argocd/values.yaml` contains it, together with highly
    available settings and resource limits you can reuse.
- Read access to your copy of the template, if it is private (a
  [repository credential](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/)
  with read-only rights; it is a secret, see
  [Secrets](../operations/secrets.md)).

Check:

```sh
kubectl -n argocd get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n argocd get cm argocd-cm -o yaml | grep -c health.argoproj.io_Application
```

```text
quay.io/argoproj/argocd:v3.6.1
1
```

## 10. Tools on your computer

| Tool | Version used in the guides | Used for |
| --- | --- | --- |
| `kubectl` | 1.36 or newer | everything |
| `helm` | 3.19 | `helm template` checks, `install-root.sh`, `openbao-configure.sh`, `openbao-seed.sh` |
| `git` | any | your copy of the template |
| `bash`, `jq`, `openssl` | bash 4 or newer | the bootstrap scripts (on Windows: use WSL) |
| `age` | 1.2 | the key Den encrypts its backups to |

Check:

```sh
kubectl version --client && helm version --short && jq --version && openssl version && age --version
```

```text
Client Version: v1.36.1
Kustomize Version: v5.8.1
v3.19.0+g3d8990f
jq-1.7.1
OpenSSL 3.0.13 30 Jan 2024
v1.2.1
```

## 11. Accounts

| Account | What for | Needed |
| --- | --- | --- |
| A domain and its DNS | `<app>.<domain>` records; DNS-01 challenges for the wildcard certificate | yes. Cloudflare is built in (an API token); any other provider works with your own cert-manager solver ([DNS and certificates](dns-and-certificates.md)) |
| A managed S3-compatible object storage | files of Den, Stash, Rally, Learn, Wiki and Tasks; database and Den backups | yes ([Data](data.md)) |
| An SMTP mail server | Keycloak's password-reset and verification mail; Learn's mail | yes by default; turn Keycloak mail off with `keycloak.smtp.enabled: false` |
| GitHub (or another Git host) | your private copy of the template, which Argo CD reads | yes |

Credentials for these accounts go into OpenBao, never into Git; see
[Secrets](../operations/secrets.md).

## 12. How the cluster is run

The template neither sets these up nor checks them; they are the job of
whoever runs the cluster. We expect a cluster run along common practice
(the [Kubernetes security checklist](https://kubernetes.io/docs/concepts/security/security-checklist/)
and the CIS Kubernetes Benchmark); a managed Kubernetes service covers most
of the control-plane items for you.

| Expectation | Why |
| --- | --- |
| Highly available control plane: 3 (or 5) control-plane and etcd members, or a managed control plane | One failed or rebooting node does not stop the Kubernetes API |
| etcd snapshots on a schedule, copied off the cluster, and a tested restore | The only way back after losing etcd's majority; the template's own data is backed up separately ([Data](data.md#backups)) |
| Secrets encrypted at rest in etcd | Snapshots and disks do not reveal Secrets |
| Kubernetes API not reachable from the internet; admin kubeconfigs kept private | A kubeconfig is a full-access credential |
| API server audit logging | Shows who changed what |
| Encrypted traffic between nodes (for example Cilium WireGuard) when the nodes share a network with other machines | Pod traffic, including database connections, cannot be read on the wire |
| Node operating systems get security updates automatically; reboots drain one node at a time | Kernel and runtime fixes without downtime ([High availability](high-availability.md#planned-maintenance-without-downtime)) |
| Clocks synchronised (NTP) on every node | Certificates, tokens and etcd depend on correct time |
| Off-cluster backups of the volumes (for example a Longhorn backup target) | Volume snapshots live on the same disks as the volumes |
| Pinned versions of Kubernetes and the add-ons; upgrades one minor version at a time | Upgrades are deliberate and reversible |
| The prerequisites of steps 6 to 8 run highly available (2 replicas of cert-manager, ESO and the CNPG operator, 3 OpenBao pods) and OpenBao is unsealed after every restart, or unseals itself | Certificates, secrets and database failover keep working while a node is down ([High availability](high-availability.md)) |
| OpenBao backed up (Raft snapshots) off the cluster, unseal or recovery keys kept offline | Without them a rebuilt cluster cannot read its secrets |
| Monitoring of nodes, disks and certificates, with alerts | Full disks and expired certificates are noticed before users do |

## Troubleshooting

**`kubectl get gatewayclass cilium` says `NotFound`**
:   Cilium's Gateway API support is off, or the Gateway API CRDs were
    installed after Cilium. Check `gatewayAPI.enabled: true` in your Cilium
    values, then restart the operator:
    `kubectl -n kube-system rollout restart deploy/cilium-operator`.

**The GatewayClass is `ACCEPTED False` with `unsupported version`**
:   The Gateway API CRDs are older or newer than this Cilium release
    supports. Replace them with v1.6.3 (step 3) and restart the Cilium
    operator.

**`argocd-cm` has no `resource.customizations.health.argoproj.io_Application` entry**
:   Add the health check from [step 9](#9-argo-cd) to `argocd-cm` (with the
    Helm chart: `configs.cm`) before applying the root Application.
    Argo CD picks the change up without a restart.

**Two StorageClasses say `(default)`**
:   For example k3s' `local-path` next to Longhorn. Remove the mark from the
    other one:
    `kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'`.

**Fewer than 3 nodes accept workloads**
:   Control-plane nodes of kubeadm and many managed services are tainted.
    Add worker nodes, or, on a cluster of only 3 nodes, let all 3 run
    workloads:
    `kubectl taint nodes <node> node-role.kubernetes.io/control-plane:NoSchedule-`.

**`install-root.sh` stops with `missing: ...`**
:   One of the prerequisites of steps 6 to 8 is not installed, or is not
    where `cluster.yaml` says. Each line names what is missing, for example
    `missing: Barman Cloud plugin (CRD objectstores.barmancloud.cnpg.io not found)`
    or `missing: External Secrets service account external-secrets/external-secrets (cluster.yaml externalSecrets.*)`.
    Install it, or correct `openbao.*` / `externalSecrets.*` in
    `cluster.yaml`, push, and run the script again.

**cert-manager runs in another namespace than `cert-manager`**
:   The template keeps the Secrets of its ClusterIssuers (the CA key, the
    DNS token) in `cert-manager`, so the issuers stay `Ready False` with
    `secret "conservices-internal-ca" not found`. Create the namespace
    `cert-manager`, set cert-manager's `clusterResourceNamespace` chart
    value and trust-manager's `app.trust.namespace` to it.

**PostgreSQL backups fail with `plugin barman-cloud.cloudnative-pg.io not found`**
:   The Barman Cloud plugin runs in another namespace than the CNPG
    operator. Install it in the operator's namespace.

Next: [Argo CD and cluster.yaml](argocd.md).
