#!/usr/bin/env bash
# Verify the chart's core design claims against a running deployment.
# These are the assertions that only a live cluster can settle.
set -u
NS="${1:-ragflow}"
PASS=0; FAIL=0
ok()  { echo "  ok:   $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "[1] executor is a StatefulSet with stable ordinal identities"
names=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=executor \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | tr '\n' ' ')
echo "      pods: $names"
for i in 0 1 2; do
  case "$names" in *"rf-ragflow-executor-$i"*) ok "ordinal $i present" ;;
                   *) bad "ordinal $i missing" ;; esac
done

echo "[2] each executor uses its pod name as the Redis consumer host-id"
for i in 0 1 2; do
  hid=$(kubectl -n "$NS" logs "rf-ragflow-executor-$i" 2>/dev/null \
        | grep -o 'host_id=[^ ]*' | head -1)
  [ "$hid" = "host_id=rf-ragflow-executor-$i" ] \
    && ok "executor-$i -> $hid" \
    || bad "executor-$i got '$hid'"
done

echo "[3] executor runs replicaCount x workers processes"
total=0
for i in 0 1 2; do
  n=$(kubectl -n "$NS" exec "rf-ragflow-executor-$i" -c ragflow-executor -- \
      sh -c 'pgrep -f "[r]ag/svr/task_executor.py" | wc -l' 2>/dev/null | tr -d '[:space:]')
  echo "      executor-$i: $n worker process(es)"
  total=$((total + ${n:-0}))
done
[ "$total" -eq 6 ] && ok "total workers = $total (3 replicas x 2)" \
                   || bad "total workers = $total, expected 6"

echo "[4] the exec liveness probe genuinely passes (not a self-match)"
for i in 0 1 2; do
  kubectl -n "$NS" exec "rf-ragflow-executor-$i" -c ragflow-executor -- \
    sh -c 'pgrep -f "[r]ag/svr/task_executor.py" > /dev/null' 2>/dev/null \
    && ok "executor-$i probe passes with workers running" \
    || bad "executor-$i probe fails despite running workers"
done
# Negative control: a pattern that matches nothing must FAIL, proving the probe
# can actually report unhealthy.
kubectl -n "$NS" exec rf-ragflow-executor-0 -c ragflow-executor -- \
  sh -c 'pgrep -f "[z]zz_not_running.py" > /dev/null' 2>/dev/null \
  && bad "negative control passed - probe is a no-op!" \
  || ok "negative control correctly fails (probe is meaningful)"

echo "[5] datasync is a singleton with Recreate strategy"
n=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=datasync --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "1" ] && ok "exactly 1 datasync pod" || bad "$n datasync pods (must be 1)"
strat=$(kubectl -n "$NS" get deploy rf-ragflow-datasync -o jsonpath='{.spec.strategy.type}' 2>/dev/null)
[ "$strat" = "Recreate" ] && ok "strategy=Recreate" || bad "strategy=$strat"
reps=$(kubectl -n "$NS" get deploy rf-ragflow-datasync -o jsonpath='{.spec.replicas}' 2>/dev/null)
[ "$reps" = "1" ] && ok "replicas=1" || bad "replicas=$reps"

echo "[6] each role runs only its own processes"
te=$(kubectl -n "$NS" exec rf-ragflow-executor-0 -c ragflow-executor -- \
     sh -c 'pgrep -f "[s]ync_data_source.py" >/dev/null && echo yes || echo no' 2>/dev/null | tr -d '[:space:]')
[ "$te" = "no" ] && ok "executor does NOT run datasync" || bad "executor is also running datasync"
ds=$(kubectl -n "$NS" exec deploy/rf-ragflow-datasync -c ragflow-datasync -- \
     sh -c 'pgrep -f "[t]ask_executor.py" >/dev/null && echo yes || echo no' 2>/dev/null | tr -d '[:space:]')
[ "$ds" = "no" ] && ok "datasync does NOT run task executors" || bad "datasync is also running executors"

echo "[7] preflight ran on every workload"
for c in api executor datasync; do
  pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=$c -o name 2>/dev/null | head -1)
  kubectl -n "$NS" logs "$pod" -c preflight-credentials 2>/dev/null | grep -q "preflight ok" \
    && ok "$c preflight ok" || bad "$c preflight did not report ok"
done

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
