# Stats

Stats is the Con Services aggregate dashboard. Each participating module owns
and calculates its own operational numbers; Stats pulls those numbers every
one to five minutes and displays the latest successful snapshots together.

The 1.1 scaffold is for local development. It has a Go backend and a static
dashboard shell, stores snapshots only in memory, and supports `AUTH_MODE=dev`
only. It does **not** collect cluster or infrastructure telemetry, person-level
data, or provide a public signage feed.

## Current scope

- Pull a small aggregate JSON document from configured module endpoints.
- Keep the last successful snapshot if a later pull fails.
- Show source health, total metric count and the sum of values whose unit is
  `count`.
- Expose health checks and one dashboard endpoint.

See [Setup](setup.md), [Configuration](configuration.md), the
[API and internal pull contract](api.md) and
[Personal data](../../operations/personal-data.md#stats).
