# Example: a k3s cluster

**Optional.** Skip this page if you already have a cluster that meets the
[Prerequisites](prerequisites.md). It shows one tested way to build such a
cluster from three empty Linux machines: k3s, Cilium and Longhorn. Other
distributions are covered in [Kubernetes distributions](distributions.md).

By the end you have:

- **k3s** v1.37.2+k3s1 on three server nodes with embedded etcd;
- **Cilium** 1.20.4: pod networking, kube-proxy replacement, WireGuard
  encryption between nodes, the Gateway API controller, and L2
  announcements for the Gateway IPs;
- **Longhorn** 1.13.0 as the replicated default StorageClass.

The files are in your copy of the template, under `bootstrap/example-k3s/`.
The examples use the node names `node-1` to `node-3` with the addresses
`10.0.0.11` to `10.0.0.13`; use your own.

## Terms used on this page

**k3s**
:   A small, certified Kubernetes distribution packaged as one binary.

**Server node**
:   A k3s node that runs the Kubernetes control plane (API server,
    scheduler, controllers) and a member of **etcd**, the cluster database.
    In this setup server nodes also run normal workloads.

**Agent (worker) node**
:   A k3s node that only runs workloads, no control plane.

**CNI**
:   Container Network Interface: the plug-in that gives pods their network.
    Without it, nodes stay `NotReady`.

**LB IPAM and L2 announcements**
:   Cilium gives Services of type `LoadBalancer` an IP from a pool and
    answers ARP requests for it on the LAN, so your router can reach it. No
    cloud load balancer or MetalLB needed. The template creates the pool
    when `loadBalancer.ciliumL2.enabled` is set.

More terms: [Glossary](../concepts/glossary.md).

## Requirements

| Per node | Minimum | Recommended |
| --- | --- | --- |
| CPU | 4 vCPU | 4 to 8 vCPU |
| Memory | 16 GiB | 16 to 32 GiB |
| System disk | 40 GiB | 60 GiB |
| Data disk for Longhorn (`/var/lib/longhorn`) | 100 GiB | 200 GiB or more, SSD |
| OS | Ubuntu 24.04 LTS or Debian 13, 64-bit (amd64 or arm64) | |
| Kernel | 5.10 or newer (WireGuard and eBPF for Cilium) | 6.x |

[Sizing and resources](sizing.md) explains where the numbers come from.

Network: all nodes in one LAN (same layer 2 segment), fixed IP addresses
(DHCP reservations are fine), and **two more free addresses** in that LAN
for the Gateways, outside your router's DHCP range.

### Choosing the node layout

**Recommended: three server nodes.** Every node runs the control plane, an
etcd member and workloads. Any one node can fail or be rebooted and the
cluster keeps working, including its API, because etcd keeps a majority (2
of 3).

**Also works: one server and two workers.** Fine for a trial, but the
single server is a **single point of failure** for the Kubernetes API: if
it is down, running pods keep running, but nothing can be changed,
rescheduled or healed. Do not taint the server: PostgreSQL, OpenBao and
Redis need all 3 nodes for their 3 members. Cilium cannot use `127.0.0.1`
for the API server on the workers; set `k8sServiceHost` in
`bootstrap/example-k3s/cilium-values.yaml` to the server's IP, and use
`bootstrap/example-k3s/agent.yaml` for the workers. Workers can only
become servers by reinstalling them.

!!! warning "Three VMs on one physical host"
    Three nodes protect you against one node (VM) failing, being upgraded or
    being restarted. When all three VMs run on the **same physical server**,
    that server, its disks and its power supply remain a single point of
    failure. Keep off-site backups no matter how many nodes you have; see
    [High availability](high-availability.md).

## 1. Prepare every node

Do this on **each** of the three machines.

1. Give each machine a fixed IP address and a unique hostname (`node-1`,
   `node-2`, `node-3`), and make sure the clocks are synchronised
   (`timedatectl` shows `System clock synchronized: yes`).
2. If you have a separate data disk, format it and mount it at
   `/var/lib/longhorn` (Longhorn's default data path):

    ```sh
    sudo mkfs.ext4 -L longhorn /dev/sdb          # your data disk
    sudo mkdir -p /var/lib/longhorn
    echo 'LABEL=longhorn /var/lib/longhorn ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
    sudo mount -a && df -h /var/lib/longhorn
    ```

3. Copy `bootstrap/example-k3s/node-prep.sh` to the node and run it:

    ```sh
    sudo bash node-prep.sh
    ```

    It installs `open-iscsi`, the NFS client and `cryptsetup`, enables
    `iscsid`, loads the kernel modules `iscsi_tcp`, `dm_crypt`, `wireguard`
    and the netfilter modules Cilium's Envoy needs (`xt_socket`,
    `xt_TPROXY`, ...), keeps `multipathd` away from Longhorn's disks, raises
    the inotify limits and turns swap off. Expected end of the output:

    ```text
    ==> Done. Check the node with Longhorn's preflight tool:
    ```

    A `WARNING: kernel module ... not available` line means your kernel
    lacks that module; install your distribution's full kernel package
    (for example `linux-image-generic` instead of a `-virtual` kernel).

4. Simplest: no host firewall between the nodes. If you run one, allow all
   traffic between the node IPs (Longhorn and the pod network use many
   ports), and at least TCP 6443 (Kubernetes API), TCP 2379-2380 (etcd),
   TCP 10250 (kubelet), UDP 51871 (Cilium WireGuard), TCP 4240 (Cilium
   health) and TCP 4244 (Hubble). Never open them to the internet.

## 2. Install k3s on the first server

The configuration lives in a file, not on the command line, so every node
uses the same flags.

1. Create the cluster join token once and keep it in your password manager
   (it lets a machine join the cluster; see [Secrets](../operations/secrets.md)):

    ```sh
    sudo install -d -m 755 /etc/rancher/k3s
    openssl rand -hex 32 | sudo tee /etc/rancher/k3s/cluster-token > /dev/null
    sudo chmod 600 /etc/rancher/k3s/cluster-token
    ```

2. Copy `bootstrap/example-k3s/server-first.yaml` to
   `/etc/rancher/k3s/config.yaml` and replace the addresses in `tls-san`
   with your three node IPs (and a DNS name for the API, if you have one):

    ```sh
    sudo install -m 600 server-first.yaml /etc/rancher/k3s/config.yaml
    sudo nano /etc/rancher/k3s/config.yaml
    ```

    What the file does: starts a new etcd cluster (`cluster-init`), turns
    off flannel, kube-proxy and the k3s network policy controller (Cilium
    replaces them), turns off Traefik, ServiceLB and local-path storage
    (replaced by the Cilium Gateway, Cilium LB IPAM and Longhorn), encrypts
    Secrets in etcd (`secrets-encryption: true`) and takes etcd snapshots
    every 6 hours. It keeps k3s' `gateway-api-crd` add-on, which installs
    the Gateway API CRDs v1.6.3 the template needs; since k3s 1.37 that
    add-on is separate from Traefik.

3. Install k3s:

    ```sh
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.2+k3s1 sh -s - server
    ```

4. Check it. The node is `NotReady` on purpose: there is no CNI yet.

    ```sh
    sudo k3s kubectl get nodes
    ```

    ```text
    NAME     STATUS     ROLES                       AGE   VERSION
    node-1   NotReady   control-plane,etcd,master   40s   v1.37.2+k3s1
    ```

5. Copy the kubeconfig to your computer and point it at the node:

    ```sh
    ssh node-1 sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/conservices.yaml
    sed -i 's/127.0.0.1/10.0.0.11/' ~/.kube/conservices.yaml   # the first server's IP
    chmod 600 ~/.kube/conservices.yaml
    export KUBECONFIG=~/.kube/conservices.yaml
    kubectl get nodes
    ```

    This file is a cluster-admin credential. Keep it private.

## 3. Install Cilium

Without a CNI no pod can start, so Cilium is installed with Helm first.

1. Install `helm` and the `cilium` CLI on your computer
   ([Helm install](https://helm.sh/docs/intro/install/),
   [Cilium CLI](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli)).
2. Check `bootstrap/example-k3s/cilium-values.yaml`. With three server
   nodes, `k8sServiceHost: 127.0.0.1` and `k8sServicePort: 6443` are right
   (every node runs an API server). With worker nodes, use the server's IP.
3. Install, from your copy of the template:

    ```sh
    helm repo add cilium https://helm.cilium.io
    helm install cilium cilium/cilium --version 1.20.4 -n kube-system \
      -f bootstrap/example-k3s/cilium-values.yaml
    cilium status --wait
    ```

    ```text
        /¯¯\
     /¯¯\__/¯¯\    Cilium:             OK
     \__/¯¯\__/    Operator:           OK
     /¯¯\__/¯¯\    Envoy DaemonSet:    OK
     \__/¯¯\__/    Hubble Relay:       OK
        \__/       ClusterMesh:        disabled
    ```

4. Now that pods have a network, k3s installs the Gateway API CRDs. Wait for
   them, then run the same Helm command as an **upgrade**: the chart creates
   the GatewayClass `cilium` only when the CRDs exist. Restart the operator
   so it starts its Gateway controller:

    ```sh
    kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=5m
    helm upgrade cilium cilium/cilium --version 1.20.4 -n kube-system \
      -f bootstrap/example-k3s/cilium-values.yaml
    kubectl -n kube-system rollout restart deployment/cilium-operator
    kubectl get gatewayclass
    ```

    ```text
    NAME     CONTROLLER                     ACCEPTED   AGE
    cilium   io.cilium/gateway-controller   True       30s
    ```

5. The node is now `Ready`: `kubectl get nodes`.

What the values do: kube-proxy replacement; pod IPs from the per-node
ranges k3s assigns from `10.42.0.0/16` (`ipam.mode: kubernetes`); native
routing (all nodes share one LAN); WireGuard encryption of pod and node
traffic; the Gateway API controller with its Envoy DaemonSet; L2
announcements with a higher Kubernetes client rate limit (each announced
IP holds a Lease); Hubble with its relay and UI; two operator replicas.

Cilium stays outside Argo CD: it is the network of every pod, Argo CD
included, so upgrade it by hand with the same `helm upgrade` command and a
new `--version`, one minor version at a time, after reading the
[Cilium upgrade notes](https://docs.cilium.io/en/stable/operations/upgrade/).

## 4. Join the other two servers

On the second and third node:

1. Copy `/etc/rancher/k3s/cluster-token` from the first server (same path,
   mode 600).
2. Copy `bootstrap/example-k3s/server-join.yaml` to
   `/etc/rancher/k3s/config.yaml`; `server:` points to the first server
   (`https://10.0.0.11:6443`), `tls-san` is the same list.
3. Install:

    ```sh
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.2+k3s1 sh -s - server
    ```

4. From your computer:

    ```sh
    kubectl get nodes
    ```

    ```text
    NAME     STATUS   ROLES                       AGE   VERSION
    node-1   Ready    control-plane,etcd,master   15m   v1.37.2+k3s1
    node-2   Ready    control-plane,etcd,master   2m    v1.37.2+k3s1
    node-3   Ready    control-plane,etcd,master   1m    v1.37.2+k3s1
    ```

Cilium's DaemonSet starts on the new nodes by itself. Check the network
(optional, about 10 minutes, creates a test namespace):

```sh
cilium connectivity test
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
```

```text
✅ [cilium-test-1] All 70 tests (500 actions) successful, 0 tests skipped, 0 scenarios skipped.
Encryption: Wireguard
Interface: cilium_wg0
	Number of peers: 2
```

## 5. Install Longhorn

1. Check the nodes with Longhorn's CLI (it starts a short-lived DaemonSet):

    ```sh
    curl -fsSL -o longhornctl https://github.com/longhorn/cli/releases/download/v1.13.0/longhornctl-linux-amd64
    chmod +x longhornctl
    ./longhornctl check preflight --kubeconfig ~/.kube/conservices.yaml
    ```

    Every node should report `iscsid`, `nfs`, `cryptsetup` and the kernel
    modules as passed. `./longhornctl install preflight` can install
    missing packages for you.

2. Install Longhorn with the example values:

    ```sh
    kubectl create namespace longhorn-system
    kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged
    helm repo add longhorn https://charts.longhorn.io
    helm install longhorn longhorn/longhorn --version 1.13.0 -n longhorn-system \
      -f bootstrap/example-k3s/longhorn-values.yaml
    kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer
    kubectl get storageclass
    ```

    ```text
    deployment "longhorn-driver-deployer" successfully rolled out
    NAME                 PROVISIONER          RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
    longhorn (default)   driver.longhorn.io   Delete          Immediate           true                   1m
    ```

3. In `cluster.yaml`, set `storage.longhornSingle.enabled: true`. The
   template then creates the class `longhorn-single` (one copy, on the
   pod's node) for PostgreSQL and OpenBao, which replicate their data
   themselves, so it is not stored 3 × 3 times. Optionally set
   `adminRoutes.longhorn: true` for the Longhorn UI on
   `longhorn.<domain>` (internal Gateway; the UI has **no login**).

**Replica counts.** The default class `longhorn` keeps 3 copies of each
volume, one per node. With only two nodes that can store data, set
`persistence.defaultClassReplicaCount` and
`defaultSettings.defaultReplicaCount` to 2 in `longhorn-values.yaml`, or
every volume stays `Degraded`.

**Backups.** Longhorn snapshots live on the same disks. Configure an
off-cluster backup target (`defaultBackupStore` in `longhorn-values.yaml`,
an S3 bucket at another provider or NFS on another machine). The
template's own data (PostgreSQL, Den) is backed up to S3 independently
([Data](data.md#backups)).

## 6. Continue with the template

Your cluster now meets the [Prerequisites](prerequisites.md). For the
template's `cluster.yaml`:

```yaml
loadBalancer:
  ciliumL2:
    enabled: true
    blocks: ["10.0.0.240/29"]     # free addresses outside your DHCP range
gateway:
  public:
    loadBalancerIP: 10.0.0.240
  internal:
    loadBalancerIP: 10.0.0.241
oidcHairpin:
  mode: coredns-custom
storage:
  longhornSingle:
    enabled: true
```

Then follow [Argo CD and cluster.yaml](argocd.md).

## Hardening: protect-kernel-defaults

k3s can refuse to start when kernel settings differ from what the kubelet
expects (`protect-kernel-defaults: true`, recommended by the CIS
benchmark). It is off in the example files. To turn it on, first set the
sysctls on every node:

```sh
cat <<'EOF' | sudo tee /etc/sysctl.d/90-kubelet.conf
vm.panic_on_oom = 0
vm.overcommit_memory = 1
kernel.panic = 10
kernel.panic_on_oops = 1
EOF
sudo sysctl --system
```

then add `protect-kernel-defaults: true` to `/etc/rancher/k3s/config.yaml`
on every node and restart k3s, one node at a time
(`sudo systemctl restart k3s`).

## Back up etcd

k3s writes etcd snapshots to `/var/lib/rancher/k3s/server/db/snapshots`
every 6 hours (28 kept). They contain every Kubernetes object, including
Secrets (encrypted with the k3s secrets-encryption key in
`/var/lib/rancher/k3s/server/cred/`). Copy both off the host regularly, or
configure k3s' built-in S3 upload (`etcd-s3: true` and the `etcd-s3-*`
options). Take one by hand before upgrades:

```sh
sudo k3s etcd-snapshot save --name before-upgrade
```

## Troubleshooting

**Nodes stay `NotReady` after installing k3s**
:   Expected until Cilium is installed (step 3): k3s runs without a CNI.
    `kubectl describe node` shows `network plugin is not ready: cni config uninitialized`.

**Cilium pods crash with `unable to contact k8s api-server` or `dial tcp 127.0.0.1:6443: connect: connection refused`**
:   `k8sServiceHost` is wrong for that node. `127.0.0.1` only works on
    server nodes; on worker nodes use the server's IP. Fix
    `cilium-values.yaml` and run the `helm upgrade` again.

**`kubectl get gatewayclass` shows nothing**
:   The Gateway API CRDs appeared after Cilium was installed. Run step 3.4
    again. If the CRDs are missing entirely, check the add-on:
    `kubectl -n kube-system get pods | grep gateway-api-crd` should show a
    `Completed` pod, and `gateway-api-crd` must not be in the `disable:`
    list of the k3s config.

**The second server fails to join with `critical configuration value mismatch`**
:   Its `/etc/rancher/k3s/config.yaml` differs from the first server's in a
    cluster-wide setting (`cluster-cidr`, `service-cidr`,
    `flannel-backend`, `disable-*`, `secrets-encryption`). Use the same
    values, run `sudo /usr/local/bin/k3s-uninstall.sh` on the failed node
    and install again.

**`cilium-dbg encrypt status` shows `Encryption: Disabled` or Cilium logs `wireguard: module not found`**
:   The `wireguard` kernel module is missing; see the warning in step 1.3.

**A Gateway IP does not answer from the LAN**
:   Check that the Service got the IP (`kubectl get svc -A | grep LoadBalancer`),
    that the IP is inside `loadBalancer.ciliumL2.blocks` and **outside your
    router's DHCP range**, and which node announces it:
    `kubectl -n kube-system get lease | grep cilium-l2announce`. Some
    devices cache ARP answers for minutes after a failover; `arp -d <ip>`
    on the client helps.

**Gateway connections time out although the IP answers ARP**
:   Envoy is reached through TPROXY, which needs the netfilter modules
    loaded by `node-prep.sh` (`xt_socket`, `xt_TPROXY`, `nf_tproxy_ipv4`).
    Run `lsmod | grep -E 'xt_socket|tproxy'` on each node.

**Longhorn volumes fail to attach with `iscsiadm: not found` or stay `Attaching`**
:   `open-iscsi` is missing or `iscsid` is not running on that node:
    `systemctl status iscsid`. Run `node-prep.sh` again and
    `longhornctl check preflight`.

**Longhorn mounts fail with `already mounted or mount point busy`**
:   `multipathd` claimed the Longhorn device. `node-prep.sh` blacklists
    `sd*` devices; restart `multipathd` or disable it
    (`sudo systemctl disable --now multipathd multipathd.socket`) if you do
    not use multipath storage.

**Two nodes are down and `kubectl` hangs**
:   etcd lost its majority (it needs 2 of 3). Bring a node back. If they
    are gone for good, restore from a snapshot on the remaining server:
    `sudo k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>`
    ([k3s docs](https://docs.k3s.io/datastore/backup-restore)).

Next: [Argo CD and cluster.yaml](argocd.md).
