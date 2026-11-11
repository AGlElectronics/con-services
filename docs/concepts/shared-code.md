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
| `authbase` | The `AUTH_MODE`/`APP_ENV` start-up guard, CORS headers (dev headers only in dev mode), a JSON body decoder with a size limit, a rate limiter, security headers for API responses, and the person's identity key. | `AUTH_MODE`, `APP_ENV` |
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
| `denlink.FromEnv(slug, version, os.Getenv) (Config, error)` | Read every setting; fails without `DEN_LINK_ENCRYPTION_KEY` outside `APP_ENV=development`. |
| `denlink.Open(pool, cfg, log) (*Client, error)` | `New` that returns the configuration error, so the backend refuses to start. `New` still works; then `Restore` and `Pair` return the error. |
| `client.Revoked() bool`, `Status.Revoked`, `State.Revoked` | Den rejected the credential; an admin must pair again. |
| `denlink.ErrRevoked` | What `Sync` and the preferences calls return after a `401` from Den. |
| `Config.HostAllowed(host)` | Whether a pasted pairing URL may point at that host. |
| `denlink.Schema`, `denlink.SchemaUpgrade` | The `den_link` table for a new module, and the migration an existing one needs (adds `revoked_at`). |

What changes in the module's API is on [Pairing](pairing.md#the-den-connection-api-in-each-module).

### authbase

| Function | Use |
| --- | --- |
| `authbase.FromEnv(os.Getenv) (Config, error)` | `AUTH_MODE` (default `oidc`) and `APP_ENV` (default `production`); fails for `AUTH_MODE=dev` unless `APP_ENV=development`. |
| `cfg.AllowedHeaders(extra...)`, `cfg.CORS(CORSOptions)` | CORS: `X-Dev-User` and `X-Dev-Groups` are allowed only in dev mode. |
| `cfg.StripDevHeaders(next)` | Middleware that deletes the dev headers from every request outside dev mode. |
| `authbase.DecodeJSON(w, r, &dst, DecodeOptions{MaxBytes, DisallowUnknownFields, RequireJSONContentType})` | Decode a request body with `http.MaxBytesReader` (default 1 MiB). Errors are `413 request_too_large`, `415 unsupported_media_type` or `400 bad_request`; write them with `authbase.WriteDecodeError`. |
| `authbase.NewRateLimiter(RateLimitOptions{Rate, Burst, Key})`, `.Middleware` | An in-memory token bucket per client IP (`authbase.ClientIP`) or per person (`authbase.BySubject`). Answers `429 rate_limited` with `Retry-After`. Each replica counts on its own. `authbase.ParseRate("60/m")` reads a rate from a setting. |
| `authbase.SecurityHeaders(next)` | `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY` and `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'` on every API response. |
| `authbase.UserKey{Issuer, Subject}` | A person's identity across Con Services (`iss` + `sub`), with `String`, `ParseUserKey` and `IsZero`. |

A `429` looks like this:

```text
HTTP/1.1 429 Too Many Requests
Retry-After: 2
Content-Type: application/json

{"error":{"code":"rate_limited","message":"Too many requests; try again in 2 seconds."}}
```

### gworkspace

Modules depend on the interfaces `gworkspace.Directory`, `gworkspace.Gmail`
(or both, `gworkspace.Workspace`), create the real client with
`gworkspace.New(cfg, gworkspace.Options{})`, and use
`gworkspace.NewFake(domain)` in tests.

| Interface | Methods |
| --- | --- |
| `Directory` | `GetUser`, `CreateUser`, `SetSuspended`, `DeleteUser`, `ListGroups`, `GetGroup`, `CreateGroup`, `DeleteGroup`, `ListMembers`, `AddMember`, `RemoveMember` |
| `Gmail` | `ListMessages`, `GetMessage`, `SendMessage`, `ModifyLabels`, `TrashMessage` |

The client refuses users, groups and mailboxes outside
`GOOGLE_WORKSPACE_DOMAIN`, so a mistake in a module cannot create accounts
in another domain. `gworkspace.IsNotFound(err)` and
`gworkspace.IsConflict(err)` tell the common Google errors apart. Setting
up the service account is described [below](#google-workspace-service-account).

## Configuration reference

These are the settings the packages read. A module that adopts a package
lists the same rows on its own configuration page.

| Variable | Default | Required | Package | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `production` | no | `authbase`, `denlink` | Only `development` relaxes the rules: allows `AUTH_MODE=dev`, an unencrypted Den credential and `http://` pairing URLs to the development hosts. Anything else counts as production. |
| `AUTH_MODE` | `oidc` | no | `authbase` | `oidc` verifies Keycloak tokens. `dev` trusts `X-Dev-User`/`X-Dev-Groups` and is refused unless `APP_ENV=development`. |
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

**groupmatch**: replace the module's own group comparison, store grants with
`NewGrant` (a migration normalising existing grants), stop merging `roles`
into groups, and add the three `OIDC_GROUP*` settings to the configuration
page.

**authbase**: call `authbase.FromEnv` at start-up (this changes the
defaults to `AUTH_MODE=oidc` and `APP_ENV=production`; the module's
`.env.example` and Compose service then set `APP_ENV=development`
explicitly), mount `StripDevHeaders` and `SecurityHeaders` first on the API
router, and use `DecodeJSON` for request bodies.

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

The web apps' nginx gets its headers from one snippet,
`shared/nginx/security-headers.conf`: a Content Security Policy
(`default-src 'self'`, with placeholders for the Keycloak and Den origins),
`X-Frame-Options: DENY` and `frame-ancestors 'none'`, `nosniff`,
`Referrer-Policy: strict-origin-when-cross-origin` and a
`Permissions-Policy`. HSTS is set at the Gateway or Caddy, not here. The
comments in the file say how to fill in the placeholders and where to
`include` it; nginx forgets inherited `add_header` lines in every
`location` that has its own, so include it there too. Check the result:

```sh
curl -sI https://hr.conservices.test/ | grep -i -E 'content-security|x-frame|referrer|permissions|nosniff'
```

```text
content-security-policy: default-src 'self'; script-src 'self'; … frame-ancestors 'none'; …
x-frame-options: DENY
x-content-type-options: nosniff
referrer-policy: strict-origin-when-cross-origin
permissions-policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
```

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
    ```

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
