#!/usr/bin/env bash
# Verify this chart's design assumptions against the actual RAGFlow image.
#
# Every claim the chart's structure depends on is checked here, so a future
# version bump that breaks one of them fails loudly instead of silently
# producing a broken deployment.
#
# Usage: bash ci/verify-image-assumptions.sh [image]
set -u
IMAGE="${1:-infiniflow/ragflow:v0.27.0}"
PASS=0
FAIL=0

ok()   { echo "  ok:   $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

run() { docker run --rm --entrypoint sh "$IMAGE" -c "$1" 2>/dev/null; }

echo "== image: $IMAGE =="

echo
echo "[1] entrypoint exposes the three role switches"
for flag in disable-webserver disable-taskexecutor disable-datasync; do
  if run "grep -q -- '--$flag' /ragflow/entrypoint.sh"; then
    ok "--$flag present"
  else
    bad "--$flag MISSING - workload split is invalid"
  fi
done

echo
echo "[2] probe endpoints exist and are unauthenticated"
if run "grep -q 'system/healthz' /ragflow/api/apps/restful_apis/system_api.py"; then
  ok "/api/v1/system/healthz route present"
else
  bad "healthz route missing - readinessProbe will fail"
fi
if run "grep -q 'system/ping' /ragflow/api/apps/restful_apis/system_api.py"; then
  ok "/api/v1/system/ping route present"
else
  bad "ping route missing - livenessProbe will fail"
fi
# healthz must NOT be behind login_required, or the probe gets a 401.
if run "grep -A2 'system/healthz' /ragflow/api/apps/restful_apis/system_api.py | grep -q 'login_required'"; then
  bad "healthz is behind @login_required - probe would 401"
else
  ok "healthz is unauthenticated"
fi

echo
echo "[3] API version prefix is still v1"
if run "grep -q 'API_VERSION = \"v1\"' /ragflow/api/constants.py"; then
  ok "API_VERSION=v1 (probe paths /api/v1/... are correct)"
else
  bad "API_VERSION changed - probe paths need updating"
fi

echo
echo "[4] datasync has no distributed lock (so it MUST stay a singleton)"
LOCKS=$(run "grep -cE 'RedisDistributedLock|DistributedLock' /ragflow/rag/svr/sync_data_source.py" | tr -d '[:space:]')
if [ "${LOCKS:-0}" = "0" ]; then
  ok "sync_data_source.py has no lock - replicas:1 + Recreate is required"
else
  bad "sync_data_source.py now has $LOCKS lock(s) - datasync may be scalable, revisit the chart"
fi
ELOCKS=$(run "grep -cE 'RedisDistributedLock|DistributedLock' /ragflow/rag/svr/task_executor.py" | tr -d '[:space:]')
if [ "${ELOCKS:-0}" != "0" ]; then
  ok "task_executor.py has $ELOCKS lock(s) - safe to run multiple replicas"
else
  bad "task_executor.py lost its locking - multi-replica executors may be unsafe"
fi

echo
echo "[5] executor consumes a Redis consumer group (basis for StatefulSet identity)"
if run "grep -q 'SVR_CONSUMER_GROUP_NAME' /ragflow/rag/svr/task_executor.py"; then
  ok "consumer group used - stable hostnames matter"
else
  bad "consumer group gone - StatefulSet rationale no longer holds"
fi

echo
echo "[6] pgrep exists (exec probes depend on it)"
if run "command -v pgrep >/dev/null"; then
  ok "pgrep present"
else
  bad "pgrep MISSING - exec probes will always fail"
fi

echo
echo "[7] process command lines match the probe patterns"
if run "grep -q 'rag/svr/task_executor.py' /ragflow/entrypoint.sh"; then
  ok "task_executor launched as 'rag/svr/task_executor.py' - probe pattern matches"
else
  bad "launch path changed - executor probe pattern is stale"
fi
if run "grep -q 'rag/svr/sync_data_source.py' /ragflow/entrypoint.sh"; then
  ok "sync_data_source launched as 'rag/svr/sync_data_source.py' - probe pattern matches"
else
  bad "launch path changed - datasync probe pattern is stale"
fi

echo
echo "[8] metadata backends supported by the app"
for t in MYSQL POSTGRES OCEANBASE GAUSSDB; do
  if run "grep -q '$t = ' /ragflow/api/db/db_models.py"; then
    ok "PooledDatabase.$t available"
  else
    bad "PooledDatabase.$t missing - values.schema.json enum is wrong"
  fi
done

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
