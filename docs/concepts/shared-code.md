# Shared code

Den and every module are separate Git repositories, but some Go code must
behave exactly the same in all of them: pairing with Den, matching a
person's groups, the sign-in guard. That code has **one source**, the folder
`shared/go` in the `con-services` repository, and every module carries a
**generated copy** of the packages it uses. A script makes the copies, and
CI fails when a copy has been edited by hand (**drift**).

This page explains the packages, how to copy them into a module, how the
drift check works, and the settings the packages read.

!!! note "Adoption happens per module"
    The packages exist from `con-services` 1.0.0. Each module switches to
    them in its own release; that release's changelog says so, and from then
    on its configuration page lists the settings below. Until then a module
    keeps its hand-made `internal/denlink` copy and its current sign-in
    rules.

## Why copies and not a Go dependency

Each module is built from its own repository and must build without
network access to `con-services` at a particular version. A copy in
`<module>/backend/internal/<package>`:

- builds with the module's own `go.mod`, with no extra Go module to
  publish or version;
- is reviewed in the module's pull request like any other code;
- can never change underneath a module: it changes only when someone runs
  the sync script and commits the result.

The price is that copies can drift apart. The header in every copied file
and the drift check make sure they do not.

## The packages

| Package | What it does | Reads |
| --- | --- | --- |
| `groupmatch` | Decides whether a person's groups (from the ID token) match the groups a module grants roles to. | `OIDC_GROUPS_CLAIM`, `OIDC_GROUP_MATCH`, `OIDC_GROUP_PREFIX` |
| `denlink` | Pairs the module with Den, stores the module credential **encrypted**, pulls Den's bundle every minute, serves the brand and the Den connection endpoints, and reports a **revoked** credential. | `DEN_MODE`, `DEN_INTERNAL_URL`, `DEN_ALLOWED_HOSTS`, `DEN_LINK_ENCRYPTION_KEY`, `DEN_LINK_ENCRYPTION_KEY_PREVIOUS`, `APP_ENV` |
| `authbase` | The `AUTH_MODE`/`APP_ENV` start-up guard, CORS headers (dev headers only in dev mode), a JSON body decoder with a size limit, a rate limiter, the client address behind trusted proxies, security headers for API responses, and the person's identity key. | `AUTH_MODE`, `APP_ENV`, `TRUSTED_PROXY_CIDRS` |
| `gworkspace` | A Google Workspace client: accounts and groups (Admin SDK Directory) and mailboxes (Gmail API), through a service account with domain-wide delegation. Comes with an in-memory fake for tests. | `GOOGLE_WORKSPACE_CREDENTIALS_FILE`, `GOOGLE_WORKSPACE_ADMIN_EMAIL`, `GOOGLE_WORKSPACE_DOMAIN` |

`shared/go` is one Go module, `github.com/AGlElectronics/con-services/shared/go`,
so you can test all packages together:

```sh
cd shared/go
go vet ./...
go test ./...
```

```text
ok   github.com/AGlElectronics/con-services/shared/go/authbase    0.03s
ok   github.com/AGlElectronics/con-services/shared/go/denlink     0.04s
ok   github.com/AGlElectronics/con-services/shared/go/groupmatch  0.02s
ok   github.com/AGlElectronics/con-services/shared/go/gworkspace  0.10s
```

### groupmatch

The matching rule itself is described in
[Authentication → How groups are matched](authentication.md#how-groups-are-matched).

| Function | Use |
| --- | --- |
| `groupmatch.FromEnv(os.Getenv) (Config, error)` | Read and validate the three settings at start-up. |
| `cfg.Groups(claims map[string]any) []string` | The groups from a verified token's claims (only the configured claim). |
| `cfg.Match(groups, grant)`, `cfg.MatchAny(groups, grants)`, `cfg.Matching(groups, grants)` | Does the person have this grant, any of these grants, which ones? |
| `groupmatch.NewGrant(name) Grant` | When an admin enters a group: `Stored` (normalised, for the database and unique indexes) and `Display` (as typed). |
| `groupmatch.Normalize(name)`, `cfg.Key(name)` | The normalised form, and the form actually compared (prefix removed, last segment in `last` mode). |

### denlink

The same public API as the copies modules carry today (`New`, `Restore`,
`Run`, `Bundle`, `Setting`, `BoolSetting`, `Pair`, `Unpair`, `Sync`, the
handlers and `RequirePaired`), plus:

| Addition | Use |
| --- | --- |
| `denlink.FromEnv(slug, version, os.Getenv) (Config, error)` | Read every setting; fails without `DEN_LINK_ENCRYPTION_KEY` outside `APP_ENV=development`. `Config.AppEnv` is normalised (`denlink.NormalizeAppEnv`): trimmed, lower-cased, `production` when unset. |
| `denlink.Open(pool, cfg, log) (*Client, error)` | `New` that returns the configuration error, so the backend refuses to start. `New` still works; then `Restore` and `Pair` return the error. |
| `client.Revoked() bool`, `Status.Revoked`, `State.Revoked` | Den rejected the credential; an admin must pair again. |
| `denlink.ErrRevoked` | What `Sync` and the preferences calls return after a `401` from Den. |
| `Config.HostAllowed(host)` | Whether a pasted pairing URL may point at that host. |
| `denlink.Schema`, `denlink.SchemaUpgrade` | The `den_link` table for a new module, and the migration an existing one needs (adds `revoked_at`). |
| `client.ModuleSettings() *ModuleSettings`, `Bundle.ModuleSettings` | Den's [module settings](module-settings.md) for this module, from the stored bundle (so they survive a restart); `nil` when standalone. Methods, all safe on `nil`: `Lookup(key)`, `Section(name)`, `Decode(key, &dst)`, `String`, `Bool`, `Int`, `Days(key)` (whole number, 0 or more), `Retention()`, `SMTP()` (only when `smtp.host` is set; port `587` and `starttls` by default), `FinanceSeller()`. Keys are dotted: `wiki.revision_retention_days`, `finance.seller`. |
| `client.ModuleSettingSecret(ctx, key) (string, error)`, `client.SMTPPassword(ctx) (string, error)` | A secret Den keeps out of the bundle. `SMTPPassword` is the key `smtp.password`. An empty string and a nil error means Den holds none. `ErrNotPaired` when standalone, `ErrRevoked` when Den rejected the credential. Kept in memory for `SecretCacheTTL` (one minute), never in the database. A response over 64 KiB is refused. See [Fetching the SMTP password](module-settings.md#fetching-the-smtp-password). |
| `client.Modules(ctx) ([]Module, error)` | Den's enabled, paired modules (`GET /api/v1/integrations/modules`, the module's pairing credential). `Module.RoleCatalogURL` is that module's role catalog; empty when it publishes none. `ErrNotPaired` when standalone, `ErrRevoked` when Den rejected the credential. Kept in memory for `ModulesCacheTTL` (one minute). A response over 64 KiB is refused. See [Paired modules](#paired-modules). |
| `client.RequireDen(next) http.HandlerFunc`, `PortalCallerFrom(ctx)`, `CredentialMatches(ctx, token)`, `BearerToken(header)`, `UserFromDen(r)` | Check a call Den makes into the module (`GET /api/portal/todos`). See [Portal to-dos](#portal-to-dos). |
| `denlink.UserMessage(err) string` | The sentence an admin sees: the API `message` field and `den_link.last_error`. `Error()` is the Go error string (lowercase, no trailing punctuation). |

The pairing (`POST …/den/pair`) and preferences (`PUT …/me/preferences`)
handlers accept a body of at most 64 KiB and answer like
`authbase.DecodeJSON`: `413 request_too_large` when it is larger, `400
bad_request` when it is not exactly one JSON value. `denlink` keeps its own
small copy of that decoder instead of calling `authbase`, because a module
may copy `denlink` without `authbase` and the shared packages never import
each other. A secrets response and the paired-module list from Den are
each capped at the same 64 KiB and are not cached when larger.

What changes in the module's API is on [Pairing](pairing.md#the-den-connection-api-in-each-module).

#### Fetching a module-setting secret

`SMTP()` on the bundle tells the module the mail server and whether Den
holds a password (`password_set`). The password itself is fetched when
the module sends mail:

```go
password, err := den.SMTPPassword(ctx)
```

The call, the cache and the errors (`ErrNotPaired`, `ErrRevoked`, an empty
password) are written out on
[Module settings](module-settings.md#fetching-the-smtp-password).
`ModuleSettingSecret(ctx, "smtp.password")` is the same method for a
dotted key. The answer stays in the process for at most a minute
(`SecretCacheTTL`); a successful sync, a new pairing, unpairing, or a
rejected credential drops it immediately. It is never written to
`den_link`.

#### Paired modules

`Modules` asks Den which modules are paired. HR uses it to find each
module's [role catalog](role-catalog.md) without a hand-written list:

```go
mods, err := client.Modules(ctx)
```

The call is `GET /api/v1/integrations/modules` with the module's pairing
credential (`Authorization: Bearer`), the same credential as the bundle.
Den answers `200` with the enabled, paired modules:

```json
{
  "modules": [
    {
      "slug": "desk",
      "display_name": "Desk",
      "base_url": "https://desk.con.example.org",
      "internal_url": "https://desk-backend.conservices-desk.svc.cluster.local:8080",
      "role_catalog_url": "https://desk-backend.conservices-desk.svc.cluster.local:8080/api/role-catalog"
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `Slug`, `DisplayName` | As registered in Den. |
| `BaseURL` | Public address, for links. |
| `InternalURL` | Address a backend inside the cluster uses. Empty when the registration has none. |
| `RoleCatalogURL` | Where that module serves `GET /api/role-catalog`. Den builds it from `internal_url`, or from `base_url` when `internal_url` is empty. Empty when the module publishes no catalog. |

Do not append `/api/role-catalog` yourself: Den already did.

A body over 64 KiB is refused and not cached. A successful answer stays in
memory for `ModulesCacheTTL` (one minute) and is dropped when the module
syncs, pairs again, unpairs, or Den rejects the credential — the same
moments as the SMTP password. It is never written to `den_link`.

`ErrNotPaired` means standalone: no request is sent. `ErrRevoked` means
Den rejected the credential, including a `401` on this call (the link is
marked revoked, as with `Sync`). Any other failure is returned and not
cached.

HR connects this to its catalog fetcher. `Discover` wants a slug and a
catalog URL. Skip a module whose `RoleCatalogURL` is empty.
`ROLE_CATALOG_SOURCES` still replaces the URL of a slug and adds modules
Den does not list. When the call returns `ErrNotPaired`, return no
discovered modules so the override list is the whole set (standalone HR).
On any other error, log it and return no discovered modules for that
attempt; HR still shows the last catalog it saved for a module.

```go
fetcher.Discover = func(ctx context.Context) []catalog.Source {
    mods, err := denClient.Modules(ctx)
    if err != nil {
        if !errors.Is(err, denlink.ErrNotPaired) {
            log.Warn().Err(err).Msg("den link: paired modules")
        }
        return nil
    }
    out := make([]catalog.Source, 0, len(mods))
    for _, m := range mods {
        if m.Slug == "" || m.RoleCatalogURL == "" {
            continue
        }
        out = append(out, catalog.Source{Slug: m.Slug, URL: m.RoleCatalogURL})
    }
    return out
}
```

#### Portal to-dos

Den's portal lists what the signed-in person should do. Den's **backend**
calls each paired module itself:

```text
GET https://tasks.example.org/api/portal/todos
Authorization: Bearer <the module's pairing credential>
X-Den-User-Issuer: https://auth.example.org/realms/conservices
X-Den-User-Subject: 8f0c2a1e-1b3d-4e5f-9a6b-7c8d9e0f1a2b
```

The person's token never leaves Den. Den does not pass the person in the
query string; `UserFromDen` reads only `X-Den-User-Issuer` and
`X-Den-User-Subject` (`HeaderUserIssuer`, `HeaderUserSubject`).

`RequireDen` checks that request and puts the person on the context.
Mount it on `GET /api/portal/todos` (behind `RequirePaired`, like the
rest of the API). A revoked credential still passes `RequirePaired` — the
module keeps its last bundle — and then fails here.

```go
r.Get("/api/portal/todos", den.RequireDen(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    caller, _ := denlink.PortalCallerFrom(r.Context())
    items := todosFor(r.Context(), caller.Issuer, caller.Subject)
    w.Header().Set("Content-Type", "application/json")
    _ = json.NewEncoder(w).Encode(map[string]any{"items": items})
})))
```

Den keeps an item only when it has an `id`, a `title` and an `http` or
`https` `url`. `severity` is `info`, `warning` or `danger` (anything else
counts as `info`). `due_at` is RFC3339 or `null`. `detail` is optional.
Den gives up after five seconds and skips a module that answers with an
error or `404`.

| Result | Status | Code | Message |
| --- | --- | --- | --- |
| Credential matches and both headers name the person | the handler runs | | `PortalCallerFrom` returns issuer and subject |
| No credential, the wrong one, not paired, revoked, or the database read failed | `401` | `unauthorized` | `invalid or revoked credential` |
| A header is missing, blank, or longer than 512 bytes | `400` | `bad_request` | `issuer and subject are required` |

The `401` is the same in every failure so the route does not say whether
the module is paired. `CredentialMatches(ctx, token)` is the check on its
own: it compares the **decrypted** pairing credential, and it hashes both
sides before comparing so a shorter token does not return at the first
different byte. `BearerToken` takes the token out of an `Authorization`
header (`Bearer` is case-insensitive). A module that writes its own status
codes calls those two and `UserFromDen` instead of `RequireDen`.

What you should see: with a pairing, `curl` as below answers `200` and a
JSON object `{"items":[…]}`. The same call with no `Authorization` header
answers `401`.

```sh
curl -s -H "Authorization: Bearer $MODULE_CREDENTIAL" \
  -H "X-Den-User-Issuer: https://auth.example.org/realms/conservices" \
  -H "X-Den-User-Subject: 8f0c2a1e-1b3d-4e5f-9a6b-7c8d9e0f1a2b" \
  https://tasks.example.org/api/portal/todos
```

```json
{"items":[{"id":"task-18","title":"Pack radios","url":"https://tasks.example.org/t/task-18","severity":"warning","due_at":"2026-11-14T10:00:00Z"}]}
```

### authbase

| Function | Use |
| --- | --- |
| `authbase.FromEnv(os.Getenv) (Config, error)` | `AUTH_MODE` (default `oidc`) and `APP_ENV` (default `production`); fails for `AUTH_MODE=dev` unless `APP_ENV=development`. |
| `authbase.NormalizeAppEnv(s)` | How `APP_ENV` is read: trimmed, lower-cased, empty is `production`. `denlink.NormalizeAppEnv` is an identical copy. |
| `cfg.AllowedHeaders(extra...)`, `cfg.CORS(CORSOptions)` | CORS: `X-Dev-User` and `X-Dev-Groups` are allowed only in dev mode. `CORSOptions.ExposeHeaders` lists the response headers the page may read (`Access-Control-Expose-Headers`); `nil` means `authbase.DefaultExposeHeaders` (`X-Request-ID`), an empty slice exposes none. |
| `cfg.TrustedProxies`, `authbase.ParseTrustedProxies(s)` | The proxies from `TRUSTED_PROXY_CIDRS` whose `X-Forwarded-For` is believed. `.ClientAddr(r)` finds the client (rules in [Client IP addresses](../operations/production.md#client-ip-addresses)), `.Middleware` replaces `r.RemoteAddr` with it, `.ClientIP` is a rate-limit key. The zero value trusts nobody. |
| `cfg.StripDevHeaders(next)` | Middleware that deletes the dev headers from every request outside dev mode. |
| `authbase.DecodeJSON(w, r, &dst, DecodeOptions{MaxBytes, DisallowUnknownFields, RequireJSONContentType})` | Decode a request body with `http.MaxBytesReader` (default 1 MiB). Errors are `413 request_too_large`, `415 unsupported_media_type` or `400 bad_request`; write them with `authbase.WriteDecodeError`. |
| `authbase.NewRateLimiter(RateLimitOptions{Rate, Burst, Key})`, `.Middleware` | An in-memory token bucket per client IP (`authbase.ClientIP`: each IPv4 address on its own, IPv6 addresses per `/64` network, since one home or phone usually holds a whole `/64`) or per person (`authbase.BySubject`). Answers `429 rate_limited` with `Retry-After`. Each replica counts on its own. `authbase.ParseRate("60/m")` reads a rate from a setting. `ClientIP` only reads `r.RemoteAddr`: behind the Gateway, mount `cfg.TrustedProxies.Middleware` before the limiter (or keep the module's own trusted-proxy middleware), otherwise every request counts against the proxy's address. |
| `authbase.SecurityHeaders(next)` | `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY` and `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'` on every API response. |
| `authbase.UserKey{Issuer, Subject}` | A person's identity across Con Services (`iss` + `sub`), with `String`, `ParseUserKey` and `IsZero`. |

A `429` looks like this:

```text
HTTP/1.1 429 Too Many Requests
Retry-After: 2
Content-Type: application/json

{"error":{"code":"rate_limited","message":"Too many requests; try again in 2 seconds."}}
```

Mount order on the API router, outermost first:

```go
auth, err := authbase.FromEnv(os.Getenv)
if err != nil {
    log.Fatal().Err(err).Msg("configuration")
}
r.Use(auth.TrustedProxies.Middleware) // RemoteAddr = the real client
r.Use(auth.StripDevHeaders)
r.Use(authbase.SecurityHeaders)
r.Use(auth.CORS(authbase.CORSOptions{AllowedOrigins: origins}))
r.With(limiter.Middleware).Get("/api/public/verify/{code}", verify)
```

#### Error codes

These codes are part of the API contract. A module that uses `authbase`
returns them unchanged in its standard error body
`{"error":{"code":"…","message":"…"}}`, lists them in its API docs, and its
web app may switch on them. Do not map them to the module's own codes (for
example `validation_failed`). The constants are exported, so handlers can
compare without string literals.

| Status | Code | Constant | When |
| --- | --- | --- | --- |
| `400` | `bad_request` | `authbase.CodeBadRequest` | The body is empty, not valid JSON, has a field of the wrong type, an unknown field (with `DisallowUnknownFields`), or more than one JSON value. |
| `413` | `request_too_large` | `authbase.CodeRequestTooLarge` | The body is larger than `DecodeOptions.MaxBytes` (default 1 MiB). |
| `415` | `unsupported_media_type` | `authbase.CodeUnsupportedMediaType` | `RequireJSONContentType` is set and `Content-Type` is not `application/json` or `…+json`. |
| `429` | `rate_limited` | `authbase.CodeRateLimited` | The rate limit is used up; `Retry-After` says how many seconds to wait. |

For example, a module endpoint that decodes with `RequireJSONContentType`
(here HR's `POST /api/people`, once HR has adopted `authbase`), called with
a plain-text body:

```sh
curl -s -X POST https://hr.con.example.org/api/people \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: text/plain" -d 'hello'
```

```json
{"error":{"code":"unsupported_media_type","message":"Content-Type must be application/json"}}
```

#### Testing a module that uses authbase or denlink

`authbase.FromEnv` and `denlink.FromEnv` default to `APP_ENV=production`.
Module tests that sign in with `X-Dev-User`/`X-Dev-Groups`, or that call
`denlink.Restore` or `Pair` without `DEN_LINK_ENCRYPTION_KEY`, must set
`APP_ENV=development` (and `AUTH_MODE=dev` for the dev headers):

```go
t.Setenv("APP_ENV", "development")
t.Setenv("AUTH_MODE", "dev")
```

Without it the dev headers are stripped (every request is anonymous and
gets `401`), and `Restore` fails with
`DEN_LINK_ENCRYPTION_KEY is required unless APP_ENV=development`. A
hand-built `authbase.Config{}` or `denlink.Config{}` counts as production
too.

### gworkspace

Modules depend on the interfaces `gworkspace.Directory`, `gworkspace.Gmail`
(or both, `gworkspace.Workspace`), create the real client with
`gworkspace.New(cfg, gworkspace.Options{})`, and use
`gworkspace.NewFake(domain)` in tests.

| Interface | Methods |
| --- | --- |
| `Directory` | `GetUser`, `CreateUser`, `SetSuspended`, `DeleteUser`, `ListGroups`, `GetGroup`, `CreateGroup`, `DeleteGroup`, `ListMembers`, `AddMember`, `RemoveMember` |
| `Gmail` | `ListMessages`, `GetMessage`, `SendMessage`, `ModifyLabels`, `TrashMessage`, `UntrashMessage`, `ListLabels`, `CreateLabel`, `CreateSendAs`, `DeleteSendAs` |

The client refuses users, groups, mailboxes and send-as aliases outside
`GOOGLE_WORKSPACE_DOMAIN`, so a mistake in a module cannot create accounts
in another domain. `gworkspace.IsNotFound(err)` and
`gworkspace.IsConflict(err)` tell the common Google errors apart. Setting
up the service account is described [below](#google-workspace-service-account).

`ListLabels` returns every label on the mailbox. `CreateLabel` creates a
user label by name and shows it in Gmail's label list and on messages
(`labelShow` / `show`); a name that already exists is a conflict.
`UntrashMessage` moves a message out of the trash. `CreateSendAs(ctx,
mailbox, alias, displayName)` lets that mailbox send as `alias`
(`treatAsAlias` is set), and `DeleteSendAs` removes the alias. Those two
request `gworkspace.SendAsScopes()` — `GmailScopes` plus
`gworkspace.SendAsScope`
(`https://www.googleapis.com/auth/gmail.settings.sharing`). Every other
Gmail call stays on `GmailScopes` (`gmail.modify`) alone, so a module that
never creates an alias does not authorise the extra scope. A duplicate
alias is `IsConflict`; deleting one that is already gone is `IsNotFound`.
Desk, which treats both of those as success, can drop its own copies of
these four calls and keep that mapping.

`gworkspace.NewFake` implements the same methods. Its `ListLabels` returns
only labels the test created, not Gmail's system labels.

## Configuration reference

These are the settings the packages read. A module that adopts a package
lists the same rows on its own configuration page.

| Variable | Default | Required | Package | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `production` | no | `authbase`, `denlink` | Only `development` relaxes the rules: allows `AUTH_MODE=dev`, an unencrypted Den credential and `http://` pairing URLs to the development hosts. Anything else counts as production. Both packages trim spaces and ignore case the same way (`NormalizeAppEnv`), so ` Development ` is `development`. |
| `AUTH_MODE` | `oidc` | no | `authbase` | `oidc` verifies Keycloak tokens. `dev` trusts `X-Dev-User`/`X-Dev-Groups` and is refused unless `APP_ENV=development`. |
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7` | no | `authbase` | Comma-separated CIDRs (or single addresses) of the proxies in front of the API (Gateway, nginx, Caddy). Only on a connection from one of them is `X-Forwarded-For` read, right to left, and the first untrusted address is the client; `X-Real-IP` is never read. `none` trusts no proxy. An invalid entry stops the start-up. Same variable and rules as the modules' own handling; see [Client IP addresses](../operations/production.md#client-ip-addresses). Used only when the backend mounts `TrustedProxies.Middleware` or keys on `TrustedProxies.ClientIP`. |
| `OIDC_GROUPS_CLAIM` | `groups` | no | `groupmatch` | The token claim that holds the person's groups. `roles` is never read in addition. A dotted name such as `realm_access.roles` is followed into nested objects when no claim has that exact name. |
| `OIDC_GROUP_MATCH` | `full` | no | `groupmatch` | `full`: the whole group path must match. `last`: only the last path segment is compared. |
| `OIDC_GROUP_PREFIX` | none | no | `groupmatch` | A parent group such as `/con2026` that is removed from group names before matching, for an identity provider that keeps each convention year under its own parent. |
| `DEN_MODE` | `standalone` | no | `denlink` | `required` or `standalone`; see [Pairing](pairing.md#required-or-standalone). Unchanged. |
| `DEN_INTERNAL_URL` | none | on Kubernetes | `denlink` | Replaces scheme and host of a pasted pairing URL; the pasted host is then never contacted. Unchanged. |
| `DEN_ALLOWED_HOSTS` | none | when `DEN_INTERNAL_URL` is empty | `denlink` | Comma-separated hosts a pasted pairing URL may point at, for example `den.con.example.org` or `*.con.example.org` (every subdomain). With `APP_ENV=development`, `localhost`, `127.0.0.1`, `::1` and `*.conservices.test` are always allowed. Outside development the URL must also use `https://`. |
| `DEN_LINK_ENCRYPTION_KEY` | none | **yes**, unless `APP_ENV=development` | `denlink` | **Secret.** 32 random bytes, base64. Encrypts the stored Den credential (AES-256-GCM). Without it outside development the backend refuses to start. One key per module. |
| `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` | none | no | `denlink` | **Secret.** The old key during a [rotation](../operations/secrets.md#den-link-encryption-key). Values sealed with it are re-encrypted with the current key on the next read. |
| `GOOGLE_WORKSPACE_CREDENTIALS_FILE` | none | for Google Workspace | `gworkspace` | Path of the service-account key file (JSON), mounted from a Secret. |
| `GOOGLE_WORKSPACE_ADMIN_EMAIL` | none | for Google Workspace | `gworkspace` | A Workspace admin the service account acts as for Directory calls. Must be in the domain. |
| `GOOGLE_WORKSPACE_DOMAIN` | none | for Google Workspace | `gworkspace` | The Workspace primary domain. Users, groups and mailboxes outside it are refused. All three empty: Google Workspace is off. |

Generate an encryption key:

=== "bash"

    ```sh
    openssl rand -base64 32
    ```

=== "PowerShell"

    ```powershell
    $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b)
    ```

```text
q3V0w6m3cXn8m1x0ZrQm9b7c2H4v5o6p7q8r9s0t1u4=
```

Store it in your secret manager, never in Git; see [Secrets](../operations/secrets.md#den-link-encryption-key).

## Copy a package into a module

The sync script copies `shared/go/<package>` into
`<module>/backend/internal/<package>`. It rewrites imports of
`github.com/AGlElectronics/con-services/shared/go/<x>` to
`<module path>/internal/<x>` (the module path is read from the module's
`go.mod`) and starts every file with:

```go
// Code generated from con-services shared/go/denlink; DO NOT EDIT. Run scripts/sync-shared.
```

1. Clone the workspace so the module sits next to `shared/` (see
   [Local development](../contributing/local-development.md#the-workspace)),
   and create a branch in the module repository.
2. Run the script from the `con-services` root, naming the module and the
   packages:

    === "bash"

        ```sh
        scripts/sync-shared.sh --modules learn --packages denlink,groupmatch
        ```

    === "PowerShell"

        ```powershell
        scripts/sync-shared.ps1 -Modules learn -Packages denlink,groupmatch
        ```

    ```text
    wrote   …/learn/backend/internal/denlink/crypto.go
    wrote   …/learn/backend/internal/denlink/denlink.go
    wrote   …/learn/backend/internal/denlink/denlink_test.go
    wrote   …/learn/backend/internal/denlink/security_test.go
    wrote   …/learn/backend/internal/groupmatch/example_test.go
    wrote   …/learn/backend/internal/groupmatch/groupmatch.go
    wrote   …/learn/backend/internal/groupmatch/groupmatch_test.go

    Done. In each backend run: go mod tidy; go build ./...; go test ./internal/...
    ```

    Later runs need no `--packages`: without it the script updates the
    packages the module already has.

3. In the module's backend, update dependencies and test:

    ```sh
    cd ../learn/backend
    go mod tidy
    go build ./...
    go test ./...
    ```

4. Do the adoption work for each package (next section), commit in the
   module repository and add a changelog entry there.

Files in `internal/<package>` **without** the header are left alone, so a
module may keep extra tests of its own there. A generated file that no
longer exists in `shared/go` is deleted.

### What adopting a package involves

**denlink**

1. Add a migration with `denlink.SchemaUpgrade`
   (`ALTER TABLE den_link ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;`).
   Without it every pairing query fails.
2. Build the client with `denlink.FromEnv` and `denlink.Open` and stop the
   start-up on error.
3. Add `DEN_LINK_ENCRYPTION_KEY` to the module's Secret (chart
   `existingSecret` keys, Kustomize, the root `docker-compose.yml`) and to
   its configuration page. Existing plaintext credentials are encrypted on
   the first read, so no re-pairing is needed.
4. On Kubernetes `DEN_INTERNAL_URL` is set, so `DEN_ALLOWED_HOSTS` is not
   needed. For a module without it, set `DEN_ALLOWED_HOSTS`.
5. In the web app, show *Den rejected this module's credential: pair again*
   when `GET /api/den/state` answers `"revoked": true`.
6. Update tests that compare the state body exactly: it now has a
   `revoked` field.
7. Read Den's [module settings](module-settings.md) with
   `client.ModuleSettings()` instead of SQL on `den_link.bundle`; remove
   such queries (Wiki's revision retention, Finance's seller details).
8. Tests that call `Restore` or `Pair` set `APP_ENV=development` (see
   [Testing](#testing-a-module-that-uses-authbase-or-denlink)).
9. When Den sets `smtp.password_set`, fetch the password with
   `client.SMTPPassword` instead of the module's `SMTP_PASSWORD`. See
   [Fetching the SMTP password](module-settings.md#fetching-the-smtp-password).
10. Serve `GET /api/portal/todos` with `client.RequireDen` so Den's portal
    can list the person's to-dos. See [Portal to-dos](#portal-to-dos).
11. HR: set the catalog fetcher's `Discover` from `client.Modules`. See
    [Paired modules](#paired-modules). Other modules do not call it.

**groupmatch**: replace the module's own group comparison, store grants with
`NewGrant` (a migration normalising existing grants), stop merging `roles`
into groups, and add the three `OIDC_GROUP*` settings to the configuration
page.

!!! warning "Grants cannot be matched with SQL equality"
    The stored grant (`Grant.Stored`) is only normalised. The form that is
    compared, `cfg.Key(name)`, also drops `OIDC_GROUP_PREFIX` and, with
    `OIDC_GROUP_MATCH=last`, everything but the last segment, and it does
    so for the token's groups too. So
    `WHERE grant_group = ANY($tokenGroups)` misses matches as soon as a
    prefix or `last` is configured: `/con2026/departments/security` must
    match the stored `departments/security`, and in `last` mode
    `/teams/security` matches it as well. Load the module's grants (they
    are few) and compare in Go with `cfg.Matching(groups, grants)`. Do not
    store `cfg.Key` values either: they change when the settings change.

**authbase**: call `authbase.FromEnv` at start-up (this changes the
defaults to `AUTH_MODE=oidc` and `APP_ENV=production`; the module's
`.env.example` and Compose service then set `APP_ENV=development`
explicitly), mount `StripDevHeaders` and `SecurityHeaders` first on the API
router, and use `DecodeJSON` for request bodies. Also:

- Keep the module's own trusted-proxy middleware, or replace it with
  `cfg.TrustedProxies.Middleware` mounted before any rate limiter. Either
  way `TRUSTED_PROXY_CIDRS` keeps its name and default.
- Return the [error codes](#error-codes) unchanged and list them in the
  module's API docs.
- If the web app reads a response header such as `X-Request-ID` or
  `Content-Disposition` cross-origin, list it in
  `CORSOptions.ExposeHeaders` (`X-Request-ID` is exposed by default).
- Set `APP_ENV=development` in tests that use the dev headers (see
  [Testing](#testing-a-module-that-uses-authbase-or-denlink)).
- `authbase` does not verify tokens. A backend that refuses ID tokens (the
  [token contract](authentication.md#tokens-the-10-contract)) does so in
  its own OIDC check, and relies on Keycloak's `typ` claim for it; see
  [Refusing ID tokens](authentication.md#refusing-id-tokens).

**Frontend lint (every module)**: the shared module CI runs
`npm run --if-present lint` in the frontend folder, so a module whose
`package.json` has a `lint` script must also have an ESLint configuration
(`eslint.config.js`, the flat config of ESLint 9). Without one the job
stops with `ESLint couldn't find an eslint.config.(js|mjs|cjs) file`.
Check it locally before pushing:

```sh
cd frontend
npm ci
npm run lint
```

**gworkspace**: mount the key file from a Secret, add the three settings,
and add a NetworkPolicy egress rule to `oauth2.googleapis.com`,
`admin.googleapis.com` and `gmail.googleapis.com` on port 443 (with a row on
[Network policies](../operations/network-policies.md)).

## Change shared code

1. Change the code and its tests in `shared/go` in a `con-services` branch,
   and run `go test ./...` there.
2. Add an entry to the root `CHANGELOG.md`.
3. Run the sync script for every module that has the package (without
   `--packages`), run each module's tests, and open a pull request per
   module repository. Give the module branches the **same name** as the
   `con-services` branch: the drift check then compares with that branch
   until it is merged.

Never edit a generated copy in a module. A fix that is needed in one module
now still goes into `shared/go` first.

## The drift check

`--check` (bash) or `-Check` (PowerShell) compares the copies with
`shared/go` without writing anything and exits with code `1` on drift.
Line endings are ignored, so a Windows checkout with `core.autocrlf=true`
does not count as drift.

=== "bash"

    ```sh
    scripts/sync-shared.sh --modules hr,stash,learn --check
    ```

=== "PowerShell"

    ```powershell
    scripts/sync-shared.ps1 -Modules hr,stash,learn -Check
    ```

```text
checked …/learn/backend internal/denlink
DRIFT  groupmatch/groupmatch.go: differs from shared/go/groupmatch/groupmatch.go
checked …/learn/backend internal/groupmatch

1 file(s) differ from con-services shared/go. Fix the code in shared/go and run scripts/sync-shared, never edit the copies.
```

A module without generated copies prints
`no shared packages adopted, nothing to check` and passes.

### In CI

The shared module workflow (`module-ci.yml`, see
[CI and releases](../contributing/ci.md)) has a job **Shared code drift**.
It looks for files with the header in `<go-dir>/internal`; when there are
none it passes straight away, so modules that have not adopted anything are
not affected. Otherwise it checks out `con-services` (the branch with the
same name as the module's branch if one exists, else `shared-ref`) and runs
the check. Releases wait for it.

| Input | Default | What it does |
| --- | --- | --- |
| `shared-check` | `error` | `error` fails the run on drift, `warn` only shows a warning, `off` skips the job. |
| `shared-ref` | `main` | The `con-services` ref to compare with when no branch of the same name exists (tag builds always use it). |
| `shared-repository` | `AGlElectronics/con-services` | Where `shared/go` comes from. |

The `con-services` workflow **Shared Go** tests `shared/go` itself and syncs
every package into a scratch module that must build and pass its tests.

## Nginx security headers

The nginx that serves each web app (the React frontend) sends the same
browser security headers: a **Content Security Policy** (CSP, the list of
places the page may load scripts, images and data from:
`default-src 'self'`, `script-src 'self'`, `frame-ancestors 'none'`),
`X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`,
`Referrer-Policy: strict-origin-when-cross-origin` and a
`Permissions-Policy`. HSTS is set at the Gateway or Caddy, not here, and
API responses get their own stricter headers from the backend
(`authbase.SecurityHeaders`).

`/silent-callback.html` is the one page the app must be able to frame
itself, so silent sign-in can run in a hidden iframe. That exact location
uses a second snippet; see [Silent sign-in iframe](#silent-sign-in-iframe).
Every other response keeps `frame-ancestors 'none'`.

The headers come in two forms in `shared/nginx/`, and each form has a
second file for that one page:

| File | Use |
| --- | --- |
| `security-headers.conf.template` | **Preferred.** The origins are environment variables that the official nginx image fills in when the container starts, so one image works for any domain. |
| `security-headers-frame-self.conf.template` | The same headers with `frame-ancestors 'self'` and `X-Frame-Options: SAMEORIGIN`, for `location = /silent-callback.html` only. |
| `security-headers.conf` | The same headers with placeholders you replace by hand, for an app whose origins are fixed at build time. |
| `security-headers-frame-self.conf` | The build-time form of the silent sign-in snippet. |

!!! note "Who fills in the origins"
    **Nothing fills in the placeholders when you copy the file.** The sync
    script (`scripts/sync-shared`) copies only the Go packages; you copy
    the nginx file into the app by hand, once, and it stays a template
    with `${KEYCLOAK_ORIGIN}` and the like in it. The values are filled in
    **when the frontend container starts**: the official `nginx` and
    `nginxinc/nginx-unprivileged` images run `envsubst` over
    `/etc/nginx/templates/*.template` from their entrypoint
    (`20-envsubst-on-templates.sh`), reading the container's environment
    variables `KEYCLOAK_ORIGIN`, `DEN_ORIGIN`, `S3_ORIGIN`,
    `EXTRA_CONNECT_SRC` and `EXTRA_FRAME_SRC`. So one image works for every
    installation, and a
    new domain needs only new environment values and a restart.

    **Helm charts and Kustomize manifests pass the origins as `env` on the
    frontend container**, filled from the chart's values (the Keycloak
    origin is the scheme and host of `OIDC_ISSUER_URL`), and mount an
    `emptyDir` at `/etc/nginx/snippets`; step 6 below shows the
    container spec. A chart that mounts its own `nginx.conf` from a
    ConfigMap keeps only the `include` line there. It never renders a
    filled-in copy of `security-headers.conf` into a ConfigMap or bakes
    one into the image: such a copy goes stale when the shared file
    changes and pins the policy to one domain.

The CSP allows these origins besides the app itself. Each is scheme, host
and optional port, no path (`https://auth.con.example.org`); several are
separated by spaces; an empty value leaves the origin out.

| Variable | What it is | Where it appears in the CSP |
| --- | --- | --- |
| `KEYCLOAK_ORIGIN` | The sign-in server (for Rally's submission site, the attendee realm's server). | `connect-src`, `frame-src` (silent token renewal), `form-action` |
| `DEN_ORIGIN` | Den, when the browser calls Den or loads assets from it. Most apps leave it empty: they serve Den's brand through their own API. | `connect-src` |
| `S3_ORIGIN` | The S3 storage, for apps whose browser uploads files straight to a bucket (presigned URLs) or shows images from it. | `connect-src`, `img-src` |
| `EXTRA_CONNECT_SRC` | Anything else the browser must call. | `connect-src` |
| `EXTRA_FRAME_SRC` | Extra `frame-src` tokens. Empty everywhere except Desk, which sets `about:srcdoc` so a sandboxed mail frame can render. Not an origin: it is the token `about:srcdoc`, with no scheme or host. | `frame-src` |

### Use the template in a web app

1. Copy `shared/nginx/security-headers.conf.template` and
   `shared/nginx/security-headers-frame-self.conf.template` into the app,
   for example to `infra/`.
2. In the frontend Dockerfile, put both into the image's template folder
   and tell the image where to write the result. The official `nginx` and
   `nginxinc/nginx-unprivileged` images run `envsubst` at start-up on every
   `/etc/nginx/templates/*.template` file and write it, without the
   `.template` suffix, to `NGINX_ENVSUBST_OUTPUT_DIR`. The filter limits the
   substitution to the five variables, so nginx's own `$uri` and the like
   are left alone; the empty defaults keep an unset variable from ending up
   in the policy as literal text. The loop writes a copy of each snippet
   with the variables removed, used when `/etc/nginx/snippets` is read-only.

    ```dockerfile
    FROM nginxinc/nginx-unprivileged:1.30.6-alpine
    COPY infra/nginx.conf /etc/nginx/conf.d/default.conf
    COPY infra/security-headers.conf.template /etc/nginx/templates/security-headers.conf.template
    COPY infra/security-headers-frame-self.conf.template /etc/nginx/templates/security-headers-frame-self.conf.template
    USER root
    # Copies without outside origins, used when /etc/nginx/snippets is read-only.
    RUN mkdir -p /etc/nginx/snippets \
     && for t in security-headers security-headers-frame-self; do \
          sed -E 's/ *\$\{[A-Z0-9_]+\}//g' /etc/nginx/templates/$t.conf.template \
            > /etc/nginx/snippets/$t.conf; \
        done \
     && chown -R 101:101 /etc/nginx/snippets
    USER 101
    ENV NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/snippets \
        NGINX_ENVSUBST_FILTER='^(KEYCLOAK_ORIGIN|DEN_ORIGIN|S3_ORIGIN|EXTRA_CONNECT_SRC|EXTRA_FRAME_SRC)$' \
        KEYCLOAK_ORIGIN="" \
        DEN_ORIGIN="" \
        S3_ORIGIN="" \
        EXTRA_CONNECT_SRC="" \
        EXTRA_FRAME_SRC=""
    ```

3. Include the snippet in **every `location` that serves the app**, not
   at `server` level, and not in the `location /api/` that proxies to the
   backend. nginx drops inherited `add_header` lines in a `location` that
   has its own, so each serving `location` needs the `include`; and a
   `server`-level include would also be inherited by `/api/`, which would
   then send two Content Security Policies (the backend's and the app's).

    ```nginx
    location /api/ {
        proxy_pass http://backend;   # no include: the backend sets its headers
    }

    location = /config.json {
        alias /etc/conservices/config.json;
        include /etc/nginx/snippets/security-headers.conf;
        add_header Cache-Control "no-store" always;
    }

    location / {
        try_files $uri $uri/ /index.html;
        include /etc/nginx/snippets/security-headers.conf;
        add_header Cache-Control "no-cache" always;
    }
    ```

4. **Move inline scripts into files.** `script-src 'self'` blocks every
   `<script>…</script>` written into an HTML file, and the browser then
   skips that code without any other sign than a console error. Two are
   in nearly every app:

    - the theme script in `index.html` that sets light or dark mode
      before React starts (without it the page flashes in the wrong
      theme);
    - the script in `public/silent-callback.html` that hands the result of
      the silent token renewal from the hidden frame back to the app
      (`parent.postMessage(…)`); blocked, the session ends when the token
      expires.

    Put each into a file under `public/` and load it by URL. Vite copies
    `public/` unchanged, so the file is served from the app's own origin:

    ```html
    <!-- index.html, in <head>, before the app's module script -->
    <script src="/theme-init.js"></script>
    ```

    ```html
    <!-- public/silent-callback.html -->
    <!doctype html>
    <html><body><script src="/silent-callback.js"></script></body></html>
    ```

    ```js
    // public/silent-callback.js: the same code that was inline
    parent.postMessage({ source: 'oidc-client', url: window.location.href, keepOpen: false }, window.location.origin);
    ```

    Check in the browser's developer tools (Console) after a reload and
    after five minutes signed in: no *Refused to execute inline script*.

    A `nonce` or a hash in `script-src` is no alternative: the headers are
    the same for every response, so a nonce would be the same each time,
    and a hash breaks with every edit.
5. **Stash only:** Stash scans barcodes with the camera, so its copy says
   `camera=(self)` in `Permissions-Policy`. Every other app keeps
   `camera=()`.
6. Set the variables on the frontend container. With a read-only root file
   system on Kubernetes, mount an `emptyDir` at `/etc/nginx/snippets` so
   the start-up step can write the file.

    === "Docker Compose"

        ```yaml
        rally-frontend:
          environment:
            KEYCLOAK_ORIGIN: https://auth.conservices.test
            S3_ORIGIN: https://s3.conservices.test
        ```

    === "Kubernetes"

        ```yaml
        env:
          - name: KEYCLOAK_ORIGIN
            value: https://auth.con.example.org
          - name: S3_ORIGIN
            value: https://s3.con.example.org
        volumeMounts:
          - name: nginx-snippets
            mountPath: /etc/nginx/snippets
        # volumes: - name: nginx-snippets
        #            emptyDir: {}
        ```

7. Check the result:

    ```sh
    curl -sI https://events.conservices.test/ | grep -i -E 'content-security|x-frame|referrer|permissions|nosniff'
    ```

    ```text
    content-security-policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https://s3.conservices.test; font-src 'self' data:; connect-src 'self' https://auth.conservices.test   https://s3.conservices.test ; frame-src 'self'  https://auth.conservices.test; frame-ancestors 'none'; form-action 'self' https://auth.conservices.test; base-uri 'self'; object-src 'none'
    x-frame-options: DENY
    x-content-type-options: nosniff
    referrer-policy: strict-origin-when-cross-origin
    permissions-policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
    ```

    The extra spaces left by empty variables are harmless. `curl -sI
    https://events.conservices.test/api/health` must show the backend's
    `default-src 'none'` policy **only**.

The container log shows the start-up step:

```text
20-envsubst-on-templates.sh: Running envsubst on /etc/nginx/templates/security-headers.conf.template to /etc/nginx/snippets/security-headers.conf
20-envsubst-on-templates.sh: Running envsubst on /etc/nginx/templates/security-headers-frame-self.conf.template to /etc/nginx/snippets/security-headers-frame-self.conf
```

### Silent sign-in iframe

With tokens kept in memory, a reload signs the person in again through the
existing Keycloak session. `oidc-client-ts` does that by loading
`/silent-callback.html` in a hidden iframe of the app itself and reading
the result with `postMessage`. `frame-ancestors 'none'` and
`X-Frame-Options: DENY` refuse that iframe, so the session ends and the
person has to type a password.

`security-headers-frame-self.conf.template` is the shared policy with two
differences: `frame-ancestors 'self'` and `X-Frame-Options: SAMEORIGIN`.
Everything else, including `${EXTRA_FRAME_SRC}`, is the same. Use it only
for the silent-callback file. An exact `location` beats `location /`, so
the rest of the app stays unframeable. The HTML file is
`public/silent-callback.html` (Vite copies `public/` to the site root);
this location must not fall through to `index.html`.

```nginx
server {
    listen 8080;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location /api/ {
        proxy_pass http://backend;   # no include: the backend sets its headers
    }

    location = /config.json {
        alias /etc/conservices/config.json;
        include /etc/nginx/snippets/security-headers.conf;
        add_header Cache-Control "no-store" always;
    }

    # Hidden iframe target for oidc-client-ts silent renew.
    location = /silent-callback.html {
        include /etc/nginx/snippets/security-headers-frame-self.conf;
        add_header Cache-Control "no-cache" always;
    }

    location / {
        try_files $uri $uri/ /index.html;
        include /etc/nginx/snippets/security-headers.conf;
        add_header Cache-Control "no-cache" always;
    }
}
```

Check that page on its own. `frame-ancestors` is `'self'` and
`X-Frame-Options` is `SAMEORIGIN`. The home page still says `'none'` and
`DENY`.

```sh
curl -sI https://hr.con.example.org/silent-callback.html | grep -i -E 'content-security|x-frame'
```

```text
content-security-policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: ; font-src 'self' data:; connect-src 'self' https://auth.con.example.org   ; frame-src 'self'  https://auth.con.example.org; frame-ancestors 'self'; form-action 'self' https://auth.con.example.org; base-uri 'self'; object-src 'none'
x-frame-options: SAMEORIGIN
```

An app that still replaces placeholders by hand (Wiki today) copies
`security-headers-frame-self.conf` the same way as `security-headers.conf`
and includes that file in the same `location`.

#### Sandboxed HTML (`about:srcdoc`)

Desk shows a customer's message in a sandboxed iframe whose document is
`srcdoc`. The browser checks that frame against the page's `frame-src`.
Without `about:srcdoc` the mail pane stays blank. Set
`EXTRA_FRAME_SRC` to that token on Desk's frontend only:

=== "Docker Compose"

    ```yaml
    desk-frontend:
      environment:
        KEYCLOAK_ORIGIN: https://auth.conservices.test
        EXTRA_FRAME_SRC: "about:srcdoc"
    ```

=== "Kubernetes"

    ```yaml
    - name: EXTRA_FRAME_SRC
      value: "about:srcdoc"
    ```

The token is inserted in both snippets
(`frame-src 'self' ${EXTRA_FRAME_SRC} ${KEYCLOAK_ORIGIN}`). Empty, which
is the image default, leaves a space and adds no source. Desk's editor
is unaffected: `style-src` already allows `'unsafe-inline'`, and its
scripts are files. No other app sets `EXTRA_FRAME_SRC`.

### Troubleshooting the headers

**The browser console says *Refused to execute inline script because it violates the following Content Security Policy directive: "script-src 'self'"***
: An inline `<script>` is left in an HTML file. Move it into a file
  (step 4).

**Sign-in or uploads fail with *Refused to connect to 'https://…'***
: The origin is missing from `connect-src`. Set `KEYCLOAK_ORIGIN`,
  `S3_ORIGIN` or `EXTRA_CONNECT_SRC` on the frontend container and
  restart it.

**The policy contains `${S3_ORIGIN}` or `${EXTRA_FRAME_SRC}` literally**
: The variable is not defined in the container, or it is missing from
  `NGINX_ENVSUBST_FILTER`. Add the `ENV` defaults and the filter from
  step 2, including `EXTRA_FRAME_SRC`.

**A reload asks for the password again, and the console says framing
`/silent-callback.html` violated `frame-ancestors 'none'`**
: That location is still including `security-headers.conf`. Give the
  exact location `= /silent-callback.html` the frame-self snippet. See
  [Silent sign-in iframe](#silent-sign-in-iframe).

**Desk's mail pane is blank and the console refuses `about:srcdoc`**
: Set `EXTRA_FRAME_SRC=about:srcdoc` on Desk's frontend and restart it.
  See [Sandboxed HTML](#sandboxed-html-aboutsrcdoc).

**The log says `/etc/nginx/templates exists, but /etc/nginx/snippets is not writable`**
: The root file system is read-only. Mount an `emptyDir` at
  `/etc/nginx/snippets` (step 6). Until then nginx uses the copy baked
  into the image, which allows no outside origins.

**API responses carry two `Content-Security-Policy` headers**
: The snippet is included at `server` level or in `location /api/`. Include
  it only in the locations that serve the app (step 3).

## Google Workspace service account

1. In the Google Cloud console, create a project (or use one), enable the
   **Admin SDK API** and the **Gmail API**, and create a **service
   account**. Create a JSON key for it and store the file in your secret
   manager.
2. In the Google Admin console, open **Security → Access and data control →
   API controls → Domain-wide delegation**, add the service account's
   **client ID** and authorise exactly these scopes (only the ones the
   module needs):

    ```text
    https://www.googleapis.com/auth/admin.directory.user
    https://www.googleapis.com/auth/admin.directory.group
    https://www.googleapis.com/auth/gmail.modify
    https://www.googleapis.com/auth/gmail.settings.sharing
    ```

    `gmail.modify` covers reading, sending, labels, trash and untrash.
    `gmail.settings.sharing` is only for creating and deleting a send-as
    alias (`CreateSendAs`, `DeleteSendAs`). Authorise it for Desk. Leave
    it off for a module that never makes those two calls: they are the
    only calls that request it, and Google rejects a token when
    domain-wide delegation does not list a scope the call asks for.

3. Mount the key into the module's pod as a file from a Secret (see
   [Secrets](../operations/secrets.md#google-workspace-service-account-key))
   and set `GOOGLE_WORKSPACE_CREDENTIALS_FILE` to its path,
   `GOOGLE_WORKSPACE_ADMIN_EMAIL` to an admin account and
   `GOOGLE_WORKSPACE_DOMAIN` to the domain.

Directory calls act as the admin account; Gmail calls act as the owner of
the mailbox, so a module can only read the mailboxes it is configured for.

## Troubleshooting

**The backend stops at start-up with `DEN_LINK_ENCRYPTION_KEY is required unless APP_ENV=development`**
: Production needs the key. Generate one (above), add it to the module's
  Secret, restart. For local work set `APP_ENV=development`.

**`DEN_LINK_ENCRYPTION_KEY must be 32 bytes after base64 decoding`**
: The value is not a 32-byte key. Use `openssl rand -base64 32`; do not
  use a password or a hex string.

**`the stored Den credential cannot be decrypted (was DEN_LINK_ENCRYPTION_KEY changed …?)`**
: The key changed without keeping the old one. Put the old value into
  `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` and restart, or pair the module again.

**`ERROR: column "revoked_at" does not exist`**
: The module adopted `denlink` without the migration. Add
  `denlink.SchemaUpgrade` as a migration.

**Pairing fails with `pairing with Den at … is not allowed here`**
: The module has no `DEN_INTERNAL_URL` and the host is not in
  `DEN_ALLOWED_HOSTS`. Add Den's host there, or set `DEN_INTERNAL_URL`.

**CI job *Shared code drift* fails**
: Someone edited a generated copy, or `shared/go` changed. Run the sync
  script for the module and commit the result; if the module's change was
  intended, make it in `shared/go` first.

**`go build` fails after syncing with `no required module provides package golang.org/x/oauth2/google`**
: Run `go mod tidy` in the module's backend; the package needs a dependency
  the module did not have.

**Google answers `unauthorized_client` when the module signs in**
: Domain-wide delegation is missing or lacks a scope. Compare the scopes
  in the Admin console with the list above; changes can take a few minutes.
