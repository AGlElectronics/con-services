# Prerequisites

The template installs Con Services and everything it needs **on top of** a
Kubernetes cluster. It does not build the cluster, its network or its
storage. This page lists what you must have before you start, and gives a
command for each item so you can check it. If you still need a cluster,
[Example: a k3s cluster](cluster.md) shows one tested way to build it.

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

## At a glance

| Item | Version | Installed by | Check |
| --- | --- | --- | --- |
| Kubernetes, 3 or more schedulable nodes | 1.37 (validated); 1.35 or newer | you | [1](#1-kubernetes-and-nodes) |
| Cilium with kube-proxy replacement and Gateway API | 1.20.4 (1.20 or newer) | you | [2](#2-cilium) |
| Gateway API CRDs, standard channel | v1.6.3 | you (k3s ships them) | [3](#3-gateway-api-crds) |
| A replicated default StorageClass | Longhorn 1.13.0 recommended | you | [4](#4-storage) |
| Two LoadBalancer IPs (or Cilium L2 announcements) | | you, or the template with `loadBalancer.ciliumL2` | [5](#5-loadbalancer-ips-and-ports) |
| Argo CD | v3.6.1 (chart `argo-cd` 10.14.0) | you, one `helm install` in [Argo CD](argocd.md#3-install-argo-cd) | [6](#6-tools-on-your-computer) |
| Accounts: DNS, S3, mail, Git hosting | | you | [7](#7-accounts) |

Everything else (cert-manager, trust-manager, External Secrets Operator,
OpenBao, CloudNativePG, the Keycloak operator, Keycloak, Den and the
modules) is installed by the template.

"Validated" means the CI of the template renders every manifest and checks
it against the Kubernetes 1.37 API schemas, and the example k3s cluster
runs k3s v1.37.2+k3s1. Older Kubernetes versions are not checked.

## 1. Kubernetes and nodes

You need **at least 3 schedulable nodes**. PostgreSQL, OpenBao and Argo
CD's Redis each place their 3 copies on 3 different nodes, and refuse to
put two on the same node; with 2 nodes the third copy stays `Pending`.

Capacity for the default settings (all modules on, from
[Sizing and resources](sizing.md)):

| | Requested by the template | Recommended per node (3 nodes) |
| --- | --- | --- |
| CPU | about 4.2 cores | 4 cores |
| Memory | about 11.1 GiB | 16 GiB |
| Disk for volumes | 136 GiB of volumes (see [Storage](#4-storage)) | 150 GiB free for Longhorn, plus the operating system |

The recommendation leaves room for Kubernetes itself, Cilium, Longhorn,
CoreDNS and load peaks. Self-hosted CI runners need more; see
[Sizing](sizing.md#self-hosted-runners).

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

All nodes must be `Ready` and none may carry a `NoSchedule` taint:

```sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

```text
NAME     TAINTS
node-1   <none>
node-2   <none>
node-3   <none>
```

## 2. Cilium

Cilium must run with:

- `kubeProxyReplacement: true` (the Gateway needs it);
- `gatewayAPI.enabled: true`, which creates the GatewayClass `cilium`;
- `l7Proxy: true` (the default), because the Gateway is served by Envoy;
- `l2announcements.enabled: true` **only** if the template should hand out
  the Gateway IPs (`loadBalancer.ciliumL2.enabled` in `cluster.yaml`).

The example values are in `bootstrap/example-k3s/cilium-values.yaml` of the
template. The template's network policies use Cilium features (DNS-based
egress rules for S3), so another CNI is not supported.

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
`gateway-api-crd` add-on. On other clusters, install them **before**
Cilium (or restart the Cilium operator afterwards, so it creates the
GatewayClass):

```sh
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
```

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
recommended and used in the example; a cloud provider's replicated block
storage works too.

Volumes the template creates (default sizes, all changeable in
`cluster.yaml`):

| Volume | Count | Size each | Total |
| --- | --- | --- | --- |
| PostgreSQL data | 3 | 20 GiB | 60 GiB |
| PostgreSQL WAL (write-ahead log) | 3 | 10 GiB | 30 GiB |
| OpenBao data | 3 | 10 GiB | 30 GiB |
| OpenBao audit log | 3 | 5 GiB | 15 GiB |
| Wiki editing buffers | 1 | 1 GiB | 1 GiB |
| | | | **136 GiB** |

PostgreSQL and OpenBao copy their data to their other instances
themselves. On a storage layer that also keeps 3 copies, every byte is
stored 9 times. With Longhorn, set `storage.longhornSingle.enabled: true` in
`cluster.yaml`: the template creates the StorageClass `longhorn-single`
(one copy, on the pod's node) and uses it for PostgreSQL and OpenBao. The
136 GiB then need 136 GiB of disk; with the default 3-copy class they need
about 410 GiB.

Check:

```sh
kubectl get storageclass
```

```text
NAME                 PROVISIONER          RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
longhorn (default)   driver.longhorn.io   Delete          Immediate           true                   2d
```

Exactly one class must say `(default)`.

## 5. LoadBalancer IPs and ports

The template creates two Gateways, each a `Service` of type
`LoadBalancer`:

| Gateway | Serves | Reachable from |
| --- | --- | --- |
| `public` | Den, the modules, Keycloak | the internet: forward TCP 80 and 443 to it |
| `internal` | Argo CD, OpenBao, and optionally the Longhorn and Hubble UIs | your LAN or VPN only |

Something must give them addresses:

- **A cloud load balancer** or MetalLB: nothing to configure in the
  template; optionally pin addresses with `gateway.public.loadBalancerIP`
  and `gateway.internal.loadBalancerIP`.
- **Cilium L2 announcements** (bare metal, one shared LAN): set
  `loadBalancer.ciliumL2.enabled: true`, a free address range outside your
  router's DHCP range in `loadBalancer.ciliumL2.blocks`, and both
  `gateway.*.loadBalancerIP` inside it. Cilium needs
  `l2announcements.enabled: true`.

The cluster also needs **outbound** HTTPS to your S3 provider, Let's
Encrypt, your DNS provider's API, `ghcr.io` and the chart repositories.

## 6. Tools on your computer

| Tool | Version used in the guides | Used for |
| --- | --- | --- |
| `kubectl` | 1.36 or newer | everything |
| `helm` | 3.19 | installing Argo CD, `install-root.sh`, `openbao-seed.sh` |
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

## 7. Accounts

| Account | What for | Needed |
| --- | --- | --- |
| A domain and its DNS | `<app>.<domain>` records; DNS-01 challenges for the wildcard certificate | yes. Cloudflare is built in (an API token); any other provider works with your own cert-manager solver ([DNS and certificates](dns-and-certificates.md)) |
| A managed S3-compatible object storage | files of Den, Stash, Rally, Learn, Wiki and Tasks; database and Den backups | yes ([Data](data.md)) |
| An SMTP mail server | Keycloak's password-reset and verification mail; Learn's mail | yes by default; turn Keycloak mail off with `keycloak.smtp.enabled: false` |
| GitHub (or another Git host) | your private copy of the template, which Argo CD reads | yes |
| A GitHub App | self-hosted CI runners | only with `arc.enabled` ([Self-hosted CI runners](self-hosted-runners.md)) |

Credentials for these accounts go into OpenBao, never into Git; see
[Secrets](../operations/secrets.md).

## Troubleshooting

**`kubectl get gatewayclass cilium` says `NotFound`**
:   Cilium's Gateway API support is off, or the Gateway API CRDs were
    installed after Cilium. Check `gatewayAPI.enabled: true` in your Cilium
    values, then restart the operator:
    `kubectl -n kube-system rollout restart deploy/cilium-operator`.

**The GatewayClass is `ACCEPTED False` with `unsupported version`**
:   The Gateway API CRDs are older or newer than this Cilium release
    supports. Install v1.6.3 with the command in step 3 and restart the
    Cilium operator.

**Two StorageClasses say `(default)`**
:   For example k3s' `local-path` next to Longhorn. Remove the mark from the
    other one:
    `kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'`.

**A node shows a `NoSchedule` taint**
:   Control-plane nodes of kubeadm and many managed services are tainted.
    With only 3 nodes, all 3 must run workloads:
    `kubectl taint nodes <node> node-role.kubernetes.io/control-plane:NoSchedule-`.

Next: [Argo CD and cluster.yaml](argocd.md).
