# RAGFlow Production Helm Chart

A production-oriented Helm chart for [RAGFlow](https://github.com/infiniflow/ragflow).

The chart bundled in the upstream repo (`helm/`, version `0.1.1`) is a starting
point rather than a production artifact. This chart rebuilds it around three
principles:

1. **Workload split** — the RAGFlow image is role-switchable via
   `entrypoint.sh` flags, so one image serves as an API Deployment, an executor
   StatefulSet, and a single-instance datasync Deployment, each scaling on its
   own terms.
2. **External dependencies** — metadata DB, Redis, object storage and the doc
   engine are all external; the chart manages only the application.
3. **Evidence over convention** — every structural decision below was verified
   against the v0.27.0 source and, where it matters, against the running image
   in a real cluster. The "Why" column in the table and every non-obvious
   template comment cite its source.

## Architecture

| Workload | Kind | entrypoint flags | Why this shape |
|---|---|---|---|
| `api` | Deployment | `--disable-taskexecutor --disable-datasync` | Stateless HTTP serving; scale with traffic |
| `executor` | StatefulSet | `--disable-webserver --disable-datasync` | `task_executor.py` derives its Redis consumer-group name from the hostname; stable ordinals keep the group clean. `--host-id` is pinned to the pod name |
| `datasync` | Deployment, **replicas fixed at 1** | `--disable-webserver --disable-taskexecutor` | `sync_data_source.py` holds no distributed lock (unlike the executor); a second replica would double-sync every data source. `Recreate` strategy so upgrades never overlap |
| `migration` | pre-install Job | all three disabled | DDL runs once, serialized, outside the request path |

## Chart vs upstream

Findings from reading the upstream templates and application source at
v0.27.0. Each is reproduced locally before being claimed here.

| # | Upstream behaviour | Consequence | Here |
|---|---|---|---|
| 1 | One `replicas: 1` Deployment for everything | Parsing load and HTTP serving compete; nothing scales | Three workloads |
| 2 | No probes | Traffic to unready pods; hung processes never restart | Startup/liveness/readiness on verified endpoints |
| 3 | Passwords rendered unquoted into Secrets | `12345678` becomes an int and the API server rejects the Secret; `0012345` silently becomes `5349` (octal) | Every value quoted; round-trip tested against 10 hostile passwords |
| 4 | ConfigMaps without release prefix | Two releases in one namespace overwrite each other | All names release-scoped |
| 5 | Elasticsearch initContainer `privileged: true` | Rejected under PSA baseline/restricted | Doc engine is external |
| 6 | No PDB/HPA/NetworkPolicy/ServiceAccount | No availability or policy surface | Included |
| 7 | Schema init in every pod | Concurrent DDL across replicas | Serialized hook Job |
| 8 | MySQL as the only metadata backend | PostgreSQL/GaussDB/OceanBase unsupported (the app supports all four) | All four selectable |

## Security posture — read before deploying

The stock image runs its entrypoint as **root**, and the chart defaults reflect
that instead of pretending otherwise. Verified against v0.27.0:
`entrypoint.sh` writes `/ragflow/conf/service_conf.yaml`, copies the nginx
vhost into `/etc/nginx/conf.d/`, and nginx binds `:80` — all root-owned `0755`
paths, and the image ships no non-root user. Forcing `runAsUser: 1000` makes
every pod CrashLoop within seconds.

Consequences:

- Pods will be rejected by a namespace enforcing PSA `restricted`. Deploy into
  an unlabeled or `baseline` namespace.
- The recommended hardening path is an image rebuild: create a dedicated user,
  `chown /ragflow`, move nginx to a port ≥ 1024 — then set
  `podSecurityContext` in values. The chart's security fields are passthroughs;
  no chart change needed.

## Prerequisites

Kubernetes ≥ 1.23, Helm ≥ 3.8. Everything else is **external by default**:

- Metadata DB: MySQL 8.x, PostgreSQL, OceanBase, or GaussDB
- Redis / Valkey
- S3-compatible object storage
- Doc engine: Infinity, Elasticsearch 8.x, or OpenSearch 2.x

Three of these can be installed **by the chart itself** (all default off):

| Switch | What you get | Wired automatically |
|---|---|---|
| `valkey.enabled=true` | Official Valkey chart, single replica | `REDIS_HOST` → in-cluster service |
| `postgres.builtin.enabled=true` | Official `postgres:17` image, single replica + PVC | `MYSQL_HOST` → in-cluster service (works with `metadataDb.type=postgres`) |
| `rustfs.enabled=true` | Built-in RustFS StatefulSet (S3 API) | `MINIO_HOST` → in-cluster service |
| `opensearch.enabled=true` (+ `docEngine.type=opensearch`) | Official OpenSearch chart, single node | `OS_HOST` → in-cluster service |

All credentials come from the same `existingSecret` — the built-in services
read the identical keys RAGFlow reads (`REDIS_PASSWORD`, `MINIO_*`,
`MYSQL_PASSWORD`), so there is one credential source for the whole stack.

Scaling truth in this mode: valkey/rustfs/postgres built-ins are **single
replica without HA**. They exist for evaluation and small deployments. For
production keep them off and use dedicated clusters (CloudNativePG for
Postgres, Sentinel/Cluster for Redis, a real S3 or distributed RustFS for
objects, a multi-node OpenSearch).

PostgreSQL stays external even in all-in-one mode — for production-grade
Postgres on Kubernetes use [CloudNativePG](https://cloudnative-pg.io) and
point `metadataDb.host` at it.

The image is ~3.2 GB compressed. Pre-pull or mirror it; the startupProbe
allows up to 10 minutes for a cold boot.

## Quick start

```bash
# 1. Credentials — the chart never takes plaintext passwords in values
kubectl create secret generic ragflow-credentials -n ragflow \
  --from-literal=MYSQL_PASSWORD='...' \
  --from-literal=REDIS_PASSWORD='...' \
  --from-literal=MINIO_PASSWORD='...'

# 2. Install
helm upgrade --install ragflow ./ragflow -n ragflow --create-namespace \
  -f my-values.yaml
```

Minimum values:

```yaml
existingSecret: ragflow-credentials
metadataDb:
  host: mysql.data.svc.cluster.local
  user: ragflow
redis:
  host: redis-master.data.svc.cluster.local
storage:
  minio:
    host: minio.data.svc.cluster.local
docEngine:
  type: infinity
  infinity:
    host: infinity.data.svc.cluster.local
```

## Metadata backends

`metadataDb.type` accepts `mysql`, `postgres`, `oceanbase`, `gaussdb`. In all
four cases **the password comes from `existingSecret`, never from values**.

```yaml
metadataDb:
  type: postgres        # or mysql / oceanbase / gaussdb
  host: postgres.data.svc
  port: 5432            # optional; defaults follow the type
  user: ragflow
existingSecret: ragflow-credentials
```

### Why postgres/oceanbase get an initContainer

These two backends are configured through `local.service_conf.yaml`, not env
vars, and three facts (verified in v0.27.0) make that awkward:

1. The shipped `service_conf.yaml` has **no `postgres:` section** at all.
2. `common/settings.py` resolves `DATABASE` at **module import time** via an
   unguarded `database["password"]` lookup — a missing section crashes every
   process with `KeyError: 'password'` before it can serve anything.
3. `entrypoint.sh` expands `${VAR}` **only** inside
   `service_conf.yaml.template`; `local.service_conf.yaml` is read verbatim.

So the chart adds a `render-service-conf` initContainer: it reads
`MYSQL_PASSWORD` from the Secret via the environment, writes a properly quoted
YAML file into a shared `emptyDir`, and the main container mounts that single
file by subPath (so the 17 other files in `/ragflow/conf` survive). The
password never appears in values, ConfigMaps, or rendered manifests.

Quoting is not cosmetic: unquoted, `0012345` parses as int `5349` (octal),
`yes` as `True`, `&x`/`*x` as YAML anchors.

`mysql` and `gaussdb` are configured purely through env vars and get no
initContainer — asserted in the negative tests.

### Admin server caveat

`admin/server/config.py` has `case "mysql"` but no `case "postgres"`, so the
Admin panel will not show metadata-DB status on a PostgreSQL deployment. The
main service is unaffected; `api.adminServer.enabled` defaults to `false`.

## Probes

Verified against `api/apps/restful_apis/system_api.py`, both unauthenticated:

- `/api/v1/system/ping` → liveness. No dependency checks, so a transient DB
  blip never kills a healthy container.
- `/api/v1/system/healthz` → readiness. Checks db + redis + doc_engine +
  storage; 500 unless all four pass.

The executor/datasync probes use `pgrep -f "[r]ag/svr/..."` — the character
class is load-bearing: without it, pgrep matches the probe's own command line
and the probe can never fail.

Boot ordering is owned by a 10-minute startupProbe: `ensure_db_init()` runs
before any worker spawns and can be slow on a cold cluster; Kubernetes holds
liveness while the startupProbe is pending, so initialization is never
interrupted by a probe race.

## Scaling

`api` scales on CPU/memory via the built-in HPA. For `executor`, throughput is
`replicas × workers`; CPU is a poor proxy for parsing backlog, so drive it from
Redis queue depth with KEDA — see `ci/values-keda-example.yaml` (the streams
are `te.1.common` and `te.0.common`, consumer group
`rag_flow_svr_task_broker`; RAGFlow uses Redis Streams, hence the
`redis-streams` scaler).

`executor.terminationGracePeriodSeconds` defaults to 4980s: a single parse has
a hard 80-minute timeout (`@timeout(60 * 80, 1)` on `build_chunks`). Scaling in
earlier aborts in-flight tasks; Redis redelivers them, but you pay for
duplicate parsing.

## Validation

```bash
make verify            # lint × 3 + kubeconform -strict + 28 negative assertions
make verify-image      # 17 design-assumption checks against the real image
```

`ci/negative-tests.sh` asserts the chart **refuses** to render on missing
credentials, unknown backend types, or missing hosts; that no password ever
appears in rendered output; and that postgres/oceanbase get the render
initContainer while mysql/gaussdb do not.

`ci/verify-image-assumptions.sh` checks the design assumptions (entrypoint
flags, probe routes, distributed-lock absence, `PooledDatabase` enum) against
the actual image, so a version bump that breaks one fails loudly.

`ci/e2e-initcontainer.sh` runs the chart's **actual rendered** init script in
the real image inside a cluster and asserts RAGFlow's own config loader reads
the password back as an exact string.

`ci/verify-orchestration.sh` settles the live-cluster claims: stable
StatefulSet ordinals, `host-id` = pod name, worker count, datasync singleton
under `Recreate`, role isolation — and, via a negative control, that the exec
probe can actually report unhealthy.

`ci/e2e-deploy.sh` is the full lifecycle: it creates its own kind cluster,
installs the chart, and asserts install → readiness → migration hook →
preflight → rendered config → HTTP serving → upgrade → datasync-singleton
invariant → uninstall (only the documented hook resources remain — Helm does
not track hook resources in the release manifest, per
[helm/helm#9206](https://github.com/helm/helm/issues/9206)). Stub image by
default for speed; `REAL_IMAGE=1` runs it against the real RAGFlow image.

## Known gaps

- **No metrics endpoint.** RAGFlow ships no `/metrics` route and no Prometheus
  instrumentation (verified in v0.27.0), so the chart intentionally has no
  ServiceMonitor. Scrape the Kubernetes API for pod-level signals.
- **Logs are ephemeral** (`/ragflow/logs` in-container). Use a node-level
  collector.
- **`readOnlyRootFilesystem` cannot be enabled** with the stock image
  (runtime writes to `/ragflow/conf`, `/ragflow/logs`, `/var/log/nginx`,
  `/var/run`).
- **First login**: `initSuperuser` (off by default) creates the admin account
  from `DEFAULT_SUPERUSER_EMAIL` / `DEFAULT_SUPERUSER_PASSWORD` keys in your
  Secret — the app's built-in defaults are `admin@ragflow.io` / `admin`, so
  always set them. Without a superuser, open registration is required
  (`api.registerEnabled`).
