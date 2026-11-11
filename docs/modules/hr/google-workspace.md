# Google Workspace

HR can give every onboarded person a **Google Workspace** account (an email
address and Google apps in your organisation's domain), keep a Google Group
per department in step with HR, and close the account again when the
person leaves.

!!! warning "Not available in HR 1.0.0"
    HR 1.0.0 contains the connector's logic, settings and admin pages, but
    ships **without the Google Workspace client** (the part that talks to
    Google). The Settings page shows the connector as unavailable, and with
    `GOOGLE_WORKSPACE_CREDENTIALS_FILE` set HR logs a warning
    (`GOOGLE_WORKSPACE_CREDENTIALS_FILE is set, but this HR version has no
    Google Workspace client yet`) and carries on without it.
    You can prepare Google Cloud and the secret now; the connector starts
    working with the HR release that adds the client.

## What the connector does

Once available and turned on (**Settings → Google Workspace**):

| When | What happens in Google Workspace |
| --- | --- |
| An onboarding is completed | HR creates the account `<organisation email>` (from the person's profile or the **Organization email name** template), puts it in the configured organisational unit, adds it to the department's group `dept-<name>@<domain>`, and emails the person how to set their password. |
| Someone joins or leaves a department | The department's Google Group gets exactly the accounts of its active members. |
| Someone is offboarded | HR **suspends** the account and schedules its deletion **Delete after** days later (default 30). |
| **Reminder** days before the deletion (default 7) | HR admins get an email, so they can move data (Drive files, mail) out first. |
| The scheduled day | The housekeeping task deletes the suspended account. **Delete now** on **Settings → Google Workspace** does it earlier. |

Problems never block an onboarding: HR shows a warning and keeps the error
on the account row.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| **Enabled** | off | Turns the connector on (only possible when it is available). |
| **Domain** | the organisation email domain | Domain of the accounts, for example `volunteers.example.org`. |
| **Admin email** | none | A Workspace super admin the service account acts as (domain-wide delegation, below). |
| **Organisational unit** | `/` | Where new accounts go, for example `/Volunteers`. |
| **Delete after (days)** | `30` | How long a suspended account is kept after an offboarding. |
| **Reminder (days)** | `7` | When HR admins are reminded before a deletion. |

## Prepare Google Cloud

You need a Google Workspace super admin and a Google Cloud project.

1. **Create a project.** In the [Google Cloud console](https://console.cloud.google.com/):
   **Select a project → New project**, name it for example
   `conservices-hr`.
2. **Turn on the Admin SDK API.** **APIs & Services → Library**, search
   **Admin SDK API**, click **Enable**.
3. **Create a service account.** **IAM & Admin → Service accounts →
   Create service account**, name `hr-workspace`. Grant it no project
   roles.
4. **Create a key.** Open the service account → **Keys → Add key → Create
   new key → JSON**. The browser downloads a file such as
   `conservices-hr-1a2b3c.json`. This file is a secret: it can create,
   suspend and delete accounts in your domain. Do not email it or commit
   it; put it straight into your secret manager (next section) and delete
   the download.
5. **Allow domain-wide delegation.** Copy the service account's **Client
   ID** (a number). In the [Google Admin console](https://admin.google.com/):
   **Security → Access and data control → API controls → Manage
   domain-wide delegation → Add new**, paste the client ID and these
   scopes (comma-separated):

    ```text
    https://www.googleapis.com/auth/admin.directory.user,https://www.googleapis.com/auth/admin.directory.group,https://www.googleapis.com/auth/admin.directory.group.member
    ```

6. **Create the organisational unit** you want new accounts in (for
   example `/Volunteers`) under **Directory → Organisational units**.

## Give HR the key (Kubernetes)

The chart mounts the key from its own Secret, `hr-google-workspace`, with
the key `credentials.json`. Store it in your secret manager and let the
External Secrets Operator create the Secret
([Secrets](../../operations/secrets.md)):

```sh
vault kv put secret/conservices/hr/google-workspace credentials.json=@conservices-hr-1a2b3c.json
```

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: hr-google-workspace
  namespace: conservices-hr
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: SecretStore
  target:
    name: hr-google-workspace
  data:
    - secretKey: credentials.json
      remoteRef:
        key: conservices/hr/google-workspace
        property: credentials.json
```

Then turn it on in your HR values and upgrade:

```yaml
googleWorkspace:
  enabled: true
  existingSecret: hr-google-workspace
```

```sh
helm upgrade hr deploy/charts/hr -n conservices-hr -f hr-values.yaml
```

The chart then:

- mounts the key read-only at `/etc/conservices-google/credentials.json`
  and sets `GOOGLE_WORKSPACE_CREDENTIALS_FILE` to that path;
- opens egress from HR's backend to `admin.googleapis.com` and
  `oauth2.googleapis.com` on port 443. With Cilium
  (`networkPolicy.gateway.cilium: true`, the default) this is a
  `CiliumNetworkPolicy` named `hr-google-apis` matching those host names.
  On another CNI, list Google's address ranges instead
  ([goog.json](https://www.gstatic.com/ipranges/goog.json)):

    ```yaml
    networkPolicy:
      googleApis:
        cidrs: ["142.250.0.0/15", "172.217.0.0/16"]   # example; use the current list
    ```

Check that the key is mounted:

```sh
kubectl exec -n conservices-hr deploy/hr-backend -- ls /etc/conservices-google
```

```text
credentials.json
```

**Docker:** mount the file read-only into the backend container and set
`GOOGLE_WORKSPACE_CREDENTIALS_FILE` to its path, for example
`/run/secrets/google-workspace.json`.

**Rotate the key:** create a new key for the service account, store it in
the secret manager, restart HR
(`kubectl rollout restart -n conservices-hr deploy/hr-backend`), then
delete the old key in Google Cloud.

## Troubleshooting

**The Settings page says the connector is unavailable.** Expected in HR
1.0.0 (see the warning at the top). In a later release: the key is not
mounted; check `GOOGLE_WORKSPACE_CREDENTIALS_FILE` and the Secret.

**The backend log says "this HR version has no Google Workspace client
yet".** The same: the key is set, but this HR version has no Workspace
client. Nothing is broken.

**Accounts are not created and the warning mentions the domain.** Set
**Domain** (or the organisation email domain) in HR's settings; HR only
creates accounts inside that domain.

**`Not Authorized to access this resource/api` or `unauthorized_client`.**
Domain-wide delegation is missing a scope or uses another client ID
(step 5), or **Admin email** is not a super admin.

**Timeouts calling Google.** The egress rule is missing: with Cilium check
`kubectl get ciliumnetworkpolicy -n conservices-hr hr-google-apis`; on
other CNIs set `networkPolicy.googleApis.cidrs`.
