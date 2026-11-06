# Logs, health and monitoring

**Goal:** know whether every part of Con Services is healthy, find the log
line behind a failed request, and set up monitoring and alerts that catch
real problems (a pod crash-looping, a backup that did not run, a full disk).

!!! info "What exists today"
    Every backend has **health endpoints** and writes **structured JSON
    logs**. No Con Services component exposes Prometheus metrics yet (there
    is no `/metrics` endpoint). Monitoring therefore uses Kubernetes'
    own metrics, the health endpoints, the logs, and the metrics of the
    pieces around Con Services (ingress controller, PostgreSQL, CNI).

## Health endpoints

Kubernetes already uses these as probes. You can call them yourself to
check a component by hand.

| Component | Liveness | Readiness | Human-friendly | Reachable from outside |
| --- | --- | --- | --- | --- |
| `den-backend` | `/livez` | `/readyz` (pings the database) | `/api/health` | `/api/health` through `https://den.<domain>` |
| `den-operator` | `/livez` (empty `204`) | none | none | No, only from `den-backend` |
| `stash-backend` | TCP 8080 | `/api/health` | `/api/health` | `/api/health` through the module address |
| HR, Finance backends | `/livez` | `/readyz` | none | No |
| Rally, Learn, Wiki, Desk, Tasks backends | `/livez` | `/readyz` | `/api/health` | `/api/health` through the module address |
| Every `*-frontend` | `/` on 8080 | `/` on 8080 | | Yes |
| `keycloak` | `/health/live` on 9000 | `/health/ready` on 9000 | | No (management port) |
| `postgres` | `pg_isready` | `pg_isready` | | No |

`/livez` never touches the database, so a database outage marks pods
*not ready* (no traffic) instead of restarting them in a loop.

Check Den from your computer:

```sh
curl -s https://den.con.example.org/api/health
```

```json
{"database":"ok","status":"ok","uptime_sec":5321,"version":"1.0.0-1"}
```

When the database is unreachable the answer is `503` with
`"status":"degraded","database":"down"`.

Check an endpoint that is not published (here HR's readiness) from inside
the module's own namespace, through its frontend pod, which the network
policies allow to reach the backend:

```sh
kubectl exec -n conservices-hr deploy/hr-frontend -- wget -qO- http://hr-backend:8080/readyz
```

## Logs

Every Go program in Con Services (all backends, migrators and Den's
operator) logs **one JSON object per line** to standard output when
`APP_ENV` is anything but `development`. The manifests and charts set
`APP_ENV=production`, so production logs are always JSON. Den's operator
adds `"service":"den-operator"` to every line.

A request line from Den's backend looks like this:

```json
{"level":"info","request_id":"csv0q2h5lhm4c7d3o1kg","method":"GET","path":"/api/v1/me","status":200,"size":412,"duration":3.215,"time":"2026-11-06T14:02:11Z","message":"http"}
```

`duration` is in milliseconds.

The `request_id` is also sent back to the browser as the `X-Request-ID`
response header. When someone reports an error, ask for that header (browser
developer tools → Network → the failed request → Headers) and search for
it:

```sh
kubectl logs -n conservices-den deploy/den-backend --since=24h | grep csv0q2h5lhm4c7d3o1kg
```

### Reading logs with kubectl

| You want | Command |
| --- | --- |
| Follow a component live | `kubectl logs -n conservices-den deploy/den-backend -f` |
| The migration step | `kubectl logs -n conservices-den deploy/den-backend -c migrate` |
| The run before the last crash | `kubectl logs -n conservices-den deploy/den-backend --previous` |
| Only errors (needs `jq`) | `kubectl logs -n conservices-den deploy/den-backend --since=1h \| jq -c 'select(.level=="error")'` |
| Every Con Services pod at once (needs [stern](https://github.com/stern/stern)) | `stern -A -l app.kubernetes.io/part-of=conservices --since 10m` |
| Kubernetes' own view (scheduling, probes, OOM) | `kubectl get events -n conservices-den --sort-by=.lastTimestamp` |

### Keeping logs

`kubectl logs` only shows what the node still has, and nothing after a pod
is deleted. For a real installation, ship logs to a log store:

1. Install a collector as a DaemonSet, for example
   [Grafana Alloy](https://grafana.com/docs/alloy/) or
   [Fluent Bit](https://docs.fluentbit.io/), sending to Loki,
   Elasticsearch/OpenSearch or your cloud's log service.
2. Select the Con Services pods by namespace (`conservices-*`) or by the
   label `app.kubernetes.io/part-of=conservices`.
3. Parse the line as JSON so `level`, `status`, `path` and `request_id`
   become searchable fields.
4. Keep at least 30 days, longer if your organisation has audit rules.

Collectors read log files from the node, not over the network, so they need
no NetworkPolicy changes in the Con Services namespaces.

!!! warning "Logs can contain personal data"
    Request paths can contain IDs and names of people. Treat the log store
    like the database: restrict who can read it and set a retention period.

## Monitoring: what to scrape

Since the Con Services programs have no metrics endpoint, scrape the things
around them. With the [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
Helm chart you get most of this out of the box.

| Source | What it tells you | How |
| --- | --- | --- |
| **kube-state-metrics** | Pod restarts, pods not ready, Deployments with fewer ready replicas than wanted. | Part of kube-prometheus-stack. |
| **kubelet / cAdvisor** | CPU and memory per container, compared with the limits; volume usage. | Part of kube-prometheus-stack. |
| **Ingress controller** | Requests, `5xx` rate and latency per host (`den.`, `auth.`, each module). | ingress-nginx: `controller.metrics.enabled=true` and a ServiceMonitor; other controllers have their own. |
| **Blackbox exporter** | Whether `https://<host>/api/health` answers `200` from outside, and when the TLS certificate expires. | [prometheus-blackbox-exporter](https://github.com/prometheus/blackbox_exporter) with an HTTP probe per published address. |
| **PostgreSQL** | Connections per database, database size, replication lag. | Your provider's monitoring, CloudNativePG's built-in metrics, or [postgres_exporter](https://github.com/prometheus-community/postgres_exporter). |
| **Keycloak** | Logins, failed logins, sessions. | Set `KC_METRICS_ENABLED=true`; metrics appear on port 9000 at `/metrics`. Needs a NetworkPolicy rule (below). |
| **Cilium / Hubble** | Dropped connections per namespace: the first sign of a missing policy rule. | Cilium's Helm values `prometheus.enabled=true`, `hubble.metrics.enabled={dns,drop,flow}`. |

Probing the published addresses through the ingress controller needs no
change to the Con Services network policies. Scraping a pod **directly**
(Keycloak's port 9000, for example) does, because every namespace denies
incoming traffic by default. Add an ingress rule for your monitoring
namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: keycloak-metrics-from-monitoring
  namespace: conservices-identity
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: keycloak
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9000
```

## Alerts worth having

Start with these; each one points at a real problem an operator must act on.
Example rules for the Prometheus Operator:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: conservices
  namespace: monitoring
spec:
  groups:
    - name: conservices
      rules:
        - alert: ConServicesPodCrashLooping
          expr: increase(kube_pod_container_status_restarts_total{namespace=~"conservices-.*"}[15m]) > 3
          for: 5m
          labels: { severity: warning }
          annotations:
            summary: "{{ $labels.namespace }}/{{ $labels.pod }} restarted more than 3 times in 15 minutes"
        - alert: ConServicesDeploymentUnavailable
          expr: kube_deployment_status_replicas_available{namespace=~"conservices-.*"} == 0
          for: 5m
          labels: { severity: critical }
          annotations:
            summary: "{{ $labels.namespace }}/{{ $labels.deployment }} has no ready pod"
        - alert: ConServicesEndpointDown
          expr: probe_success{job="blackbox", instance=~"https://.*conservices.*|https://.*example.org.*"} == 0
          for: 5m
          labels: { severity: critical }
          annotations:
            summary: "{{ $labels.instance }} does not answer"
        - alert: ConServicesCertificateExpiring
          expr: probe_ssl_earliest_cert_expiry - time() < 14 * 86400
          labels: { severity: warning }
          annotations:
            summary: "TLS certificate of {{ $labels.instance }} expires in less than 14 days"
        - alert: ConServicesMemoryNearLimit
          expr: |
            max by (namespace, pod, container) (container_memory_working_set_bytes{namespace=~"conservices-.*", container!=""})
              / max by (namespace, pod, container) (kube_pod_container_resource_limits{namespace=~"conservices-.*", resource="memory"}) > 0.9
          for: 15m
          labels: { severity: warning }
          annotations:
            summary: "{{ $labels.namespace }}/{{ $labels.pod }} uses over 90% of its memory limit"
```

Adjust the `instance` pattern to your probe targets.

### Backup freshness

There is no backup metric yet. Two ways to notice a missing backup:

- **Den's admin console** shows a warning banner on every admin page when
  the last backup failed, there has never been one, or the newest
  successful one is more than 26 hours old (see
  [Backups](databases-and-backups.md#backups)). Make sure an admin looks at
  it daily during a convention.
- **Check the bucket from outside.** A small scheduled job with read-only
  keys for the backup bucket can list the newest object under `backups/` and
  alert if it is older than 26 hours, for example:

    ```sh
    mc ls --json backups/conservices-backups/backups/ \
      | jq -r '.lastModified' | sort | tail -1
    ```

    ```text
    2026-11-06T03:00:41Z
    ```

## Troubleshooting

**`kubectl logs` shows coloured text instead of JSON**
: `APP_ENV` is `development` on that pod. Set `APP_ENV=production` in the
  module's ConfigMap or values; development mode also relaxes other checks.

**The log collector sees nothing from Con Services**
: Check the collector runs on every node (`kubectl get ds -A`) and its
  selector matches `conservices-*` namespaces. Collectors read
  `/var/log/pods` on the node; they do not need network access to the pods.

**Prometheus shows the Keycloak target as `down` with `context deadline exceeded`**
: The NetworkPolicy above is missing, or your monitoring namespace has a
  different name. With Cilium, `hubble observe --namespace conservices-identity --verdict DROPPED`
  shows the blocked scrape.

**`/api/health` says `"database":"down"` but PostgreSQL is running**
: The backend cannot reach it: wrong `DATABASE_URL`, an expired password, or
  a NetworkPolicy. See [Timeouts between namespaces](../getting-started/troubleshooting.md#timeouts-between-namespaces).

**`ConServicesPodCrashLooping` fires after an upgrade**
: Usually the `migrate` initContainer failing. See
  [When the migration fails](versioning.md#when-the-migration-fails).

## Related pages

- [Running on Kubernetes](running.md): what runs where and its probes.
- [Network policies](network-policies.md): why scraping needs a rule.
- [Databases, backups and restore](databases-and-backups.md): the backup banner.
- [Troubleshooting](../getting-started/troubleshooting.md): step-by-step fixes.
