# Modules on Kubernetes

Each module runs in its own namespace, `conservices-<module>`, labelled
`conservices.io/tier: module` so the platform's NetworkPolicies let its
backend reach Den, PostgreSQL and S3 storage. `stash/` is the worked example;
copy its shape for the others.

| Module | Namespace | Images (`ghcr.io/aglelectronics/…`) | Migrations | Status |
| --- | --- | --- | --- | --- |
| Stash | `conservices-stash` | `stash-backend`, `stash-frontend` | run by the backend at start | manifests here |
| HR | `conservices-hr` | `hr-backend`, `hr-frontend`, `hr-migrate` | `hr-migrate` Job / initContainer | docs coming soon |
| Rally (events) | `conservices-rally` | `rally-backend`, `rally-frontend`, `rally-migrate` | `rally-migrate` | docs coming soon |
| Finance | `conservices-finance` | `finance-backend`, `finance-frontend`, `finance-migrate` | `finance-migrate` | docs coming soon |
| Learn | `conservices-learn` | `learn-backend`, `learn-frontend`, `learn-migrate` | `learn-migrate` | docs coming soon |
| Wiki | `conservices-wiki` | `wiki-backend`, `wiki-frontend`, `wiki-migrate` | `wiki-migrate` | docs coming soon |
| Desk | `conservices-desk` | `desk-backend`, `desk-frontend`, `desk-migrate` | `desk-migrate` | Helm chart `deploy/charts/desk`; docs: modules/desk/setup |
| Tasks | `conservices-tasks` | `tasks-backend`, `tasks-frontend`, `tasks-migrate` | `tasks-migrate` | docs coming soon |

The environment each module needs is in the root `docker-compose.yml`
(its profile). Cross-module calls that need extra NetworkPolicy rules are
listed in the docs: operations/network-policies.
