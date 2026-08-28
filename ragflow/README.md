# RAGFlow Production Helm Chart

A production-oriented Helm chart for [RAGFlow](https://github.com/infiniflow/ragflow),
built because the chart bundled in the upstream repo (`helm/`, version `0.1.1`,
`appVersion: dev`) is a starting point rather than a production artifact.

## Why not the upstream chart

Findings from reading the upstream templates and application source at
`v0.27.0`. Each is reproduced by rendering the upstream chart locally.

| # | Upstream behaviour | Consequence | Here |
|---|---|---|---|
| 1 | Everything runs in **one `replicas: 1` Deployment** — API, task executors and datasync in a single container | No independent scaling; parsing load and HTTP serving compete | Three workloads, each scaled separately |
| 2 | **No probes at all** on the ragflow container | Traffic routes to pods that aren't ready; hung processes are never restarted | Startup/liveness/readiness on real endpoints |
| 3 | **Passwords rendered unquoted** into the Secret | `MYSQL_PASSWORD=12345678` renders as an int; the API server **rejects the Secret**. `0012345` silently becomes `5349` (octal). A password with `:` or `*` fails to parse | Every value `quote`d |
| 4 | ConfigMaps named `nginx-config`, `mysql-init-script`, `ragflow-service-config` with **no release prefix** | Two releases in one namespace silently overwrite each other | All names release-scoped |
| 5 | Elasticsearch initContainer is **`privileged: true`, `runAsUser: 0`** | Rejected under PSA `baseline`/`restricted` | Doc engine is external; pods satisfy `restricted` |
| 6 | No PDB, HPA, NetworkPolicy, ServiceMonitor, ServiceAccount | No availability guarantees or policy surface | All included |
| 7 | Schema init runs in **every** pod | Concurrent DDL across replicas | Serialized `pre-install`/`pre-upgrade` Job |
| 8 | MySQL is the **only** metadata backend | Can't use PostgreSQL/GaussDB/OceanBase, which the app supports | All four selectable |

Reproduce finding #3:

```bash
helm template up ./ragflow-0.27.0/helm --set env.MYSQL_PASSWORD=12345678 \
  --set env.DOC_ENGINE=infinity | kubeconform -strict -
# Secret ... is invalid: at '/stringData/MYSQL_PASSWORD': got number, want null or string
```

## Architecture

The upstream container image is role-switchable via `entrypoint.sh` flags
(`--disable-webserver`, `--disable-taskexecutor`, `--disable-datasync`). This
chart uses one image as three workloads:

| Workload | Kind | Args | Scaling |
|---|---|---|---|
| `api` | Deployment | `--disable-taskexecutor --disable-datasync` | Stateless; HPA-ready |
| `executor` | StatefulSet | `--disable-webserver --disable-datasync --workers=N` | Scale with parsing backlog |
| `datasync` | Deployment | `--disable-webserver --disable-taskexecutor` | **Fixed at 1** |
| `migration` | Job (hook) | all three disabled | Runs once per install/upgrade |

**Why the executor is a StatefulSet.** `task_executor.py` consumes a Redis
Stream consumer group (`rag_flow_svr_task_broker`) with a consumer name derived
from the hostname. Stable ordinals mean restarts reuse consumer identities
instead of accumulating dead ones. The chart passes `--host-id=$(POD_NAME)`
explicitly so identity is readable in `XINFO CONSUMERS` output.

**Why datasync is a singleton.** `rag/svr/sync_data_source.py` acquires no
distributed lock — unlike `task_executor.py`, which uses `RedisDistributedLock`.
Two replicas would sync every data source twice. Replica count is deliberately
not exposed, and the strategy is `Recreate` so upgrades never overlap.

**Probe endpoints** (verified in `api/apps/restful_apis/system_api.py`, both
without `@login_required`):

- `/api/v1/system/ping` → `pong`. No dependency checks — used for liveness so a
  database blip doesn't kill healthy containers.
- `/api/v1/system/healthz` → checks db, redis, doc_engine, storage; returns 500
  unless all four pass. Used for readiness.

**The executor and datasync probes use a `[r]` character class, deliberately.**
A Kubernetes `exec` probe runs `sh -c "pgrep -f rag/svr/task_executor.py"`, and
that shell's *own* command line contains the pattern — so `pgrep` matches
itself and the probe **can never fail**. Verified in the real image:

```
unbracketed, no target: exit=0   <-- self-match bug, always "healthy"
bracketed,   no target: exit=1   <-- correctly unhealthy
bracketed,   target up: exit=0   <-- correctly healthy
```

Reproduce with `bash ci/verify-probes.sh` inside the image:

```bash
docker run --rm --entrypoint sh \
  -v "$PWD/ragflow/ci/verify-probes.sh:/t.sh:ro" \
  infiniflow/ragflow:v0.27.0 /t.sh
```

Note the test script must live in a **file**; inlining it via `sh -c` puts the
pattern into PID 1's command line and every check then self-matches.

## Prerequisites

Kubernetes >= 1.23, Helm >= 3.8, and these **external** services:

- Metadata DB: MySQL 8.x, PostgreSQL, OceanBase, or GaussDB
- Redis / Valkey
- S3-compatible object storage
- Doc engine: Infinity, Elasticsearch 8.x, or OpenSearch 2.x

The image is **3.19 GB compressed** (41 layers, ~8-10 GB on disk). On a cold
node the first pull dominates startup, which is why `startupProbe` allows up to
10 minutes. Pre-pulling onto nodes, or mirroring into a local registry via
`global.imageRegistry`, is strongly recommended.

## Install

Create the Secret first — the chart never needs plaintext credentials:

```bash
kubectl create secret generic ragflow-credentials -n ragflow \
  --from-literal=MYSQL_PASSWORD='...' \
  --from-literal=REDIS_PASSWORD='...' \
  --from-literal=MINIO_PASSWORD='...'
```

```bash
helm upgrade --install ragflow ./ragflow -n ragflow --create-namespace \
  -f my-values.yaml
```

Minimum viable values:

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

## Non-MySQL metadata backends

`metadataDb.type` accepts `mysql`, `postgres`, `oceanbase`, `gaussdb`.

**The password always comes from `existingSecret`. It never goes in values.**

```yaml
metadataDb:
  type: postgres
  host: postgres.data.svc
  port: 5432
  user: ragflow
  database: rag_flow
existingSecret: ragflow-credentials   # supplies MYSQL_PASSWORD
```

### Why postgres/oceanbase need an initContainer

These two backends are configured through `local.service_conf.yaml`, not env
vars — and three facts (all verified against `infiniflow/ragflow:v0.27.0`) make
that awkward:

1. The shipped `service_conf.yaml` has **no `postgres:` section at all** (only
   `mysql` and `oceanbase`).
2. `common/settings.py` resolves `DATABASE` at **module import time** via
   `decrypt_database_config()`, which does an unguarded `database["password"]`
   lookup. A missing section is therefore a hard crash — every process dies with
   `KeyError: 'password'` before serving anything, not a runtime connect error.
3. `entrypoint.sh` expands `${VAR}` **only** inside `service_conf.yaml.template`.
   `local.service_conf.yaml` is read verbatim by `read_config()`, so a
   `${MYSQL_PASSWORD}` placeholder in it would never be substituted.

Naively, (3) forces the password to be a literal in the file, and thus into
values. Instead the chart adds a `render-service-conf` initContainer that reads
`MYSQL_PASSWORD` from the Secret **via the environment** and writes the file
into a shared `emptyDir` at pod startup. The password never appears in
`values.yaml`, in a ConfigMap, or in `helm template` output.

`read_config()` merges with `global_config.update(local_config)` — a top-level
key merge — so emitting just the database section leaves everything else intact.

Two details that are easy to get wrong:

- **Quoting.** The init script emits a double-quoted YAML scalar and escapes
  `\` and `"`. Unquoted, `0012345` is read back as int **5349** (octal), `yes`
  as `True`, and `&x` / `*x` are YAML anchors. Round-tripped against 10 hostile
  passwords including quotes, backslashes, CJK, and `$(whoami)`.
- **subPath, not a directory mount.** `/ragflow/conf` holds 17 other files
  including `private.pem`; mounting the directory would shadow all of them.

`mysql` and `gaussdb` are configured purely through env vars, so they get **no**
initContainer — the chart asserts this in `ci/negative-tests.sh`.

### Admin server caveat

`admin/server/config.py` `load_configurations()` has a `match` with
`case "mysql"` but **no `case "postgres"`**, so the Admin panel will not show
metadata-DB status on a PostgreSQL deployment. The main service is unaffected.
`api.adminServer.enabled` defaults to `false`.

Note also that `--init-model-provider-tables` contains MySQL-only SQL; the chart
skips it automatically for `gaussdb`, mirroring upstream `entrypoint.sh`.

## Scaling

`api` scales on CPU/memory. `executor` throughput is
`replicaCount × workers`; CPU utilisation is a weak proxy for parsing backlog,
so for real workloads drive it from Redis queue depth with KEDA:

```yaml
triggers:
  - type: redis
    metadata:
      address: redis.data.svc:6379
      listName: "te.0.common"
      listLength: "5"
```

Set `executor.terminationGracePeriodSeconds` above your longest expected
document parse (default 300) so in-flight work drains on scale-in.

## Validation

```bash
helm lint ./ragflow -f ragflow/ci/minimal-values.yaml
# -ignore-missing-schemas is required: full-values enables the
# ServiceMonitor CRD, whose schema is not in kubeconform's default set.
helm template rf ./ragflow -f ragflow/ci/full-values.yaml \
  | kubeconform -strict -summary -ignore-missing-schemas -
bash ragflow/ci/negative-tests.sh ./ragflow
```

The negative suite asserts the chart **refuses** to render on missing
credentials, unknown `metadataDb.type`, unknown `docEngine.type`, and missing
required hosts; that no password appears in rendered output; and that
postgres/oceanbase get the render initContainer while mysql/gaussdb do not.

### Against the real image

```bash
# design assumptions (flags, probes, locks, enum members) — ~2 min
make verify-image

# full initContainer password round-trip inside a kind cluster — needs the
# image loaded; slow under QEMU on arm64
bash ragflow/ci/e2e-initcontainer.sh
```

`ci/e2e-initcontainer.sh` extracts the chart's **actual rendered** init script
(via `helm template` + YAML parse, never hand-copied), runs it in the real
image, and asserts that RAGFlow's own `common.settings` loader reads the
password back as an exact string and constructs
`RetryingPooledPostgresqlDatabase`.

### Against a running deployment

```bash
bash ragflow/ci/verify-orchestration.sh <namespace>
```

Settles the claims only a live cluster can: StatefulSet ordinals are stable,
each executor's Redis `host-id` equals its pod name, worker count is
`replicaCount x workers`, datasync stays a singleton under `Recreate`, each role
runs only its own processes, and — with a **negative control** — that the exec
liveness probe can actually report unhealthy rather than always passing.

## Known gaps

- **No metrics endpoint verified.** `serviceMonitor.enabled` assumes `/metrics`
  on port 9380; this was not confirmed against a running instance. Leave it off
  until verified.
- **Logs are ephemeral**, written to `/ragflow/logs` inside the container. Use a
  node-level log collector.
- **No backup tooling.** External dependencies own their own backups.
- **`readOnlyRootFilesystem: false`** — the entrypoint writes
  `service_conf.yaml` at startup. Tightening this needs an emptyDir overlay.
