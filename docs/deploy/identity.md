# Identity: Keycloak

Con Services signs people in with [Keycloak](https://www.keycloak.org), an
identity provider that speaks **OIDC** (OpenID Connect, the sign-in protocol
every module uses; see the [glossary](../concepts/glossary.md)). In the
cluster, the **Keycloak Operator** runs Keycloak: you describe the server and
its realms as Kubernetes objects, and the operator creates and updates them.
A **realm** is a separate set of users, groups and applications inside one
Keycloak.

**You need:** [Data](data.md) done, so PostgreSQL (`conservices-pg`) is
healthy and the database `keycloak` exists.

**You are done when:** `https://auth.example.org/realms/conservices` answers
in a browser, you can sign in to the admin console with your own admin
account, and the temporary bootstrap admin is deleted.

Throughout this page, `example.org` stands for your domain. Secrets
(client secrets, SMTP password, admin password) live in OpenBao, never in
Git; the full list is on [Secrets](../operations/secrets.md).

## What runs

| Piece | Where | Argo CD Application (sync wave) |
| --- | --- | --- |
| Keycloak Operator 26.8.2 (CRDs, RBAC, Deployment) | `components/keycloak-operator`, namespace `conservices-identity` | `keycloak-operator` (2) |
| Keycloak 26.8.2, 2 instances | chart `charts/keycloak`: the Keycloak resource, hostnames, routes, realm imports and theme | `keycloak` (4) |

The root chart passes `domain`, `keycloak.host`, `keycloak.adminHost`,
`keycloak.instances`, `keycloak.resources`, `keycloak.smtp.enabled`, the
host names of Den and the modules (for the clients' redirect URIs) and the
[profile](sizing.md#small-profile) from `cluster.yaml` to
`charts/keycloak`.

- **High availability:** 2 instances (`keycloak.instances`) on different
  nodes, with a PodDisruptionBudget. With `profile: small` the default is
  1 instance, allowed on any node, without a PodDisruptionBudget. They share
  sessions and caches (Infinispan) and find each other through the
  database, so one instance can fail without signing anyone out.
- **Database:** `jdbc:postgresql://conservices-pg-rw...:5432/keycloak` with
  `sslmode=verify-full` against the internal CA. The password comes from
  OpenBao `conservices/infra/postgres/roles/keycloak`.
- **TLS everywhere:** Keycloak serves HTTPS only (port 8443) with a
  certificate from the internal CA (`keycloak-tls`). The Gateway
  terminates public TLS and re-encrypts to Keycloak, checking that
  certificate with a `BackendTLSPolicy` against the `conservices-internal-ca`
  ConfigMap.
- **Hostnames** (the first label is `keycloak.host`, default `auth`, and
  `keycloak.adminHost`, default `auth-admin`; see
  [Changing a host name](#changing-a-host-name)):
    - `https://auth.example.org`: public sign-in. Only `/realms/` and
      `/resources/` are routed on the public Gateway; the admin console,
      `/metrics` and `/health` are not reachable from the internet.
    - `https://auth-admin.example.org`: the admin console, on the
      **internal** Gateway only (your LAN or VPN).
- **Services:** `keycloak` (port 8443, used by Den's backend for the admin
  API) and `keycloak-public` (443 → 8443). Inside the cluster, CoreDNS
  answers `auth.example.org` with `keycloak-public`, so backends check
  tokens without leaving the cluster. That CoreDNS rewrite is part of the
  cluster, not the template; see
  [DNS and certificates](dns-and-certificates.md#inside-the-cluster-reaching-keycloak).
- **Network policies** (`charts/keycloak/templates/networkpolicies.yaml`):
  ingress on 8443 only from the Gateway, Den and the module namespaces;
  the instances talk to each other on 7800 and 57800; egress to
  PostgreSQL, DNS and SMTP (587 and 465). The Keycloak Operator's own
  policies (egress to the Kubernetes API and to the Keycloak pods) are in
  `components/keycloak-operator/networkpolicies.yaml` and come with the
  operator in wave 2, so the operator can start before Keycloak exists.

## The realms

Two realms are imported when Keycloak first starts:

| Realm | For | Clients |
| --- | --- | --- |
| `conservices` | staff and volunteers | `den-spa`, `stash-spa`, `hr-spa`, `events-spa` (Rally), `finance-spa`, `learn-spa`, `wiki-spa`, `desk-spa`, `tasks-spa` (public, sign-in from the browser); `den-keycloak`, `hr-provisioner`, `learn-provisioner` (confidential, service accounts) |
| `attendees` | attendees submitting to Rally | `rally-submit` (public) |

The realm imports (`charts/keycloak/templates/realm-*.yaml`) are
**generated** from the development realms of the main repository by
`bootstrap/scripts/keycloak-realm.py` and ship with the template; they
take your domain from `cluster.yaml`. The generator makes them fit for
production:

- no users, except the service-account users of the confidential clients;
- redirect URIs only on `https://<host>.example.org` (no `localhost`),
  where `<host>` is the app's host name from `cluster.yaml` (`den.host`,
  `modules.<module>.host`, `modules.rally.submit.host`);
- the password grant (*direct access grants*) off on all browser clients;
- TLS required for every request (`sslRequired: all`);
- self-registration **off** in `conservices` (HR creates staff accounts)
  and on in `attendees` (people sign up to submit);
- client secrets and the SMTP login as `${PLACEHOLDERS}` (below); the SMTP
  block only with `keycloak.smtp.enabled: true`.

You do not need to run the generator to install. Run it only after the
development realms of the main repository change (from the root of the
GitOps repository, with the main repository checked out next to it, and
PyYAML installed):

```sh
python3 bootstrap/scripts/keycloak-realm.py --source ../con-services/infra/keycloak
```

You should see:

```text
wrote charts/keycloak/templates/realm-conservices.yaml (12 clients, users kept: ['service-account-hr-provisioner', 'service-account-den-keycloak', 'service-account-learn-provisioner'])
wrote charts/keycloak/templates/realm-attendees.yaml (1 clients, users kept: none)
```

!!! warning "A realm is imported only once"
    The operator imports a realm only if it does **not exist yet**. Editing
    the realm file later does not change a running realm. Make later changes
    in the admin console (and in the development realm, so new
    installations get them), or see [Add a module client](#add-a-module-client).

### Placeholders

The realm imports contain no secrets. The operator fills these placeholders
from the Secret `keycloak-realm-secrets`, which External Secrets builds from
OpenBao:

| Placeholder | OpenBao path, key |
| --- | --- |
| `DEN_KEYCLOAK_CLIENT_SECRET` | `conservices/infra/keycloak/clients`, `den-keycloak` |
| `HR_PROVISIONER_CLIENT_SECRET` | `conservices/infra/keycloak/clients`, `hr-provisioner` |
| `LEARN_PROVISIONER_CLIENT_SECRET` | `conservices/infra/keycloak/clients`, `learn-provisioner` |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM`, `SMTP_USERNAME`, `SMTP_PASSWORD` | `conservices/infra/keycloak/smtp`, `host`, `port`, `from`, `username`, `password` |

The same client secrets reach Den, HR and Learn through their own
ExternalSecrets, so both sides always agree.

## Bring it up

1. **Fill in the secrets.** External Secrets creates the client secrets and
   the bootstrap admin's password. With `keycloak.smtp.enabled: true` you
   enter the SMTP server (`conservices/infra/keycloak/smtp`: `host`, `port`,
   `from`, `username`, `password`), for example with the helper script:

    ```sh
    bash bootstrap/scripts/openbao-seed.sh     # Windows: .\bootstrap\scripts\openbao-seed.ps1
    ```

    You should see, after your answers,
    `conservices/infra/keycloak/smtp written` (or `exists, keeping it`).
    `kubectl get pushsecret -n external-secrets generated-keycloak-clients`
    should be `Synced`.

2. **Check your hostnames.** The chart builds `https://<keycloak.host>.<domain>`
   and `https://<keycloak.adminHost>.<domain>` from `cluster.yaml` and puts
   both names on the certificate `keycloak-tls`. With `domain: example.org`
   and the defaults that is `https://auth.example.org` and
   `https://auth-admin.example.org`. To use other names, set them before
   the first install (later changes need extra steps, see
   [Changing a host name](#changing-a-host-name)):

    ```yaml
    keycloak:
      host: login
      adminHost: login-admin
    ```

3. **Make `auth-admin.example.org` reachable on your LAN.** Point it at the
   internal Gateway's IP address, like the other admin tools (see
   [DNS and certificates](dns-and-certificates.md)).

4. **Sync and watch:**

    ```sh
    kubectl get keycloak,keycloakrealmimport -n conservices-identity
    ```

    ```text
    NAME                                 READY
    keycloak.k8s.keycloak.org/keycloak   true

    NAME                                                DONE
    keycloakrealmimport.k8s.keycloak.org/conservices    true
    keycloakrealmimport.k8s.keycloak.org/attendees      true
    ```

5. **Check the public endpoint:**

    ```sh
    curl -s https://auth.example.org/realms/conservices/.well-known/openid-configuration | jq -r .issuer
    ```

    It should print `https://auth.example.org/realms/conservices`.

## First admin login

The operator creates a **temporary admin** (`temp-admin`) in the `master`
realm on the very first start. Use it once to create your own admin, then
delete it.

1. Read its password (it is shown on your screen, so do this in private):

    ```sh
    kubectl get secret -n conservices-identity keycloak-bootstrap-admin \
      -o jsonpath='{.data.password}' | base64 -d; echo
    ```

2. Open `https://auth-admin.example.org/admin/master/console/` and sign in
   as `temp-admin`.
3. In the `master` realm, go to **Users → Add user**, create your own
   account, set a password under **Credentials**, and under
   **Role mapping → Assign role** give it the realm role `admin`.
4. Sign out, sign in as your new user, and turn on two-factor
   authentication for it (**Authentication → Required actions → Configure
   OTP** set to default, or from the account console).
5. Delete `temp-admin` under **Users**. It is not created again: Keycloak
   only creates the bootstrap admin when the `master` realm is new.

Staff accounts of the `conservices` realm are created through HR, or by
hand in the admin console (**conservices → Users**). Den's admin group is
`den-admin`.

## E-mail (SMTP)

Keycloak sends password resets and e-mail verification. The SMTP settings
come from `conservices/infra/keycloak/smtp` at the first import. To change
them later, edit **Realm settings → Email** in the admin console of each
realm, and update OpenBao too so a rebuilt cluster gets the new values.
**Test connection** on that page sends a test mail to your admin user's
address.

## Login theme

The `conservices` theme (login pages and e-mails) is in
`charts/keycloak/files/theme/` and is mounted into the Keycloak pods from the
ConfigMap `keycloak-theme`. Both realms use it (`loginTheme` and
`emailTheme`). After editing a theme file, commit it and restart Keycloak:

```sh
kubectl rollout restart statefulset/keycloak -n conservices-identity
```

The `master` realm keeps Keycloak's default theme; you can switch it under
**Realm settings → Themes** in the `master` realm. Den can also brand the
login page through the `den-keycloak` client (Den admin → Branding).

## Add a module client

For a new module `shop` with the browser client `shop-spa`:

1. Add the client to `infra/keycloak/realm-conservices.json` in the main
   repository, so new installations and development get it.
2. Regenerate the realm templates in `charts/keycloak/templates/` (see
   [The realms](#the-realms)) and commit them.
3. On a **running** cluster the import does not run again, so add the
   client there by hand: in the admin console, **conservices → Clients →
   Import client**, paste the client's JSON from the generated realm file,
   and save.
4. If the module calls Keycloak from its backend with a client secret,
   generate one under the client's **Credentials** tab and store it in
   OpenBao, for example:

    ```sh
    bao kv patch conservices/infra/keycloak/clients shop-backend=-
    ```

    (paste the secret, then Ctrl-D). Reference it from the module's
    ExternalSecret.

## Changing a host name

Every public address is `https://<host>.<domain>`, and the host label is a
setting in `cluster.yaml`: `keycloak.host` (default `auth`),
`keycloak.adminHost` (`auth-admin`), `den.host` (`den`),
`modules.<module>.host` (the module's name; Rally `events`) and
`modules.rally.submit.host` (`submit`). The full table is on
[Den and the modules: Host names](apps.md#host-names).

**Before the first install**, just set them; the realms are imported with
the right addresses. **On a running installation**, a push changes the
routes, certificates, web app settings and Keycloak's own hostname, but
not the realms: Keycloak imports a realm only once. Do these steps:

1. **Create the DNS record** for the new name, before you push, so the
   certificate can be issued: public names (`keycloak.host`, Den, the
   modules, Rally's submission site) point to the public Gateway IP, the
   admin console (`keycloak.adminHost`) to the internal Gateway IP
   ([DNS and certificates](dns-and-certificates.md)).
2. **Changing `keycloak.host` only:** update the CoreDNS rewrite so that
   the new name answers with `keycloak-public` inside the cluster
   ([how](dns-and-certificates.md#inside-the-cluster-reaching-keycloak)).
   Otherwise backends fail with `failed to discover OIDC issuer`. The
   token issuer changes too, so everyone has to sign in again.
3. **Change the setting** in `cluster.yaml`, check, commit and push:

    ```yaml
    modules:
      rally: { enabled: true, version: "1.0.0-1", host: con }
    ```

    ```sh
    helm template root charts/root -f cluster.yaml > /dev/null && git commit -am "Rally at con.example.org" && git push
    ```

4. **Update the client in Keycloak** (not needed for `keycloak.host` or
   `keycloak.adminHost`). Open the admin console
   (`https://auth-admin.example.org`), pick the realm and client from this
   table, and on its **Settings** tab replace the old address with the new
   one in **Root URL**, **Home URL**, **Valid redirect URIs**,
   **Valid post logout redirect URIs** and **Web origins**. Save.

    | Setting you changed | Realm | Client |
    | --- | --- | --- |
    | `den.host` | `conservices` | `den-spa` |
    | `modules.rally.host` | `conservices` | `events-spa` |
    | `modules.rally.submit.host` | `attendees` | `rally-submit` |
    | `modules.<module>.host` (others) | `conservices` | `<module>-spa` |

    For Rally at `con`, **Valid redirect URIs** becomes
    `https://con.example.org/*` and **Web origins** `https://con.example.org`.

5. **A module that is already paired:** edit its address in Den admin →
   **Modules**. Den registers modules from `cluster.yaml` only once and
   never changes an existing entry.
6. **Check** that sign-in works from the new address. Open it in a private
   browser window and sign in; Keycloak must send you back to the new
   address. Remove the old DNS record afterwards.

Keep the development realm of the main repository unchanged: it uses the
`*.conservices.test` names, and the generator maps them to your settings.

## Troubleshooting

**`keycloak` stays not ready; the log says `Connection to ... refused` or
`SSL error`**
: PostgreSQL is not healthy yet, or the internal CA is missing. Check
  `kubectl get cluster -n conservices-data` and that the ConfigMap
  `conservices-internal-ca` exists in `conservices-identity`.

**`password authentication failed for user "keycloak"`**
: The Secret `keycloak-db` does not match the role's password. Both come
  from `conservices/infra/postgres/roles/keycloak`; force a refresh with
  `kubectl annotate externalsecret -n conservices-identity keycloak-db force-sync=$(date +%s) --overwrite`.

**The realm import Job fails with `Could not resolve placeholder`**
: An entry of `keycloak-realm-secrets` is missing. Run
  `kubectl describe externalsecret -n conservices-identity keycloak-realm-secrets`;
  a missing `conservices/infra/keycloak/smtp` is the usual cause. Fill it with
  the seed script, then delete the failed Job so the operator retries.

**Browsers show `HTTPS required` or redirect to the wrong host**
: The hostname settings do not match the address you use. Keycloak runs
  with `hostname.strict: true`; use exactly `https://auth.example.org` for
  sign-in and `https://auth-admin.example.org` for the admin console (or
  the names in `keycloak.host` and `keycloak.adminHost`).

**After changing a host name, sign-in fails with `Invalid parameter: redirect_uri`**
: The client in Keycloak still has the old address; the realm import does
  not run again. Update the client as in step 4 of
  [Changing a host name](#changing-a-host-name).

**`helm template` stops with `at '/keycloak/host': 'login.example.org' does not match pattern`**
: A host setting contains a dot, an upper-case letter or other characters.
  Write only the first label (`login`, not `login.example.org`); the
  domain is added from `domain`.

**`https://auth.example.org/admin/` returns 404**
: Working as intended: the admin console is only on the internal Gateway
  at `auth-admin.example.org`.

**`auth-admin.example.org` does not load**
: The name does not resolve to the internal Gateway, or your computer is
  not on the internal network. `nslookup auth-admin.example.org` must
  return the internal Gateway IP.

**Modules fail at start-up with `failed to discover OIDC issuer`**
: The backend cannot reach Keycloak in the cluster. Check that CoreDNS
  answers `auth.example.org` with the `keycloak-public` Service
  (`kubectl run -it --rm dns --image=busybox:1.37 --restart=Never -- nslookup auth.example.org`).
  If it returns the public address instead, add the rewrite to your
  CoreDNS ([how](dns-and-certificates.md#inside-the-cluster-reaching-keycloak)).

**PodSecurity warnings in `conservices-identity`**
: The namespace enforces `baseline` and only warns about `restricted`,
  because the operator generates some pods itself. Once
  `kubectl get events -n conservices-identity | grep PodSecurity` stays
  empty after a full sync, you can switch the namespace label
  `pod-security.kubernetes.io/enforce` to `restricted`.

## Related pages

- [Authentication](../concepts/authentication.md): how the modules use OIDC.
- [Secrets](../operations/secrets.md): every OpenBao path.
- [Internal TLS](../operations/internal-tls.md): the internal CA.
- [Den and the modules](apps.md): the applications that sign in here.
