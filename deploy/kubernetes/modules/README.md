# Modules on Kubernetes

Each module runs in its own namespace, `conservices-<module>`, labelled
`conservices.io/tier: module` so the platform's NetworkPolicies let its
backend reach Den, PostgreSQL and S3 storage. `stash/` is the worked example;
copy its shape for the others.

| Module | Namespace | Images (`ghcr.io/aglelectronics/…`) | Migrations | Status |
| --- | --- | --- | --- | --- |
| Stash | `conservices-stash` | `stash-backend`, `stash-frontend` | run by the backend at start | manifests here; Helm setup in [standalone Kubernetes](../../../docs/getting-started/standalone-kubernetes.md) |
| HR | `conservices-hr` | `hr-backend`, `hr-frontend`, `hr-migrate` | `hr-migrate` initContainer | [Set up HR](../../../docs/modules/hr/setup.md) |
| Rally (events) | `conservices-rally` | `rally-backend`, `rally-frontend`, `rally-migrate`, `rally-submit` | `rally-migrate` initContainer | [Set up Rally](../../../docs/modules/rally/setup.md) |
| Finance | `conservices-finance` | `finance-backend`, `finance-frontend`, `finance-migrate` | `finance-migrate` initContainer | [Set up Finance](../../../docs/modules/finance/setup.md) |
| Learn | `conservices-learn` | `learn-backend`, `learn-frontend`, `learn-migrate` | `learn-migrate` initContainer | [Set up Learn](../../../docs/modules/learn/setup.md) |
| Wiki | `conservices-wiki` | `wiki-backend`, `wiki-frontend`, `wiki-migrate` | `wiki-migrate` initContainer | [Set up Wiki](../../../docs/modules/wiki/setup.md) |
| Desk | `conservices-desk` | `desk-backend`, `desk-frontend`, `desk-migrate` | `desk-migrate` initContainer | [Set up Desk](../../../docs/modules/desk/setup.md) |
| Tasks | `conservices-tasks` | `tasks-backend`, `tasks-frontend`, `tasks-migrate` | `tasks-migrate` initContainer | [Set up Tasks](../../../docs/modules/tasks/setup.md) |

The environment each module needs is in the root `docker-compose.yml`
(its profile). Cross-module calls that need extra NetworkPolicy rules are
listed in [Network policies](../../../docs/operations/network-policies.md).
