# Kubernetes distributions

The template runs on any **conformant** Kubernetes cluster: one that passes
the official Kubernetes conformance tests, which k3s, kubeadm clusters,
Talos Linux and the managed cloud services all do. The charts and Argo CD
Applications are the same everywhere.

What differs is how you **prepare** the cluster so it meets the
[Prerequisites](prerequisites.md): which built-in parts you switch off, how
you install Cilium and Longhorn, and where CoreDNS is configured. This page
lists those differences. The project tests on k3s; the other sections are
guidance.

## At a glance

| | k3s | kubeadm ("plain" Kubernetes) | Talos Linux | Managed (EKS, AKS, GKE, ...) |
| --- | --- | --- | --- | --- |
| What it is | Kubernetes in one binary, with extras bundled | The reference installer from the Kubernetes project | An operating system that only runs Kubernetes; no SSH, configured through an API | The cloud provider runs the control plane |
| Built-in parts to switch off | Traefik, ServiceLB, flannel, local-path storage, network policy controller, kube-proxy | kube-proxy (if Cilium replaces it) | the default CNI (flannel) and kube-proxy | depends on the provider |
| Cilium | Install yourself, see [Example: a k3s cluster](cluster.md) | Install yourself | Install yourself, with Talos-specific settings (below) | Often only in chaining mode or as the provider's own "Dataplane V2"; check that Gateway API and `BackendTLSPolicy` work |
| Longhorn | Needs `open-iscsi` and `nfs-common` on every node | Same | Needs Talos system extensions and an extra kubelet mount (below) | Use the provider's replicated block storage instead |
| CoreDNS changes | ConfigMap `coredns-custom` in `kube-system` | Edit the `coredns` ConfigMap | Edit the `coredns` ConfigMap, or disable Talos' CoreDNS and run your own | Provider-specific |
| Load balancer IPs | Cilium LB IPAM + L2 announcements | Cilium LB IPAM + L2 or BGP | Cilium LB IPAM + L2 or BGP | The provider's load balancer |

## k3s

k3s bundles components that overlap with the reference stack. Turn them off
in `/etc/rancher/k3s/config.yaml` on every server **before** the first
start (changing them later means reinstalling the node):

```yaml
disable:
  - traefik
  - servicelb
  - local-storage
flannel-backend: none
disable-network-policy: true
disable-kube-proxy: true
```

Keep k3s' bundled Gateway API CRDs or install them yourself; see
[Prerequisites](prerequisites.md) for the version. The full, tested walk-through
is [Example: a k3s cluster](cluster.md).

For the sign-in address of Keycloak inside the cluster (see
[DNS and certificates](dns-and-certificates.md)), k3s reads extra CoreDNS
settings from the ConfigMap `coredns-custom`, which the template can manage
for you.

## kubeadm

A cluster built with `kubeadm` has no extras to remove. Initialise it
without kube-proxy so Cilium can replace it:

```sh
kubeadm init --skip-phases=addon/kube-proxy
```

Then install Cilium with the values in `bootstrap/example-k3s/cilium-values.yaml` and your API server
address (`k8sServiceHost`, `k8sServicePort`). Install Longhorn's node
requirements (`open-iscsi`, `nfs-common`) on every node.

CoreDNS reads its configuration from the ConfigMap `coredns` in
`kube-system`; there is no `coredns-custom`. Add the rewrite for the
Keycloak address there, or use split DNS (see
[DNS and certificates](dns-and-certificates.md)).

## Talos Linux

Talos has no shell and no package manager; everything is set in the
machine configuration (`talosctl`). The differences that matter here:

1. **No default CNI and no kube-proxy.** In the machine configuration:

    ```yaml
    cluster:
      network:
        cni:
          name: none
      proxy:
        disabled: true
    ```

2. **Cilium needs Talos-specific values**, because Talos mounts cgroups
   itself and restricts capabilities. Add these to the Cilium values from
   `bootstrap/example-k3s/cilium-values.yaml`:

    ```yaml
    ipam:
      mode: kubernetes
    kubeProxyReplacement: true
    k8sServiceHost: localhost   # KubePrism, Talos' local API server proxy
    k8sServicePort: 7445
    cgroup:
      autoMount:
        enabled: false
      hostRoot: /sys/fs/cgroup
    securityContext:
      capabilities:
        ciliumAgent: [CHOWN, KILL, NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN, SYS_RESOURCE, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
        cleanCiliumState: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]
    ```

    See the [Talos guide for Cilium](https://www.talos.dev/latest/kubernetes-guides/network/deploying-cilium/)
    for your Talos version.

3. **Longhorn needs system extensions and a mount.** Build your Talos image
   with the extensions `siderolabs/iscsi-tools` and
   `siderolabs/util-linux-tools` (with the
   [Image Factory](https://factory.talos.dev)), and give the kubelet access
   to Longhorn's data directory:

    ```yaml
    machine:
      kubelet:
        extraMounts:
          - destination: /var/lib/longhorn
            type: bind
            source: /var/lib/longhorn
            options: [bind, rshared, rw]
    ```

    The `longhorn-system` namespace needs the `privileged` Pod Security
    level. See [Longhorn on Talos](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/).

4. **Pod Security is on by default** (`baseline`). The template labels its
   own namespaces, so nothing to do for Con Services.

5. **CoreDNS:** edit the `coredns` ConfigMap as on kubeadm, or use split
   DNS.

## Managed Kubernetes

On EKS, AKS, GKE and similar services the provider runs the control plane,
and usually the network and storage too. Check before you start:

- **Gateway API with `BackendTLSPolicy`.** The template uses Cilium's
  Gateway. If your provider's network is not Cilium (or Cilium only in
  chaining mode, without its Gateway), you need another Gateway API
  implementation that supports `BackendTLSPolicy` with a CA from a
  ConfigMap, so the gateway verifies the apps' internal certificates. Do
  not fall back to unencrypted connections to the apps.
- **NetworkPolicies.** The charts render Cilium policies when Cilium is the
  network. Without Cilium, turn `networkPolicy.gateway.cilium` off and
  check that your network enforces plain NetworkPolicies.
- **Storage.** Use the provider's replicated block storage as the default
  StorageClass instead of Longhorn.
- **Load balancer.** The provider creates one for the Gateway; you do not
  need Cilium LB IPAM.
- **Managed PostgreSQL and object storage** are a good fit here; see
  [Data](data.md).

## Troubleshooting

**Cilium pods crash on Talos with `mount: permission denied` or cgroup errors**
: The Talos-specific values (step 2 above) are missing. Upgrade the Cilium
  release with them.

**Longhorn volumes stay `Attaching` on Talos**
: The `iscsi-tools` extension is missing from the node image or the kubelet
  mount is missing. Check with `talosctl get extensions -n <node-ip>`.

**On k3s, a second ingress or load balancer appears next to Cilium's**
: Traefik or ServiceLB is still enabled. Add them to `disable:` in the k3s
  configuration and restart k3s on every server.

**Pods cannot reach `https://auth.<domain>`, but browsers can**
: The address resolves to your public IP and the router does not send the
  traffic back in (no "hairpin NAT"). Use the CoreDNS rewrite for your
  distribution or split DNS; see [DNS and certificates](dns-and-certificates.md).
