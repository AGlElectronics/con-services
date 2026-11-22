# Stats configuration

The 1.1 scaffold reads environment variables when the backend starts. It
refuses invalid values instead of silently changing them.

| Variable | Default | Required | What it does |
| --- | --- | --- | --- |
| `AUTH_MODE` | `dev` | Yes | Authentication mode. Only `dev` is accepted by this scaffold; OIDC is not implemented yet. |
| `HTTP_ADDR` | `:8080` | No | Backend listen address inside the container. |
| `STATS_POLL_INTERVAL` | `2m` | No | Time between pulls. Must be between `1m` and `5m`, inclusive. |
| `STATS_PULL_TIMEOUT` | `10s` | No | Timeout for one source request. Must be greater than zero and no more than `30s`. |
| `STATS_SOURCES` | empty | No | Comma-separated `module=url` entries. An empty value runs the dashboard with no sources. |
| `STATS_SERVICE_TOKEN` | empty | No | Bearer token sent to each internal source. It is a secret when set; the checked-in Compose value is dev-only. |

Example:

```dotenv
AUTH_MODE=dev
HTTP_ADDR=:8080
STATS_POLL_INTERVAL=2m
STATS_PULL_TIMEOUT=10s
STATS_SOURCES=desk=http://desk-backend:8080/api/internal/stats,learn=http://learn-backend:8080/api/internal/stats
STATS_SERVICE_TOKEN=change-me-dev-only
```

The one-token setting is intentionally temporary. Before a production release,
Stats needs per-source credentials, OIDC for dashboard users, Kubernetes
Secrets or an external secret manager, and NetworkPolicy rules for each pull.

## Troubleshooting

**`invalid STATS_SOURCES entry`**
: Use `module=http://host/path`; separate entries with commas. Module names
  must be unique and URLs must use HTTP or HTTPS.

**`AUTH_MODE="oidc" is not supported`**
: Use `dev` for the scaffold. Do not expose this build publicly. OIDC belongs
  to the production implementation, not this placeholder.
