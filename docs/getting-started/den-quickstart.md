# Run Den on Kubernetes

This tutorial takes you from an empty computer to a working **Den**, the Con
Services portal, running on a small Kubernetes cluster on your own computer.
At the end you sign in and see Den's admin console. Follow the steps in
order; every step tells you what you should see, so you always know whether
it worked.

It covers steps 1 to 3 of [How the platform starts](how-the-platform-starts.md):
the platform (sign-in server, database, file storage) and Den. Adding modules
such as Stash comes after.

Plan about 45 minutes the first time. Most of that is downloading.

!!! info "A local trial, not production"
    This is the local trial path. It runs the same images and the same way
    in (Cilium's Gateway API) as a production cluster, but on one computer,
    with public test passwords and file storage inside the cluster. To run
    Con Services for real, follow [Deploy with Argo CD](../deploy/index.md).

!!! tip "Copying commands"
    Every grey command box has a copy button in its top-right corner. Click
    it, then paste into your terminal with ++ctrl+v++ (Windows and Linux) or
    ++cmd+v++ (macOS). Where the commands differ per system, pick your system
    on the tabs above the box. Run every command from the `con-services`
    folder unless the step says otherwise.

!!! warning "Trial setup: public passwords"
    This tutorial uses passwords that are written in the repository and
    therefore public, stored as plain Kubernetes Secrets. That is fine on
    your own computer and nowhere else. A real installation keeps its
    secrets in a secret manager; see [Secrets](../operations/secrets.md).

## What you are building

**Kubernetes** runs programs in *containers* and keeps them running. A
**cluster** is a set of computers Kubernetes manages; here it is one
container on your computer, made by **kind** ("Kubernetes in Docker").
**kubectl** is the command-line tool you use to talk to it.

**Cilium** is the cluster's network plugin. It connects the containers,
enforces the network rules between them, and runs the **Gateway**: the
front door that receives every request for `*.conservices.test` and sends
it to the right app. Each app says which address it answers with an
**HTTPRoute**; this is the [Gateway API](../concepts/glossary.md#gateway-api),
the standard Kubernetes way in, and the same setup production clusters use.

You will start these parts, each in its own *namespace* (a named section of
the cluster):

| Namespace | What runs there |
| --- | --- |
| `kube-system` | Cilium, including the Gateway's proxy (Envoy) |
| `conservices-gateway` | The Gateway `public`, which holds the HTTPS certificate for `*.conservices.test` |
| `conservices-identity` | Keycloak, the sign-in server, at `https://auth.conservices.test` |
| `conservices-data` | PostgreSQL (database) and SeaweedFS, an S3-compatible file storage (service `s3`), for local use only |
| `conservices-den` | Den: its web app at `https://den.conservices.test`, its API and its operator |

The published Den images are pulled from the GitHub Container Registry,
pinned to an exact version (`1.0.0-1`). Nothing is built on your computer.

## Step 1: Install Docker

kind runs the cluster inside Docker, so you need Docker but **not** Docker
Desktop's own Kubernetes (leave it switched off).

=== "Windows"

    1. Install **Docker Desktop** from
       <https://www.docker.com/products/docker-desktop/>. Accept the default
       options (it uses WSL 2). Restart the computer if the installer asks.
    2. Start Docker Desktop and wait until it says *Engine running*.
    3. Open **Settings** (gear icon) → **Resources** and give it at least
       6 GB of memory if your computer has 16 GB.

=== "macOS"

    1. Install **Docker Desktop** from
       <https://www.docker.com/products/docker-desktop/>. Pick the build for
       your chip (Apple silicon or Intel).
    2. Start Docker Desktop and wait until it says *Engine running*.
    3. Open **Settings** → **Resources** and give it at least 6 GB of memory.

=== "Linux"

    Install Docker Engine from <https://docs.docker.com/engine/install/>
    and let your user run it without `sudo`:

    ```sh
    sudo usermod -aG docker "$USER"
    ```

    Log out and in again so the group change takes effect.

Check that Docker runs:

```sh
docker version --format "{{.Server.Version}}"
```

It prints a version number, for example `29.0.1`. An error such as
`Cannot connect to the Docker daemon` means Docker is not running yet.

## Step 2: Install kubectl, kind, Helm, Git and mkcert

- **kubectl** talks to the cluster.
- **kind** creates the cluster.
- **Helm** installs ready-made Kubernetes add-ons (Cilium and
  trust-manager).
- **Git** downloads the source code.
- **mkcert** makes a certificate your browser trusts, so the local addresses
  work over HTTPS (signing in requires it).

=== "Windows"

    Open **PowerShell** (Start menu → type *PowerShell*) and run:

    ```powershell
    winget install --id Kubernetes.kubectl -e
    winget install --id Kubernetes.kind -e
    winget install --id Helm.Helm -e
    winget install --id Git.Git -e
    winget install --id FiloSottile.mkcert -e
    ```

    Close PowerShell and open it again so it finds the new programs.

=== "macOS"

    With [Homebrew](https://brew.sh):

    ```sh
    brew install kubectl kind helm git mkcert nss
    ```

=== "Linux"

    Debian or Ubuntu, on an x86-64 computer (for ARM replace `amd64` with
    `arm64`):

    ```sh
    sudo apt install git mkcert libnss3-tools
    curl -fsSLo kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
    curl -fsSLo kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -m 0755 kind kubectl /usr/local/bin/ && rm kind kubectl
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    ```

Check that everything is there:

```sh
kubectl version --client
kind version
helm version
git --version
mkcert -version
```

Each command prints a version, for example `kind v0.33.0 go1.25.1 windows/amd64`
for kind. `not recognized` or `command not found` means the program is
missing, or (Windows) PowerShell was not reopened after installing it.

## Step 3: Download Con Services

Pick a place for it (your home folder is fine), then run:

```sh
git clone https://github.com/AGlElectronics/con-services.git
cd con-services
```

From now on, every command runs inside this `con-services` folder.

## Step 4: Create the cluster and install the add-ons

These add-ons are installed once per cluster.

### 4a: The cluster

The file `deploy/kubernetes/local-cluster/kind-config.yaml` describes a
one-node cluster without kind's default network plugin and without
kube-proxy (Cilium replaces both), and publishes the ports 80 and 443 of
the cluster on your computer.

```sh
kind create cluster --config deploy/kubernetes/local-cluster/kind-config.yaml
```

After a minute or two you should see:

```text
Creating cluster "conservices" ...
 ✓ Ensuring node image (kindest/node:v1.37.0) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-conservices"
```

The node is `NotReady` until Cilium runs (step 4c); that is expected.

### 4b: The Gateway API definitions

The Gateway API objects (`Gateway`, `HTTPRoute`, `BackendTLSPolicy`, …) are
not built into Kubernetes; install their definitions first, because Cilium
only switches its Gateway on when they exist:

```sh
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
```

You should see lines such as
`customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io serverside-applied`.

### 4c: Cilium

The settings for the trial are in
`deploy/kubernetes/local-cluster/cilium-values.yaml`: Cilium replaces
kube-proxy, the Gateway API is on, and the Gateway's proxy listens on the
node's ports 80 and 443 (a laptop has no load balancer).

```sh
helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium --version 1.20.4 -n kube-system -f deploy/kubernetes/local-cluster/cilium-values.yaml
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
kubectl get nodes
kubectl get gatewayclass
```

You should see `daemon set "cilium" successfully rolled out`, the node
`Ready`, and the GatewayClass `cilium` accepted:

```text
NAME                        STATUS   ROLES           AGE   VERSION
conservices-control-plane   Ready    control-plane   4m    v1.37.0

NAME     CONTROLLER                     ACCEPTED   AGE
cilium   io.cilium/gateway-controller   True       1m
```

If `kubectl get gatewayclass` says `No resources found`, Cilium started
before the definitions from step 4b existed; restart its operator with
`kubectl -n kube-system rollout restart deployment/cilium-operator` and
check again after a minute.

### 4d: cert-manager and trust-manager

Con Services encrypts the connections *inside* the cluster too (between
the Gateway, Den, the database, the sign-in server and so on).
**cert-manager** makes and renews the certificates for that, and
**trust-manager** hands every app the certificate authority it needs to
check them. More on [Internal TLS](../operations/internal-tls.md).

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.3/cert-manager.yaml
kubectl wait --namespace cert-manager --for=condition=Available deployment --all --timeout=180s
helm upgrade --install trust-manager oci://quay.io/jetstack/charts/trust-manager --namespace cert-manager --version v0.26.0 --wait
```

You should see three lines ending in `condition met`, and then from Helm:

```text
Release "trust-manager" does not exist. Installing it now.
...
STATUS: deployed
```

## Step 5: Make the local certificate and copy the sign-in setup

The example overlay (the folder with the settings for this trial,
`deploy/kubernetes/overlays/example`) needs a few local files in its
`local` folder. That folder is ignored by Git, so nothing private is ever
committed.

1. Let mkcert create its own certificate authority and trust it (it may ask
   for your password or show a security prompt; accept):

    ```sh
    mkcert -install
    ```

2. Create the certificate and copy the files:

    === "Windows"

        ```powershell
        $local = "deploy\kubernetes\overlays\example\local"
        New-Item -ItemType Directory -Force $local | Out-Null
        mkcert -cert-file "$local\tls.crt" -key-file "$local\tls.key" auth.conservices.test den.conservices.test stash.conservices.test "*.conservices.test"
        Copy-Item "$(mkcert -CAROOT)\rootCA.pem" $local
        Copy-Item infra\keycloak\realm-conservices.json $local
        Copy-Item -Recurse infra\keycloak\themes\conservices "$local\theme"
        ```

    === "macOS / Linux"

        ```sh
        local=deploy/kubernetes/overlays/example/local
        mkdir -p "$local"
        mkcert -cert-file "$local/tls.crt" -key-file "$local/tls.key" auth.conservices.test den.conservices.test stash.conservices.test "*.conservices.test"
        cp "$(mkcert -CAROOT)/rootCA.pem" "$local/"
        cp infra/keycloak/realm-conservices.json "$local/"
        cp -R infra/keycloak/themes/conservices "$local/theme"
        ```

    mkcert prints `The certificate is at "…tls.crt" and the key at "…tls.key"`.
    The Gateway presents this certificate to your browser.

!!! danger "Never share rootCA-key.pem"
    mkcert's own key stays in the folder shown by `mkcert -CAROOT`. Only the
    public `rootCA.pem` is copied. Anyone with the key could fake any website
    for your computer.

!!! note "How Den finds the sign-in server inside the cluster"
    Den checks every sign-in against `https://auth.conservices.test`. Your
    browser finds that address through the hosts file (step 6). Inside the
    cluster, the overlay points the name at the Service `keycloak-public`,
    which it gives the fixed address `10.96.0.100`
    (`den-backend-local.yaml` and `keycloak-local.yaml`). Nothing to do
    for you; production clusters use a DNS rewrite instead.

## Step 6: Add the local web addresses (one time only)

Your computer must know that the `*.conservices.test` addresses are on your
own computer. This needs administrator rights once.

=== "Windows"

    Start PowerShell **as administrator** (right-click → *Run as
    administrator*) and run:

    ```powershell
    Add-Content -Path "$env:windir\System32\drivers\etc\hosts" -Value "127.0.0.1 auth.conservices.test den.conservices.test stash.conservices.test"
    ```

=== "macOS / Linux"

    ```sh
    echo "127.0.0.1 auth.conservices.test den.conservices.test stash.conservices.test" | sudo tee -a /etc/hosts
    ```

## Step 7: Start everything

```sh
kubectl apply -k deploy/kubernetes/overlays/example
```

`-k` means "build this folder with Kustomize, then apply it". You should see
a list of created objects ending in lines like:

```text
namespace/conservices-data created
namespace/conservices-den created
namespace/conservices-gateway created
namespace/conservices-identity created
...
certificate.cert-manager.io/den-backend-tls created
certificate.cert-manager.io/keycloak-tls created
certificate.cert-manager.io/postgres-tls created
...
deployment.apps/den-backend created
deployment.apps/den-frontend created
deployment.apps/den-operator created
deployment.apps/keycloak created
deployment.apps/s3 created
statefulset.apps/postgres created
backendtlspolicy.gateway.networking.k8s.io/den-frontend created
backendtlspolicy.gateway.networking.k8s.io/keycloak-public created
gateway.gateway.networking.k8s.io/public created
httproute.gateway.networking.k8s.io/den created
httproute.gateway.networking.k8s.io/keycloak created
httproute.gateway.networking.k8s.io/public-https-redirect created
ciliumnetworkpolicy.cilium.io/den-web-from-gateway created
ciliumnetworkpolicy.cilium.io/keycloak-from-gateway created
networkpolicy.networking.k8s.io/default-deny created
...
```

## Step 8: Wait until everything runs

Watch the pods (the running programs) come up:

```sh
kubectl get pods -A -l app.kubernetes.io/part-of=conservices -w
```

The first start downloads the images, so this takes a few minutes. Keycloak
is the slowest (one to three minutes). While it starts, `den-backend` may
restart once or twice: Den refuses to start until it can reach the sign-in
server, and Kubernetes simply tries again. When everything is ready it looks
like this:

```text
NAMESPACE              NAME                            READY   STATUS    RESTARTS      AGE
conservices-data       postgres-0                      2/2     Running   0             4m
conservices-data       s3-7c9d8f6b5-8xk2p              1/1     Running   0             4m
conservices-den        den-backend-6d9c8b7f5d-x2kqp    1/1     Running   2 (90s ago)   4m
conservices-den        den-frontend-7b9f6c4d8-4hzvn    1/1     Running   0             4m
conservices-den        den-frontend-7b9f6c4d8-q8tml    1/1     Running   0             4m
conservices-den        den-operator-5c6f9d7b84-mn2rs   1/1     Running   0             4m
conservices-identity   keycloak-6f4d8b9c7-zt5wq        1/1     Running   0             4m
```

PostgreSQL shows `2/2`: it runs a small helper next to it that reloads its
certificate when cert-manager renews it.

!!! note "File storage in the trial"
    `s3` is [SeaweedFS](https://github.com/seaweedfs/seaweedfs), a small
    S3-compatible server that creates the trial's buckets when it starts.
    It is only a stand-in for a laptop; production uses a managed S3
    service (any S3-compatible service works: AWS S3, Hetzner Object
    Storage, Cloudflare R2, Backblaze B2, ...).

Every line must say `Running` with all containers ready (`1/1`, or `2/2` for
PostgreSQL). Press ++ctrl+c++ to stop watching. Pods may wait a few seconds
in `ContainerCreating` until cert-manager has written their certificate;
check that every certificate is ready with:

```sh
kubectl get certificate -A
```

Every line must say `True` under `READY`. Then check that the Gateway is
ready and has accepted the routes:

```sh
kubectl get gateway -n conservices-gateway
kubectl get httproute -A
```

```text
NAME     CLASS    ADDRESS      PROGRAMMED   AGE
public   cilium   172.18.0.2   True         3m

NAMESPACE              NAME                    HOSTNAMES                   AGE
conservices-den        den                     ["den.conservices.test"]    3m
conservices-gateway    public-https-redirect                               3m
conservices-identity   keycloak                ["auth.conservices.test"]   3m
```

`PROGRAMMED` must be `True`; the address is the kind node's and may differ.
If a line stays on `ImagePullBackOff`, `CrashLoopBackOff`, `Pending` or
`Init:Error`, see [Troubleshooting](troubleshooting.md).

Now ask Den whether it is healthy:

=== "Windows"

    ```powershell
    curl.exe https://den.conservices.test/api/health
    ```

=== "macOS / Linux"

    ```sh
    curl https://den.conservices.test/api/health
    ```

Expected answer:

```json
{"database":"ok","status":"ok","uptime_sec":95,"version":"1.0.0-1"}
```

## Step 9: Open Den and sign in

1. Open <https://den.conservices.test> in your browser. You should see a
   **Sign in** card with a **Continue with SSO** button, and no certificate
   warning. (Firefox on Windows: if it warns, open `about:config` and set
   `security.enterprise_roots.enabled` to `true`.)
2. Click **Continue with SSO**. The browser moves to
   `auth.conservices.test` and shows a login form titled **Con Services**.
3. Sign in with the built-in test administrator:

    | Username | Password |
    | --- | --- |
    | `admin` | `adminadmin` |

    !!! danger "Test account only"
        This account comes from the test realm in the repository and its
        password is public. Real installations use their own accounts.

## Step 10: Check that it worked

After signing in you land on the **portal home**
(`https://den.conservices.test/dashboard`). You should see:

- a big **Con Services** title and a greeting with your name;
- an **Admin console** button;
- a **Your services** section saying *No services are ready yet*. That is
  expected: no modules are added yet.

Click **Admin console**. The **Overview** shows *Paired modules* 0,
*Waiting to pair* 0, *Live on portal* 0 and *People in Den* 2 (a built-in
development user and you).

Open **Backups**. It lists the databases `den` and `keycloak` and says no
backup has been made yet. Click **Back up now**; after a few seconds the
backup shows up under *Stored backups*. This proves that Den, its operator,
the database and the file storage all work together.

**Den is running.** Next:

- add your first module: continue with
  [How the platform starts, step 4](how-the-platform-starts.md#step-4-deploy-a-module-stash);
- change the colours and logo under **Branding**
  ([admin guide](../modules/den/admin-guide.md#branding));
- read why the parts are separated the way they are:
  [Network policies](../operations/network-policies.md). Unlike Docker
  Desktop's built-in Kubernetes, this cluster enforces them (Cilium).

## Stopping, starting and cleaning up

**Pause:** quit Docker Desktop (Linux: stop Docker). The cluster stops and
all data stays. Start Docker again to continue; the cluster's container
starts with it and the pods come back by themselves. If
`kubectl get nodes` cannot connect, start it by hand with
`docker start conservices-control-plane`.

**Update to a newer version:** change `newTag` in
`deploy/kubernetes/overlays/example/kustomization.yaml`, read the changelog,
and run the apply command again. See
[Versions and upgrades](../operations/versioning.md).

**Remove Con Services but keep the cluster:**

```sh
kubectl delete -k deploy/kubernetes/overlays/example
kubectl delete namespace conservices-data conservices-den conservices-gateway conservices-identity --ignore-not-found
```

Deleting the namespaces also deletes the database and file storage volumes,
so **all data is gone**.

**Remove everything**, including the cluster:

```sh
kind delete cluster --name conservices
```

To undo the other changes, remove the line you added to the hosts file and
run `mkcert -uninstall`.

## Troubleshooting

The most common problems at each step, with the full fix on the
[Troubleshooting](troubleshooting.md) page:

| Step | You see | Go to |
| --- | --- | --- |
| 1 | `Cannot connect to the Docker daemon` or `error during connect` | Docker is not running: start Docker Desktop and wait for *Engine running*. |
| 4a | `failed to create cluster: … address already in use` or `port is already allocated` | Something else uses port 80 or 443 on your computer (IIS, Apache, another proxy, the Docker Compose stack's Caddy). Stop it, run `kind delete cluster --name conservices`, then 4a again. |
| 4a | `node(s) already exist for a cluster with the name "conservices"` | The cluster exists from an earlier try. Continue with 4b, or start over with `kind delete cluster --name conservices`. |
| 4c | Node stays `NotReady`, `cilium` pods in `CrashLoopBackOff` | [Cilium does not start](troubleshooting.md#cilium-does-not-start-on-the-kind-cluster) |
| 4c | `kubectl get gatewayclass` says `No resources found` | Restart the Cilium operator as described in step 4c. |
| 4d | `helm: command not found` or `not recognized` | Helm from step 2 is missing, or PowerShell was not reopened after installing it. |
| 7 | `no matches for kind "Certificate"`, `"Bundle"`, `"HTTPRoute"` or `"CiliumNetworkPolicy"` | An add-on from step 4 is missing; install it and apply again. |
| 7 | `error: … local/tls.crt: no such file or directory` | Step 5 was skipped or run from another folder; run it again from `con-services`. |
| 8 | Pods stay in `ContainerCreating`, `kubectl get certificate -A` shows `False` | [Internal TLS troubleshooting](../operations/internal-tls.md#troubleshooting) |
| 8 | `s3` stays `0/1` or restarts | [The s3 storage pod is not ready](troubleshooting.md#the-s3-storage-pod-is-not-ready) |
| 8 | Other pods in `ImagePullBackOff` | [ImagePullBackOff](troubleshooting.md#imagepullbackoff-or-errimagepull) |
| 8 | `Pending` | [A pod is Pending](troubleshooting.md#a-pod-is-pending) |
| 8 | `den-backend` in `CrashLoopBackOff` for more than five minutes | [CrashLoopBackOff](troubleshooting.md#crashloopbackoff) |
| 8 | `Init:Error` | [The migration step failed](troubleshooting.md#den-backend-stays-in-init-the-migration-step-failed) |
| 8 | Gateway `PROGRAMMED` stays `False` or `Unknown` | [The Gateway is not programmed](troubleshooting.md#the-gateway-is-not-programmed) |
| 9 | Certificate warning | [Certificate warnings](troubleshooting.md#certificate-warnings) |
| 9 | *This site can't be reached* | [The browser cannot open the page](troubleshooting.md#the-browser-cannot-open-the-page-at-all) |
| 9 | Back on **Sign in** after logging in | [Sign-in loops](troubleshooting.md#sign-in-loops-back-to-the-sign-in-page) |
| 10 | No **Admin console** button | [Signed in, but no Admin console](troubleshooting.md#signed-in-but-failed-to-load-your-services-or-no-admin-console) |
