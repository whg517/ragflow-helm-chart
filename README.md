# ragflow-helm-chart

Production Helm chart for [RAGFlow](https://github.com/infiniflow/ragflow) —
one image, three independently-scaled workloads, external dependencies, and
credentials that never touch your values files.

[![chart-ci](https://github.com/whg517/ragflow-helm-chart/actions/workflows/chart-ci.yaml/badge.svg)](https://github.com/whg517/ragflow-helm-chart/actions/workflows/chart-ci.yaml)
![Chart Version](https://img.shields.io/badge/chart%20version-1.0.0-blue)
![App Version](https://img.shields.io/badge/app%20version-v0.27.0-green)
![License](https://img.shields.io/badge/license-Apache--2.0-lightgrey)

## Why this chart exists

The `helm/` directory bundled in the upstream repo is a starting point, not a
production artifact: one unscaled Deployment, no probes, ConfigMaps that
collide between releases, and Secrets the Kubernetes API server rejects when a
password looks like a number. The full comparison — with reproduction commands
— is in [`ragflow/README.md`](ragflow/README.md#chart-vs-upstream).

This chart's three design principles:

1. **Workload split.** The RAGFlow image is role-switchable via `entrypoint.sh`
   flags, so one image becomes an API Deployment, an executor StatefulSet, and
   a single-instance datasync Deployment — each scaling on its own terms.
2. **External dependencies.** Metadata DB, Redis, object storage, and the doc
   engine are external; the chart manages only the application.
3. **Evidence over convention.** Every non-obvious decision was verified
   against the v0.27.0 source and, where it matters, against the running image
   in a real cluster — and is asserted by a test in this repo so it cannot
   silently regress.

## Repository layout

```
ragflow/                  the chart (install this directory)
├── Chart.yaml
├── values.yaml           every knob, documented inline
├── values.schema.json    install-time validation of values
├── templates/            split by workload: api/ executor/ datasync/ common/
└── ci/                   test fixtures and verification scripts
Makefile                  make verify / verify-image
.github/workflows/        CI: lint + kubeconform + 28 negative assertions
```

## Optional built-in dependencies

The chart installs only RAGFlow by default. Enable any of these to have the
chart deploy them alongside (credentials still come exclusively from your
Secret):

```yaml
valkey:      {enabled: true}     # in-cluster Redis-compatible cache
postgres:
  builtin:   {enabled: true}     # in-cluster metadata DB (single replica)
rustfs:      {enabled: true}     # in-cluster S3-compatible object storage
opensearch:  {enabled: true}     # + docEngine.type=opensearch
```

Single replicas, no HA — evaluation and small deployments. Production should
keep them off and point at dedicated clusters. Details in
[`ragflow/README.md`](ragflow/README.md#prerequisites).

## Quick start

```bash
git clone https://github.com/whg517/ragflow-helm-chart
cd ragflow-helm-chart

# Credentials — the chart never takes plaintext passwords in values
kubectl create secret generic ragflow-credentials -n ragflow \
  --from-literal=MYSQL_PASSWORD='...' \
  --from-literal=REDIS_PASSWORD='...' \
  --from-literal=MINIO_PASSWORD='...'

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

The full quick start (including the admin-account options) is in
[`ragflow/README.md`](ragflow/README.md#quick-start).

## Documentation

Everything below lives in [`ragflow/README.md`](ragflow/README.md):

| Section | Covers |
|---|---|
| [Architecture](ragflow/README.md#architecture) | Why api/executor/datasync/migration, and what each entrypoint flag does |
| [Chart vs upstream](ragflow/README.md#chart-vs-upstream) | Eight upstream findings, each reproduced locally |
| [Security posture](ragflow/README.md#security-posture--read-before-deploying) | **The stock image requires root** — PSA restricted namespaces will reject it; hardening path |
| [Metadata backends](ragflow/README.md#metadata-backends) | mysql / postgres / oceanbase / gaussdb, and why two of them need an initContainer |
| [Probes](ragflow/README.md#probes) | Verified endpoints, the `[r]` pgrep guard, startup-gate ordering |
| [Scaling](ragflow/README.md#scaling) | HPA on api; KEDA queue-depth example for executor; the 80-minute task timeout |
| [Validation](ragflow/README.md#validation) | The four-layer verification stack and how to run it |
| [Known gaps](ragflow/README.md#known-gaps) | Metrics, log persistence, readOnlyRootFilesystem |

Upstream issues this chart works around are tracked in
[Issues](https://github.com/whg517/ragflow-helm-chart/issues) — each with a
reproduction and, where applicable, a fix upstream could adopt.

## Verification

The chart is checked at four depths; each layer catches what the previous one
cannot:

```bash
make verify        # helm lint ×3 · kubeconform -strict · 28 negative assertions
make verify-image  # 17 design-assumption checks against the real image
```

Two further scripts run against live systems and are documented in
[`ragflow/README.md#validation`](ragflow/README.md#validation):
`ci/e2e-deploy.sh` (full lifecycle on a live kind cluster — install,
readiness, hooks, upgrade, uninstall invariants), `ci/e2e-initcontainer.sh`
(in-cluster password round-trip through RAGFlow's own config loader) and
`ci/verify-orchestration.sh` (live-cluster behaviour, with negative
controls).

CI runs the first layer on every push to `ragflow/**` or the workflow itself.

## Requirements

- Kubernetes ≥ 1.23, Helm ≥ 3.8
- External: metadata DB (MySQL 8.x / PostgreSQL / OceanBase / GaussDB),
  Redis, S3-compatible storage, and a doc engine (Infinity / Elasticsearch /
  OpenSearch)
- Image: `infiniflow/ragflow` (~3.2 GB compressed; pre-pull recommended)
- **Note:** the stock image runs as root — see
  [Security posture](ragflow/README.md#security-posture--read-before-deploying)
  before deploying into a policy-restricted namespace

## License

Apache-2.0, matching RAGFlow itself. Chart is provided as-is; test it in your
environment before production use.
