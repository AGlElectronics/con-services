# Glossary

Short definitions of the words used in these docs, in alphabetical order.
Module-specific words (an *edition* in Rally, a *space* in Wiki) are listed
too, with a link to where they are explained.

**Access token**
:   A token Keycloak issues for calling APIs. Con Services web apps send the
    [ID token](#id-token) to their backend instead, because its audience is
    always the app's own client.

**ADR (architecture decision record)**
:   A short document recording an important design decision, why it was
    made and what it rules out. Den's are in
    [`docs/adr/`](https://github.com/AGlElectronics/den/tree/main/docs/adr);
    each module keeps its own.

**Admin console**
:   Den's administration area at `/admin`, for people with the `admin` or
    `owner` role.

**age**
:   The file encryption tool ([age-encryption.org](https://age-encryption.org))
    the operator uses for backups. A backup is encrypted for one or more
    *public keys* and can only be opened with a matching *secret key*.

**API (HTTP API, JSON API)**
:   The set of web addresses (endpoints) a module's backend answers, with
    JSON requests and responses. The rules all of them share are on
    [API conventions](api-conventions.md).

**API key (public API key)**
:   A secret that lets an outside system, such as a website or a signage
    screen, read Rally's public schedule. Created by staff in Rally and shown
    once. Not the same as a [service token](#service-token).

**Argo CD** { #argo-cd }
:   A [GitOps](#gitops) tool for Kubernetes. It watches a Git repository
    and keeps the cluster in line with what is written there: it installs
    the Helm charts and manifests, shows what differs, and undoes changes
    made by hand. Production Con Services clusters are managed with it; see
    [Deploy with Argo CD](../deploy/index.md).

**Asset (branding asset)**
:   An uploaded image with a *role*, such as `logo`, `favicon` or
    `login-background`. The newest upload per role is the one in use.

**Attendee realm**
:   The separate Keycloak realm `attendees`, used by Rally's public
    submission site. Attendee accounts never have staff access. See
    [Authentication](authentication.md#attendees-a-separate-realm).

**Audience (`aud`)**
:   The claim in a token that says which application the token is meant for.
    Each backend only accepts tokens whose audience is its own client.

**Audit event, audit log**
:   A record of something important that happened, who did it and when,
    such as a module being paired in Den or an item being signed out in
    Stash.

**Backend, frontend**
:   Each module has a *backend* (a Go program serving the API and talking to
    the database) and a *frontend* (an nginx container serving the web app
    in the browser and forwarding `/api/` to the backend).

**BackendTLSPolicy** { #backendtlspolicy }
:   A [Gateway API](#gateway-api) object that tells the Gateway to talk
    HTTPS to an app's Service and how to check the app's certificate: which
    CA to trust (Con Services: the ConfigMap `conservices-internal-ca`) and
    which name the certificate must carry (the Service's DNS name). See
    [Internal TLS](../operations/internal-tls.md#gateway-api-cilium).

**Bearer token**
:   A secret sent in the `Authorization: Bearer <token>` header. Whoever
    holds ("bears") it is allowed in, so it must be kept secret. ID tokens,
    module credentials, service tokens and API keys are all sent this way.

**Branding profile**
:   Den's brand as three JSON documents: `theme` (colours), `typography`
    (fonts) and `copy` (wording). Each save creates a new *revision*.

**Bucket**
:   A named container for files in S3-compatible storage. Each module has its
    own, and no module has credentials for another's.

**Build number**
:   The last part of an image tag such as `1.4.2-3`. It counts rebuilds of
    the same version and starts at `1` for each new version. See
    [Versions and upgrades](../operations/versioning.md).

**Bundle**
:   What a paired module fetches from Den every minute: the brand plus the
    organisation settings, in one response.

**Caddy**
:   The web server used as the HTTPS proxy of the Docker Compose
    development stack. On Kubernetes the [Gateway](#gateway-api) does this
    job.

**Call for papers (CfP)**
:   In Rally, an open invitation to submit talks, panels or workshops for an
    [edition](#edition). See [Rally](../modules/rally/index.md).

**cert-manager**
:   A Kubernetes add-on that creates TLS certificates from `Certificate`
    objects, stores them in Secrets and renews them before they expire.
    Con Services uses it for the public certificate and for the
    [internal CA](#internal-ca). See
    [Internal TLS](../operations/internal-tls.md).

**Changelog**
:   The `CHANGELOG.md` of each module, listing what changed in every release
    for operators and users. See [Changelogs](../contributing/changelog.md).

**Cilium**
:   An open-source network plugin (CNI) for Kubernetes that enforces network
    policies, encrypts traffic between nodes (WireGuard) and runs the
    [Gateway](#gateway-api) with its built-in Envoy proxy. The CNI of every
    Con Services cluster, from the local trial to production.

**Claim**
:   One piece of information inside a token, such as `sub`, `email` or
    `groups`.

**Cloudflare Tunnel** { #cloudflare-tunnel }
:   A way to publish web apps without a public IP or port forward: the
    program `cloudflared` runs in the cluster, keeps an outgoing connection
    to Cloudflare, and Cloudflare sends visitors' requests through it. See
    [DNS and certificates](../deploy/dns-and-certificates.md#cloudflare-tunnel-instead-of-a-port-forward).

**Client**
:   An application registered in a Keycloak realm. *Public* clients (the web
    apps, such as `den-spa`) cannot keep a secret and use PKCE.
    *Confidential* clients (such as `den-keycloak`) have a secret and act on
    their own behalf through a *service account*.

**CNI (network plugin)**
:   The part of a Kubernetes cluster that connects pods. Only some CNIs, such
    as Calico and Cilium, enforce network policies.

**Compose profile**
:   A label on services in `docker-compose.yml`, used in local development.
    `docker compose --profile den` switches on the services labelled `den`.

**ConfigMap / Secret**
:   Kubernetes objects holding settings. A ConfigMap holds plain settings; a
    Secret holds passwords and keys. Backends read both as environment
    variables.

**CORS (Cross-Origin Resource Sharing)**
:   The browser rule that a page may only call an API on another address if
    that API allows it. Configured per module with `CORS_ALLOWED_ORIGINS`.
    See [API conventions](api-conventions.md#cors).

**Den**
:   The Con Services portal and admin console, and the hub that paired
    modules follow.

**Den connection**
:   A module's settings page (and API) for pairing with Den, syncing and
    disconnecting. See
    [Pairing](pairing.md#the-den-connection-api-in-each-module).

**Department**
:   A team of the crew, such as Security or Registration. Kept in HR, which
    tells other modules (Tasks, for example) about it.

**Dev mode**
:   `AUTH_MODE=dev`. A backend trusts the `X-Dev-User` header instead of
    checking tokens. For local development only.

**Edition** { #edition }
:   In Rally, one occurrence of an event, such as "Example Con 2027". Calls
    for papers, rooms and the schedule belong to an edition.

**Endpoint**
:   One method and path of an API, such as `GET /api/v1/me`.

**Envelope (error envelope)**
:   The common JSON shape of every error,
    `{"error":{"code","message","details"}}`. See
    [API conventions](api-conventions.md#errors).

**External Secrets Operator (ESO)**
:   A Kubernetes add-on that copies secrets from a secret manager (Vault,
    AWS Secrets Manager, and others) into Kubernetes Secrets. The
    recommended way to deliver Con Services' secrets. See
    [Secrets](../operations/secrets.md).

**Gateway API, Gateway** { #gateway-api }
:   The standard Kubernetes way to bring web traffic into a cluster, the
    successor of [Ingress](#ingress). A **Gateway** is the entry point: it
    holds the public HTTPS certificate and listens on ports 80 and 443.
    Each app attaches an [HTTPRoute](#httproute) to it. Con Services uses
    Cilium's implementation (GatewayClass `cilium`) and two Gateways in the
    namespace `conservices-gateway`: `public` for the apps and sign-in, and
    `internal` for the admin tools, reachable only from your LAN or VPN.

**Git Bash** { #git-bash }
:   The bash shell that comes with Git for Windows
    (`C:\Program Files\Git\bin\bash.exe`). It can run the bash versions of
    the template's bootstrap scripts on Windows. Not the same as `bash` typed
    in PowerShell, which may start [WSL](#wsl) instead.

**GitOps** { #gitops }
:   Running a cluster from a Git repository: every setting, version and
    manifest is committed there, and a tool such as [Argo CD](#argo-cd)
    applies it. A change is a commit, and the history is the change log.
    Con Services' reference repository is `con-services-gitops`.

**Group**
:   A set of users in Keycloak, such as `den-admin`. Modules turn groups
    into roles.

**Health endpoints (`/livez`, `/readyz`, `/api/health`)**
:   Addresses that report whether a backend is alive and ready. See
    [API conventions](api-conventions.md#health-endpoints).

**Helm chart**
:   A packaged, configurable set of Kubernetes manifests, installed with
    `helm install`. Module charts are in `deploy/charts/`.

**Holdings**
:   In Learn, the qualifications a person currently holds. HR asks Learn for
    them before granting a role that requires training.

**HTTPRoute** { #httproute }
:   A [Gateway API](#gateway-api) object that says "requests for this host
    name (and path) go to this Service". Every Con Services web app has one,
    attached to the Gateway `public`.

**ID token** { #id-token }
:   A signed token from Keycloak describing the person who signed in. The
    web apps send it to their backend as a bearer token.

**Identity provider (IdP)**
:   The service that holds accounts and does the actual signing in. Locally,
    Keycloak.

**Image, image tag**
:   An image is the packaged program a container runs, for example
    `ghcr.io/aglelectronics/den-backend`. The tag after the colon picks the
    version: `ghcr.io/aglelectronics/den-backend:1.0.0-1`. Con Services
    never uses the tag `latest`.

**Ingress, ingress controller** { #ingress }
:   The older Kubernetes way in: an Ingress is a rule "requests for this
    host name go to this service", and an ingress controller (for example
    Traefik) is the web server that carries out those rules. Con Services
    uses the [Gateway API](#gateway-api) instead; the Helm charts can still
    render a plain Ingress (`ingress.enabled`) for clusters that only have a
    controller. ingress-nginx is no longer maintained; do not use it.

**initContainer**
:   A container that runs to completion before a pod's main container
    starts. Den uses one called `migrate` for its database migrations.

**Internal CA (internal certificate authority)** { #internal-ca }
:   Con Services' own certificate authority inside the cluster
    (`ClusterIssuer/conservices-internal-ca`). It signs the certificates
    that encrypt connections between pods; only Con Services' pods trust
    it, browsers do not. See [Internal TLS](../operations/internal-tls.md).

**Internal endpoint**
:   An endpoint under `/api/internal/...` that only another module may call,
    with a [service token](#service-token).

**Isolation**
:   The rule that every module has its own namespace, database, bucket,
    secrets and network policy. See
    [Design principles](design-principles.md#3-every-module-is-isolated).

**JIT provisioning (just-in-time)**
:   Creating a local user record the first time someone with a valid token
    calls a backend, instead of importing users in advance.

**JWT (JSON Web Token)**
:   The format of Keycloak's tokens: three base64 parts (header, claims,
    signature) separated by dots.

**Keycloak**
:   The open-source identity provider Con Services ships with.

**Keycloak sync**
:   Den pushing its brand into the Keycloak realm, so the sign-in page looks
    like the rest of the suite.

**kind**
:   "Kubernetes in Docker": a tool that runs a Kubernetes cluster inside
    Docker containers on your computer. The local trial uses it; see
    [Run Den on Kubernetes](../getting-started/den-quickstart.md).

**kubeconfig**
:   The file that tells `kubectl` and `helm` which cluster to talk to and how
    to log in. The default is `~/.kube/config`; the environment variable
    `KUBECONFIG` selects another file for the current terminal.

**kubectl**
:   The command-line tool for talking to a Kubernetes cluster.

**Kubernetes**
:   The system that runs Con Services' containers, restarts them when they
    fail and connects them to each other.

**Kustomize, overlay**
:   Kustomize is built into `kubectl` (`kubectl apply -k`). It combines a
    *base* set of manifests with an *overlay*, a folder holding only your
    changes: image tags, passwords, host names.

**LB IPAM** { #lb-ipam }
:   Cilium's *load balancer IP address management*: it gives each `Service`
    of type `LoadBalancer`, such as a [Gateway](#gateway-api), an address
    from a pool you define. Pin the addresses of the two Con Services
    Gateways; otherwise the order in which they get addresses is not fixed
    ([DNS and certificates](../deploy/dns-and-certificates.md#1-choose-the-gateway-ips)).

**Liveness probe, readiness probe**
:   Kubernetes' regular checks on a pod. A failing *liveness* probe
    (`/livez`) restarts the pod; a failing *readiness* probe (`/readyz`)
    only stops traffic to it until it recovers.

**Load balancer**
:   A network service that spreads incoming traffic over several servers,
    or gives a Service an address outside the cluster. On Con Services
    clusters, Cilium's [LB IPAM](#lb-ipam) gives the
    [Gateways](#gateway-api) their addresses.

**Managed database**
:   A module database the operator created for Den, and which Den may
    therefore also delete when the module is removed.

**Managed storage, managed S3**
:   S3-compatible object storage run by a provider. Required for
    production instead of SeaweedFS or any other storage inside the cluster.
    Any S3-compatible service works, for example AWS S3, Hetzner Object
    Storage, Cloudflare R2 or Backblaze B2.

**Manifest**
:   A YAML file describing Kubernetes objects. Con Services' Helm charts are
    in `deploy/charts/`, the local-trial Kustomize manifests in
    `deploy/kubernetes/`.

**Migration**
:   A numbered SQL file that changes a database's structure. Applied by a
    separate migration step (Den's `migrate` initContainer, the
    `den-migrate` service in Docker Compose) using
    [Goose](https://github.com/pressly/goose).

**Module**
:   One application of the suite: Den, HR, Rally, Stash, Finance, Learn,
    Wiki, Desk or Tasks. Each has its own repository, database and bucket.

**Module credential**
:   The long-lived secret a paired module uses to call Den's integration API.

**Namespace**
:   A named section of a Kubernetes cluster with its own objects, secrets
    and network policies. Each Con Services part has its own, such as
    `conservices-den`.

**NetworkPolicy**
:   A Kubernetes rule saying which pods may talk to which. Con Services
    denies everything by default and allows only the listed flows. See
    [Network policies](../operations/network-policies.md).

**OIDC (OpenID Connect)**
:   The standard sign-in protocol used between the apps and Keycloak.

**OIDC discovery**
:   How a backend learns Keycloak's addresses and public signing keys at
    start-up, from `<issuer>/.well-known/openid-configuration`.

**Offboarding, onboarding**
:   In HR, bringing a volunteer or staff member in (application, account,
    roles) and taking them out again (account removed, other modules told).

**Operator (`den-operator`)**
:   Den's internal service that holds the PostgreSQL administrator login,
    creates and drops module databases, and makes the encrypted backups.

**Organisation settings**
:   One JSON document of organisation-wide settings, kept in Den and passed
    to paired modules. Examples: `organization_name`, `org_email_domain`,
    `events_public_schedule`.

**Owner**
:   The highest role in Den. Set directly in the database and never changed
    by group sync.

**Pairing**
:   Connecting a module to Den with a one-time pairing URL. See
    [Pairing](pairing.md).

**Pairing URL / pairing token**
:   The one-time link Den shows when you click **Pair**. The token in it is
    valid for 15 minutes and can be used once.

**Password grant**
:   A Keycloak sign-in where a program sends a user name and password
    directly. Enabled in the local realm for `curl` examples only; must be
    off in production.

**Permission**
:   A single thing a role allows, such as `settings.manage` in Wiki.
    Modules check permissions, and roles bundle them.

**PKCE**
:   Proof Key for Code Exchange: an addition to the OIDC sign-in flow that
    protects apps running in the browser.

**Pod**
:   One running copy of a program in Kubernetes: one or more containers
    started together.

**Pod Security Standards**
:   Kubernetes' built-in levels of container hardening. Con Services
    namespaces enforce the strictest level, `restricted`.

**Portal**
:   Den's home page (`/dashboard`) for everyone with the `member` role: the
    organisation's services and to-dos in one place.

**Pre-drop backup**
:   The backup the operator makes of a module's database right before
    deleting it. Never deleted automatically.

**Programme, schedule**
:   In Rally, the timetable of an edition: which session is in which room
    when. Built by staff and optionally published to the public.

**Proposal**
:   A design that is agreed but not built yet. See
    [Proposals](../proposals/index.md).

**Protected database**
:   A database the operator refuses to drop: `postgres`, the templates and
    those in `PROTECTED_DATABASES` (by default `keycloak` and `den`).

**Qualification**
:   In Learn, proof that someone completed a training, such as a course
    certificate. HR can require one before granting a role.

**Realm**
:   A separate space in Keycloak with its own users, groups and clients. Con
    Services uses `conservices` for staff and `attendees` for Rally's public
    site.

**Replica**
:   One of several identical pods of a Deployment. Some Con Services parts
    must run as exactly one replica; see
    [Running on Kubernetes](../operations/running.md#scaling).

**Request ID (`X-Request-ID`)**
:   An ID on every response that matches the backend's log line for that
    request. Quote it when reporting a problem.

**Revision**
:   The version number of the branding profile. It increases by one on every
    save.

**Role**
:   What someone may do in a module. Den has `owner`, `admin` and `member`;
    other modules have their own.

**Role catalog**
:   The public list of roles a module understands, at `GET /api/role-catalog`.

**S3, S3-compatible storage**
:   Amazon's object storage protocol for files, also offered by Hetzner
    Object Storage, Cloudflare R2, Backblaze B2, SeaweedFS and others. Every
    module stores its files this way.

**Sealed Secrets, SOPS**
:   Two ways of keeping encrypted secrets in Git: Sealed Secrets decrypts
    them inside the cluster, SOPS encrypts files with your own keys.
    Alternatives to the External Secrets Operator.

**SeaweedFS** { #seaweedfs }
:   An open-source, S3-compatible file storage server. The Docker Compose
    stack and the Kubernetes local trial run it as the service `s3`
    (image `chrislusf/seaweedfs:4.52`, single-process `mini` mode), with
    example keys. Development and trials only, never production.

**Secret manager**
:   A service that stores secrets safely and hands them to applications,
    such as HashiCorp Vault or a cloud provider's secret store. Required for
    every real installation. See [Secrets](../operations/secrets.md).

**Semantic Versioning (SemVer)**
:   The `MAJOR.MINOR.PATCH` numbering rule: MAJOR for breaking changes,
    MINOR for new features, PATCH for fixes.

**Service DNS name**
:   The in-cluster address of a service, of the form
    `<service>.<namespace>.svc.cluster.local`.

**Service token** { #service-token }
:   A shared secret one module sends to another's internal endpoint, such as
    `WIKI_SERVICE_TOKEN`. The same value is configured on both sides.

**Share link**
:   In Wiki, a link that lets anyone read a page without an account, when
    public links are switched on.

**Slug**
:   A module's short, lowercase name, such as `hr` or `stash`. Rally's slug
    is `events`.

**Space**
:   In Wiki and Tasks, a container for pages or boards with its own access
    rules: private, per department or shared.

**SPA (single-page app)**
:   A web app that runs in the browser and talks to its backend's API. Each
    module's frontend is one; their Keycloak clients are named `<module>-spa`.

**Standalone**
:   A module running without Den, with its own settings and default look.

**Subject (`sub`)**
:   The permanent, unique id of a person in the identity provider.

**Sync wave**
:   A number on each [Argo CD](#argo-cd) Application. Argo CD installs lower
    waves first and starts a wave only when every earlier one is healthy, so
    a stuck infrastructure Application holds back everything after it. Den
    and the modules share the last wave. See
    [Argo CD and cluster.yaml](../deploy/argocd.md#6-watch-the-sync-waves).

**TLS (Transport Layer Security)**
:   The encryption behind `https://`. It also lets the client check that the
    server is who it claims to be, using a certificate. Con Services uses
    it for browsers (at the Gateway) and between pods
    ([Internal TLS](../operations/internal-tls.md)).

**trust-manager**
:   A companion add-on of cert-manager that copies a CA certificate into a
    ConfigMap in many namespaces. Con Services uses it to give every pod the
    [internal CA](#internal-ca).

**Upstream**
:   A system a module depends on, such as Keycloak or Den. `upstream_failed`
    and `unavailable` errors mean an upstream did not answer as expected.

**WSL (Windows Subsystem for Linux)** { #wsl }
:   Runs Linux distributions inside Windows. Typing `bash` in PowerShell
    often starts WSL rather than [Git Bash](#git-bash); with only Docker
    Desktop's `docker-desktop` distribution installed, that fails because it
    has no bash. The guides use PowerShell scripts or Git Bash instead.
