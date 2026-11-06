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
**cluster** is a set of computers Kubernetes manages; here it is just your
computer. **kubectl** is the command-line tool you use to talk to it.

You will start these parts, each in its own *namespace* (a named section of
the cluster):

| Namespace | What runs there |
| --- | --- |
| `conservices-identity` | Keycloak, the sign-in server, at `https://auth.conservices.test` |
| `conservices-data` | PostgreSQL (database) and MinIO (file storage), for local use only |
| `conservices-den` | Den: its web app at `https://den.conservices.test`, its API and its operator |
| `ingress-nginx` | The **ingress controller**: the front door that sends each web address to the right app |

The published Den images are pulled from the GitHub Container Registry,
pinned to an exact version (`1.0.0-1`). Nothing is built on your computer.

## Step 1: Install Docker Desktop and turn on Kubernetes

=== "Windows"

    1. Install **Docker Desktop** from
       <https://www.docker.com/products/docker-desktop/>. Accept the default
       options. Restart the computer if the installer asks.
    2. Start Docker Desktop and wait until it says *Engine running*.
    3. Open **Settings** (gear icon) → **Kubernetes**, tick **Enable
       Kubernetes**, keep the default cluster type, click **Apply &
       restart** and confirm the install.
    4. Wait until the bottom-left corner shows **Kubernetes running** (a
       few minutes).

=== "macOS"

    1. Install **Docker Desktop** from
       <https://www.docker.com/products/docker-desktop/>. Pick the build for
       your chip (Apple silicon or Intel).
    2. Start Docker Desktop and wait until it says *Engine running*.
    3. Open **Settings** → **Kubernetes**, tick **Enable Kubernetes**, keep
       the default cluster type, click **Apply & restart**.
    4. Wait until it shows **Kubernetes running**.

=== "Linux"

    Docker Desktop for Linux works the same way as on Windows and macOS:
    install it from <https://docs.docker.com/desktop/setup/install/linux/>,
    then **Settings** → **Kubernetes** → **Enable Kubernetes**.

!!! note "Other local clusters"
    [kind](https://kind.sigs.k8s.io/) and [k3d](https://k3d.io/) work too.
    The difference is how web traffic reaches the cluster: follow their
    "ingress" guide so that ports 80 and 443 on your computer reach the
    ingress controller, then continue with step 3 (skip step 4's install
    command if your cluster already has an ingress controller, and adjust
    the namespace name in the NetworkPolicies if it is not `ingress-nginx`).

## Step 2: Install kubectl, Git and mkcert

- **kubectl** comes with Docker Desktop.
- **Git** downloads the source code.
- **mkcert** makes a certificate your browser trusts, so the local addresses
  work over HTTPS (signing in requires it).

=== "Windows"

    Open **PowerShell** (Start menu → type *PowerShell*) and run:

    ```powershell
    winget install --id Git.Git -e
    winget install --id FiloSottile.mkcert -e
    ```

    Close PowerShell and open it again so it finds the new programs.

=== "macOS"

    With [Homebrew](https://brew.sh):

    ```sh
    brew install git mkcert nss
    ```

=== "Linux"

    Debian or Ubuntu:

    ```sh
    sudo apt install git mkcert libnss3-tools
    ```

Check that everything is there and that kubectl can see your cluster:

```sh
kubectl version --client
git --version
mkcert -version
kubectl get nodes
```

The last command should list one node with status `Ready`:

```text
NAME             STATUS   ROLES           AGE   VERSION
docker-desktop   Ready    control-plane   5m    v1.34.1
```

If it says `Unable to connect to the server`, Kubernetes is not running yet;
see [Troubleshooting](troubleshooting.md#kubectl-cannot-connect-to-the-cluster).

## Step 3: Download Con Services

Pick a place for it (your home folder is fine), then run:

```sh
git clone https://github.com/AGlElectronics/con-services.git
cd con-services
```

From now on, every command runs inside this `con-services` folder.

## Step 4: Install the ingress controller

The ingress controller receives every request for `*.conservices.test` and
passes it to the right app. Install it once per cluster:

```sh
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s
```

You should see, after up to a minute:

```text
pod/ingress-nginx-controller-5d8f9c7b6-r2xkq condition met
```

!!! note "About ingress-nginx"
    The ingress-nginx project stopped active development in 2026. It still
    works for a local trial. The manifests only use standard Kubernetes
    `Ingress` objects, so in production you can use another controller; see
    [Running on Kubernetes](../operations/running.md#the-ingress-controller).

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

!!! danger "Never share rootCA-key.pem"
    mkcert's own key stays in the folder shown by `mkcert -CAROOT`. Only the
    public `rootCA.pem` is copied. Anyone with the key could fake any website
    for your computer.

## Step 6: Tell Den where the sign-in server is inside the cluster

Den checks every sign-in against `https://auth.conservices.test`. Your
browser finds that address through your computer's hosts file (step 7), but
programs *inside* the cluster need to be told too. The overlay file
`den-backend-local.yaml` points the name at the ingress controller; it needs
your ingress controller's internal address (its *ClusterIP*):

=== "Windows"

    ```powershell
    $ip = kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath="{.spec.clusterIP}"
    $file = "deploy\kubernetes\overlays\example\den-backend-local.yaml"
    (Get-Content $file) -replace '10\.96\.0\.100', $ip | Set-Content $file
    Select-String -Path $file -Pattern "ip:"
    ```

=== "macOS / Linux"

    ```sh
    ip=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath="{.spec.clusterIP}")
    file=deploy/kubernetes/overlays/example/den-backend-local.yaml
    sed -i.bak "s/10\.96\.0\.100/$ip/" "$file" && rm "$file.bak"
    grep "ip:" "$file"
    ```

The last line should show your address, for example
`- ip: "10.104.211.37" # CHANGE ME: ingress controller ClusterIP`.

## Step 7: Add the local web addresses (one time only)

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

## Step 8: Start everything

```sh
kubectl apply -k deploy/kubernetes/overlays/example
```

`-k` means "build this folder with Kustomize, then apply it". You should see
a list of created objects ending in lines like:

```text
namespace/conservices-data created
namespace/conservices-den created
namespace/conservices-identity created
...
deployment.apps/den-backend created
deployment.apps/den-frontend created
deployment.apps/den-operator created
deployment.apps/keycloak created
deployment.apps/minio created
statefulset.apps/postgres created
ingress.networking.k8s.io/den created
ingress.networking.k8s.io/keycloak created
networkpolicy.networking.k8s.io/default-deny created
...
```

## Step 9: Wait until everything runs

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
conservices-data       minio-7c9d8f6b5-8xk2p           1/1     Running   0             4m
conservices-data       postgres-0                      1/1     Running   0             4m
conservices-den        den-backend-6d9c8b7f5d-x2kqp    1/1     Running   2 (90s ago)   4m
conservices-den        den-frontend-7b9f6c4d8-4hzvn    1/1     Running   0             4m
conservices-den        den-frontend-7b9f6c4d8-q8tml    1/1     Running   0             4m
conservices-den        den-operator-5c6f9d7b84-mn2rs   1/1     Running   0             4m
conservices-identity   keycloak-6f4d8b9c7-zt5wq        1/1     Running   0             4m
```

Every line must say `1/1` and `Running`. Press ++ctrl+c++ to stop watching.
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

## Step 10: Open Den and sign in

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

## Step 11: Check that it worked

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
  [Network policies](../operations/network-policies.md).

## Stopping, starting and cleaning up

**Pause:** quit Docker Desktop. The cluster stops and all data stays. Start
Docker Desktop again to continue; the pods come back by themselves.

**Update to a newer version:** change `newTag` in
`deploy/kubernetes/overlays/example/kustomization.yaml`, read the changelog,
and run the apply command again. See
[Versions and upgrades](../operations/versioning.md).

**Remove Con Services but keep the cluster:**

```sh
kubectl delete -k deploy/kubernetes/overlays/example
kubectl delete namespace conservices-data conservices-den conservices-identity --ignore-not-found
```

Deleting the namespaces also deletes the database and file storage volumes,
so **all data is gone**.

**Remove everything**, including the ingress controller: Docker Desktop →
**Settings → Kubernetes → Reset Kubernetes Cluster**. To undo the other
changes, remove the line you added to the hosts file and run
`mkcert -uninstall`.

## Troubleshooting

The most common problems at each step, with the full fix on the
[Troubleshooting](troubleshooting.md) page:

| Step | You see | Go to |
| --- | --- | --- |
| 2 | `Unable to connect to the server` | [kubectl cannot connect](troubleshooting.md#kubectl-cannot-connect-to-the-cluster) |
| 4 | `kubectl wait` times out | The controller is still pulling its image; run `kubectl get pods -n ingress-nginx` and wait. If `EXTERNAL-IP` of `kubectl get svc -n ingress-nginx` stays `<pending>` on kind or k3d, follow their ingress guide. |
| 8 | `error: … local/tls.crt: no such file or directory` | Step 5 was skipped or run from another folder; run it again from `con-services`. |
| 9 | `ImagePullBackOff` | [ImagePullBackOff](troubleshooting.md#imagepullbackoff-or-errimagepull) |
| 9 | `Pending` | [A pod is Pending](troubleshooting.md#a-pod-is-pending) |
| 9 | `den-backend` in `CrashLoopBackOff` for more than five minutes | [CrashLoopBackOff](troubleshooting.md#crashloopbackoff); usually the IP from step 6 |
| 9 | `Init:Error` | [The migration step failed](troubleshooting.md#den-backend-stays-in-init-the-migration-step-failed) |
| 10 | Certificate warning | [Certificate warnings](troubleshooting.md#certificate-warnings) |
| 10 | *This site can't be reached* | [The browser cannot open the page](troubleshooting.md#the-browser-cannot-open-the-page-at-all) |
| 10 | Back on **Sign in** after logging in | [Sign-in loops](troubleshooting.md#sign-in-loops-back-to-the-sign-in-page) |
| 11 | No **Admin console** button | [Signed in, but no Admin console](troubleshooting.md#signed-in-but-failed-to-load-your-services-or-no-admin-console) |
