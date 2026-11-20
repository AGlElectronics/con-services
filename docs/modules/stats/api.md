# Stats API

Stats follows the shared [API conventions](../../concepts/api-conventions.md)
where the scaffold implements them. The 1.1 build accepts `AUTH_MODE=dev` only
and is for a trusted local machine; it has no production user authentication.

## Dashboard snapshot

### `GET /api/v1/dashboard`

Returns the latest aggregate snapshot. In the development scaffold, any local
caller may use it; no role or bearer token is required. It has no request body.

```sh
curl http://localhost:8170/api/v1/dashboard
```

```json
{
  "version": "dev",
  "generated_at": "2026-11-17T15:30:00Z",
  "poll_interval_seconds": 120,
  "summary": {
    "configured_sources": 1,
    "reporting_sources": 1,
    "stale_sources": 0,
    "metrics": 2,
    "count_total": 16
  },
  "sources": [
    {
      "name": "desk",
      "status": "ok",
      "generated_at": "2026-11-17T15:29:55Z",
      "last_success": "2026-11-17T15:29:56Z",
      "metrics": [
        {
          "key": "open_conversations",
          "label": "Open conversations",
          "value": 12,
          "unit": "count"
        },
        {
          "key": "waiting_conversations",
          "label": "Waiting conversations",
          "value": 4,
          "unit": "count"
        }
      ]
    }
  ]
}
```

Source status is `waiting`, `ok`, `error` or `stale`. A failed pull leaves the
last successful metrics in place and adds `error`. A source is stale before
its first successful pull or when its last success is older than two polling
intervals.

Responses:

- `200 OK` with the snapshot, including when no sources are configured.
- `405 Method Not Allowed` for methods other than `GET`.

The response has `Cache-Control: no-store`.

## Health endpoints

### `GET /livez`

No authentication or role is required. It reports that the process is alive.

```sh
curl http://localhost:8170/livez
```

```json
{"status":"ok"}
```

Responses: `200 OK`, or `405 Method Not Allowed` for other methods.

### `GET /readyz`

No authentication or role is required. The in-memory scaffold has no database,
so readiness means the server configuration was valid and the process started.
Source failures do not make the server unready.

```sh
curl http://localhost:8170/readyz
```

```json
{"status":"ok","version":"dev"}
```

Responses: `200 OK`, or `405 Method Not Allowed` for other methods.

## Internal module pull contract

For each `module=url` in `STATS_SOURCES`, Stats calls:

```http
GET /api/internal/stats
Accept: application/json
Authorization: Bearer <STATS_SERVICE_TOKEN>
```

The exact path is configurable in the URL. The endpoint is internal: it must
not be routed publicly. A module must authenticate the service token and return
only organisation-level aggregate values. It must not return names, account
identifiers, email addresses, per-person values, cluster health, host metrics
or other infrastructure telemetry.

The module name must equal the configured name. Metric keys must be unique
inside one response. Values must be finite JSON numbers. `unit` is a stable
machine-readable word such as `count`, `hours`, `percent` or `currency_minor`;
Stats sums only metrics whose unit is exactly `count` for its placeholder
summary.

Example module response:

```json
{
  "schema_version": 1,
  "module": "desk",
  "generated_at": "2026-11-17T15:29:55Z",
  "metrics": [
    {
      "key": "open_conversations",
      "label": "Open conversations",
      "value": 12,
      "unit": "count"
    }
  ]
}
```

Stats accepts:

- `200 OK` with a JSON body up to 1 MiB matching schema version 1.

Stats treats these as a source failure and keeps the last successful snapshot:

- `401 Unauthorized` or `403 Forbidden`: token missing or rejected.
- `404 Not Found`: source contract is not enabled on that module.
- `429 Too Many Requests`: module is rate limiting pulls.
- any `5xx`: module is temporarily unavailable.
- timeout, malformed JSON, unsupported `schema_version`, a mismatched module
  name, duplicate keys, missing fields or non-finite values.

Example implementation check from inside the Docker network:

```sh
curl \
  -H "Authorization: Bearer change-me-dev-only" \
  http://desk-backend:8080/api/internal/stats
```

## Contract evolution

Adding optional fields is compatible within `schema_version: 1`; consumers
must ignore fields they do not know. Removing or changing a field requires a
new schema version. Stats 1.1 supports version 1 only.
