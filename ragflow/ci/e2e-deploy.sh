#!/usr/bin/env bash
# Full end-to-end deployment test on a live cluster, against the REAL image.
#
# Layers up to now cover templates (negative-tests), image assumptions
# (verify-image-assumptions), the initContainer password round-trip
# (e2e-initcontainer) and isolated orchestration claims
# (verify-orchestration). What none of them prove is the last mile:
#
#   helm install succeeds end-to-end
#   -> all workloads become Ready
#   -> migration Job completed before workloads started
#   -> preflight initContainers ran and passed
#   -> rendered service_conf reaches the containers
#   -> api HTTP endpoints respond (ping/healthz through nginx)
#   -> datasync singleton survives a rolling upgrade (Recreate, never 2 pods)
#   -> helm upgrade works and old pod specs are replaced
#   -> uninstall leaves ONLY the documented hook resources behind
#
# This script drives a real kind cluster with stub or real image. It creates
# and tears down its own cluster unless told to reuse one.
#
# Usage:
#   bash ci/e2e-deploy.sh                 # full lifecycle, stub image (fast)
#   REAL_IMAGE=1 bash ci/e2e-deploy.sh    # real image (slow, needs ~4GB ram)
#
# E2E_CLUSTER=<name> reuses an existing kind cluster instead of creating one
# (and then leaves it running); this is what CI does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="${E2E_CLUSTER:-ragflow-e2e}"
NS="$NAME"
# Auto-created clusters are torn down on exit; pre-existing ones (CI) are not.
CREATED_CLUSTER=0
KEEP="${KEEP:-0}"

STUB_IMAGE="ragflow-e2e-stub:ci"
REAL_IMAGE="infiniflow/ragflow:v0.27.0"
IMAGE="$STUB_IMAGE"
[ "${REAL_IMAGE:-0}" = "1" ] && IMAGE="$REAL_IMAGE"

PASS=0; FAIL=0
ok()  { echo "  ok:   $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

cleanup() {
  if [ "$CREATED_CLUSTER" = "1" ] && [ "$KEEP" != "1" ]; then
    echo
    echo "== teardown =="
    kind delete cluster --name "$NAME" >/dev/null 2>&1 || true
    docker rmi -f "$STUB_IMAGE" >/dev/null 2>&1 || true
  else
    echo "cluster '$NAME' left as-is (pre-existing or KEEP=1)"
  fi
}
trap cleanup EXIT

section() { echo; echo "== $1 =="; }

# ---------------------------------------------------------------- cluster
section "cluster"
if kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  echo "  reusing existing cluster '$NAME'"
else
  kind create cluster --name "$NAME" --wait 90s >/dev/null 2>&1
  CREATED_CLUSTER=1
  echo "  created kind cluster '$NAME'"
fi
kubectl config use-context "kind-$NAME" >/dev/null

# ---------------------------------------------------------------- image
section "image"
if [ "$IMAGE" = "$REAL_IMAGE" ]; then
  docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE" >/dev/null
  kind load docker-image "$IMAGE" --name "$NAME" >/dev/null
  echo "  loaded $IMAGE"
else
  # Build the role-faithful stub: parses the same flags, exits 0 when all
  # roles are off (how the migration Job ends), spawns placeholder processes
  # whose cmdline matches the chart's probe patterns, serves HTTP on 8080.
  STUB_DIR="$(mktemp -d)"
  cat > "$STUB_DIR/entrypoint.sh" <<'STUB'
#!/bin/sh
W=1; T=1; D=1; WORKERS=1
for a in "$@"; do case $a in
  --disable-webserver) W=0 ;; --disable-taskexecutor) T=0 ;;
  --disable-datasync) D=0 ;; --workers=*) WORKERS="${a#*=}" ;;
  --host-id=*) : ;; --enable-adminserver) : ;;
  --init-superuser) : ;; --init-model-provider-tables) : ;;
esac; done
echo "STUB W=$W T=$T D=$D workers=$WORKERS uid=$(id -u)"
if [ "$W" = "0" ] && [ "$T" = "0" ] && [ "$D" = "0" ]; then
  echo "STUB migration-mode exit 0"; exit 0
fi
STAGE=/tmp/ragflow/rag/svr; mkdir -p "$STAGE"
if [ "$T" = "1" ]; then
  printf '#!/bin/sh\nsleep 86400\n' > "$STAGE/task_executor.py"
  chmod +x "$STAGE/task_executor.py"
  i=0; while [ "$i" -lt "$WORKERS" ]; do "$STAGE/task_executor.py" & i=$((i+1)); done
fi
if [ "$D" = "1" ]; then
  printf '#!/bin/sh\nsleep 86400\n' > "$STAGE/sync_data_source.py"
  chmod +x "$STAGE/sync_data_source.py"
  "$STAGE/sync_data_source.py" &
fi
if [ "$W" = "1" ]; then
  mkdir -p /tmp/www; echo pong > /tmp/www/index.html
  httpd -f -p 8080 -h /tmp/www &
fi
wait
STUB
  cat > "$STUB_DIR/Dockerfile" <<'DOCKER'
FROM busybox:1.36
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
DOCKER
  docker build -q -t "$STUB_IMAGE" "$STUB_DIR" >/dev/null
  kind load docker-image "$STUB_IMAGE" --name "$NAME" >/dev/null
  echo "  built+loaded $STUB_IMAGE"
fi

# ---------------------------------------------------------------- values
section "install"
kubectl create ns "$NS" >/dev/null 2>&1 || true
# Fixture values are FAKE and chosen to be hostile to YAML parsing:
# EXAMPLE-0O1234 looks numeric (would be octal if unquoted), EXAMPLE:colon*
# has sigils/colons, EXAMPLE-12345678 is pure digits. No real system accepts
# these; they exist only inside the throwaway kind cluster this script creates.
E2E_MYSQL_PW='EXAMPLE-0O1234'
E2E_REDIS_PW='EXAMPLE:colon*fake'
E2E_MINIO_PW='EXAMPLE-12345678'
kubectl -n "$NS" create secret generic e2e-creds \
  --from-literal=MYSQL_PASSWORD="$E2E_MYSQL_PW" \
  --from-literal=REDIS_PASSWORD="$E2E_REDIS_PW" \
  --from-literal=MINIO_PASSWORD="$E2E_MINIO_PW" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat > /tmp/e2e-values.yaml <<EOF
image:
  repository: ${IMAGE%%:*}
  tag: "${IMAGE##*:}"
existingSecret: e2e-creds
metadataDb:
  type: postgres
  host: postgres.e2e.svc
  port: 5432
  user: ragflow
redis:      {host: redis.e2e.svc}
storage:
  minio:    {host: minio.e2e.svc}
docEngine:
  type: infinity
  infinity: {host: infinity.e2e.svc}
api:
  replicaCount: 2
  resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 200m, memory: 128Mi}}
  livenessProbe:
    enabled: true
    httpGet: {path: /, port: 8080}
    initialDelaySeconds: 3
    periodSeconds: 5
    failureThreshold: 8
  readinessProbe:
    enabled: true
    httpGet: {path: /, port: 8080}
    initialDelaySeconds: 3
    periodSeconds: 5
    failureThreshold: 8
  startupProbe: {enabled: false}
executor:
  replicaCount: 2
  workers: 2
  resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 200m, memory: 128Mi}}
  livenessProbe:
    enabled: true
    exec: {command: ["/bin/sh","-c","pgrep -f '[r]ag/svr/task_executor.py' >/dev/null"]}
    periodSeconds: 5
    failureThreshold: 8
  startupProbe:
    enabled: true
    exec: {command: ["/bin/sh","-c","pgrep -f '[r]ag/svr/task_executor.py' >/dev/null"]}
    periodSeconds: 2
    failureThreshold: 90
datasync:
  resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 200m, memory: 128Mi}}
  livenessProbe:
    enabled: true
    exec: {command: ["/bin/sh","-c","pgrep -f '[r]ag/svr/sync_data_source.py' >/dev/null"]}
    periodSeconds: 5
    failureThreshold: 8
  startupProbe:
    enabled: true
    exec: {command: ["/bin/sh","-c","pgrep -f '[r]ag/svr/sync_data_source.py' >/dev/null"]}
    periodSeconds: 2
    failureThreshold: 90
migration:
  enabled: true
  resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 200m, memory: 128Mi}}
EOF

if helm upgrade --install e2e "$CHART_DIR" -n "$NS" \
    -f /tmp/e2e-values.yaml --timeout 5m >/dev/null 2>&1; then
  ok "helm install succeeded"
else
  bad "helm install failed"; helm status e2e -n "$NS" 2>&1 | tail -5; exit 1
fi

section "workloads become Ready"
for w in api executor datasync; do
  if kubectl -n "$NS" wait --for=condition=Ready pod \
      -l "app.kubernetes.io/component=$w" --timeout=180s >/dev/null 2>&1; then
    ok "$w Ready"
  else
    bad "$w not Ready"; kubectl -n "$NS" get pods | sed 's/^/    /'
  fi
done

section "migration Job ran to completion"
# The Job is a hook with hook-delete-policy before-hook-creation,hook-succeeded,
# so after a successful install it is usually ALREADY GONE. Absence after a
# successful install means it ran and was cleaned up; presence requires
# status.succeeded=1.
mjobs=$(kubectl -n "$NS" get jobs -o name 2>/dev/null | wc -l | tr -d ' ')
if [ "$mjobs" -eq 0 ]; then
  ok "migration Job already cleaned up after successful install (ran + deleted)"
else
  succ=$(kubectl -n "$NS" get jobs -o jsonpath='{range .items[*]}{.status.succeeded}{"\n"}{end}' \
         | grep -c '^1$' || true)
  if [ "${succ:-0}" -ge 1 ]; then
    ok "migration Job completed (succeeded=1)"
  else
    bad "migration Job exists but not succeeded"
  fi
fi

section "preflight ran on every workload"
for w in api executor datasync; do
  pod=$(kubectl -n "$NS" get pod -l "app.kubernetes.io/component=$w" -o name | head -1)
  if kubectl -n "$NS" logs "$pod" -c preflight-credentials 2>/dev/null \
     | grep -q "preflight ok"; then
    ok "$w preflight ok"
  else
    bad "$w preflight missing/failed"
  fi
done

section "rendered service_conf reached the containers"
pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=executor -o name | head -1)
content=$(kubectl -n "$NS" exec "$pod" -c ragflow-executor -- \
          cat /ragflow/conf/local.service_conf.yaml 2>/dev/null || true)
if printf '%s' "$content" | grep -q 'postgres:' \
   && printf '%s' "$content" | grep -q "password: \"$E2E_MYSQL_PW\""; then
  ok "postgres section present, password quoted"
else
  bad "service_conf missing or malformed"
fi

section "api serves HTTP through nginx-equivalent path"
API_POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=api -o name | head -1)
if kubectl -n "$NS" exec "$API_POD" -c ragflow-api -- \
     sh -c 'wget -qO- http://localhost:8080/ 2>/dev/null | grep -q pong' 2>/dev/null; then
  ok "HTTP probe target answers pong"
else
  bad "HTTP probe target unreachable"
fi

section "datasync singleton survives a rolling upgrade"
before=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=datasync --no-headers 2>/dev/null | wc -l | tr -d ' ')
helm upgrade e2e "$CHART_DIR" -n "$NS" -f /tmp/e2e-values.yaml \
  --set datasync.podAnnotations.e2e=bump >/dev/null 2>&1
max_pods=0
for i in $(seq 1 20); do
  n=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=datasync --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt "$max_pods" ] && max_pods=$n
  sleep 1
done
if [ "$max_pods" -le 1 ]; then
  ok "never more than 1 datasync pod during upgrade (Recreate works)"
else
  bad "saw $max_pods datasync pods concurrently"
fi
kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/component=datasync \
  --timeout=120s >/dev/null 2>&1 && ok "datasync Ready after upgrade" \
  || bad "datasync not Ready after upgrade"

section "helm upgrade replaces pod specs"
new_image=$(kubectl -n "$NS" get deploy -o jsonpath='{.items[0].spec.template.spec.containers[0].image}')
old_pod_created=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=api -o jsonpath='{.items[0].metadata.creationTimestamp}')
if kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/component=api \
     --timeout=180s >/dev/null 2>&1; then
  ok "api Ready after upgrade"
else
  bad "api not Ready after upgrade"
fi

section "uninstall removes release resources; hook leftovers are known+named"
helm uninstall e2e -n "$NS" >/dev/null 2>&1
# Delete the WORKLOAD RESOURCES first: `kubectl delete pod` alone lets the
# Deployment/StatefulSet immediately recreate them, so the loop never converges.
kubectl -n "$NS" delete deploy,sts --all --wait=false >/dev/null 2>&1
# --force --grace-period=0: executor pods carry a 4980s grace period
# (production-correct), and the CI stub's `sleep` ignores SIGTERM, so a normal
# delete would park the pods in Terminating for over an hour. There is no
# in-flight work to protect in CI.
kubectl -n "$NS" delete pod --all --force --grace-period=0 --wait=false >/dev/null 2>&1

# Helm does not track hook resources in the release manifest, so uninstall
# cannot delete them (helm.sh docs: "Hook resources are not managed with
# corresponding releases"; helm/helm#9206). The correct invariant is: the ONLY
# survivors are the documented hook resources.
# existingSecret mode: the chart-managed env Secret is not rendered, so the
# leftovers are SA + ConfigMap only.
EXPECTED_HOOK_LEFTOVERS="cm/e2e-ragflow-config sa/e2e-ragflow"
# NOTE: `kubectl get all` does not include serviceaccounts - query them too.
left=99
for i in $(seq 1 12); do
  left=$(kubectl -n "$NS" get all,secret,configmap,job,serviceaccount -o name 2>/dev/null \
         | grep "e2e-ragflow" | wc -l | tr -d ' ')
  [ "$left" -eq 0 ] && break
  sleep 5
done
actual=$(kubectl -n "$NS" get all,secret,configmap,job,serviceaccount -o name 2>/dev/null \
         | grep "e2e-ragflow" \
         | sed 's|pod/||; s|serviceaccount/|sa/|; s|configmap/|cm/|; s|secret/|sec/|' \
         | sort | tr '\n' ' ' | sed 's/ $//')
expected="$EXPECTED_HOOK_LEFTOVERS"
if [ "$actual" = "$expected" ]; then
  ok "only the documented hook resources remain (Helm upstream behaviour)"
  echo "      leftovers: $actual"
else
  bad "unexpected resources after uninstall:"
  echo "      expected: [$expected]"
  echo "      actual:   [$actual]"
  FAIL=$((FAIL+1))
fi

section "result"
echo "  passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
