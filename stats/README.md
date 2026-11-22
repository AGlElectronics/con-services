# Stats

> [!WARNING]
> Stats is a 1.1 development scaffold. It is not ready for production.

Stats collects module-owned aggregate numbers on a short interval and shows
them in one dashboard. This scaffold keeps snapshots in memory and includes no
cluster or infrastructure metrics, person-level data, or public signage API.

Documentation: [Stats on the Con Services site](https://aglelectronics.github.io/con-services/modules/stats/).
Changes: [CHANGELOG.md](CHANGELOG.md).

## Run locally

From the root `con-services` workspace:

```sh
docker compose --profile stats up --build stats-frontend
```

Open <http://localhost:3011>. The API is also available at
<http://localhost:8170/api/v1/dashboard>.

The empty-source dashboard is expected. To try a module endpoint, set
`STATS_SOURCES` and `STATS_SERVICE_TOKEN` in the root `.env`; see the
[setup guide](https://aglelectronics.github.io/con-services/modules/stats/setup/).

Run the backend tests with:

```sh
cd stats/backend
go test ./...
```
