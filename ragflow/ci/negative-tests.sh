#!/usr/bin/env bash
# Negative tests: every one of these MUST fail to render.
# A guardrail that doesn't fire is worse than no guardrail.
set -u
CHART="${1:-./ragflow}"
PASS=0
FAIL=0

expect_fail() {
  local name="$1"; shift
  if helm template negtest "$CHART" "$@" >/dev/null 2>&1; then
    echo "FAIL: '$name' rendered successfully but should have been rejected"
    FAIL=$((FAIL+1))
  else
    echo "ok:   '$name' correctly rejected"
    PASS=$((PASS+1))
  fi
}

expect_ok() {
  local name="$1"; shift
  if helm template postest "$CHART" "$@" >/dev/null 2>&1; then
    echo "ok:   '$name' rendered"
    PASS=$((PASS+1))
  else
    echo "FAIL: '$name' should render but did not"
    helm template postest "$CHART" "$@" 2>&1 | tail -5
    FAIL=$((FAIL+1))
  fi
}

BASE="--set existingSecret=ragflow-credentials
      --set metadataDb.host=db.svc
      --set redis.host=redis.svc
      --set storage.minio.host=minio.svc
      --set docEngine.infinity.host=infinity.svc"

echo "--- guardrails that must reject ---"

# No credentials at all.
expect_fail "no credentials" \
  --set metadataDb.host=db.svc --set redis.host=redis.svc \
  --set storage.minio.host=minio.svc --set docEngine.infinity.host=infinity.svc

# Unsupported metadata DB (not in PooledDatabase enum).
expect_fail "invalid metadataDb.type=mongodb" $BASE --set metadataDb.type=mongodb

# Unsupported doc engine.
expect_fail "invalid docEngine.type=milvus" $BASE --set docEngine.type=milvus

# Required hosts missing.
expect_fail "missing metadataDb.host" \
  --set existingSecret=s --set redis.host=r.svc \
  --set storage.minio.host=m.svc --set docEngine.infinity.host=i.svc

expect_fail "missing redis.host" \
  --set existingSecret=s --set metadataDb.host=db.svc \
  --set storage.minio.host=m.svc --set docEngine.infinity.host=i.svc

expect_fail "missing docEngine host for selected engine" \
  --set existingSecret=s --set metadataDb.host=db.svc \
  --set redis.host=r.svc --set storage.minio.host=m.svc \
  --set docEngine.type=elasticsearch

echo "--- valid configs that must render ---"

# EVERY backend now works with existingSecret alone — no password in values.
# For postgres/oceanbase an initContainer renders local.service_conf.yaml from
# the MYSQL_PASSWORD env var at pod startup.
for t in mysql gaussdb postgres oceanbase; do
  expect_ok "metadataDb.type=$t via existingSecret only" $BASE --set metadataDb.type=$t
done

echo "--- password must never leak into rendered manifests ---"
SECRET_PW="sup3r-s3cret-should-not-appear"
for t in postgres oceanbase; do
  out=$(helm template leak "$CHART" $BASE --set metadataDb.type=$t \
        --set existingSecret=creds 2>/dev/null)
  if printf '%s' "$out" | grep -q "$SECRET_PW"; then
    echo "FAIL: password leaked into manifest for type=$t"; FAIL=$((FAIL+1))
  else
    echo "ok:   type=$t manifest contains no password"; PASS=$((PASS+1))
  fi
done

echo "--- postgres/oceanbase must get a render initContainer ---"
for t in postgres oceanbase; do
  out=$(helm template ic "$CHART" $BASE --set metadataDb.type=$t 2>/dev/null)
  if printf '%s' "$out" | grep -q "name: render-service-conf"; then
    echo "ok:   type=$t has the render initContainer"; PASS=$((PASS+1))
  else
    echo "FAIL: type=$t is missing the render initContainer"; FAIL=$((FAIL+1))
  fi
done

echo "--- mysql/gaussdb must NOT get one (env vars are enough) ---"
for t in mysql gaussdb; do
  out=$(helm template ic "$CHART" $BASE --set metadataDb.type=$t 2>/dev/null)
  if printf '%s' "$out" | grep -q "name: render-service-conf"; then
    echo "FAIL: type=$t has an unnecessary initContainer"; FAIL=$((FAIL+1))
  else
    echo "ok:   type=$t correctly has no initContainer"; PASS=$((PASS+1))
  fi
done

echo "--- the init script must quote the password it writes ---"
out=$(helm template q "$CHART" $BASE --set metadataDb.type=postgres 2>/dev/null)
if printf '%s' "$out" | grep -q 'password: "$(yaml_quote "$MYSQL_PASSWORD")"'; then
  echo "ok:   password is emitted as a quoted YAML scalar"; PASS=$((PASS+1))
else
  echo "FAIL: password is not quoted in the init script"; FAIL=$((FAIL+1))
fi
if printf '%s' "$out" | grep -q 'yaml_quote()'; then
  echo "ok:   yaml_quote escaping helper present"; PASS=$((PASS+1))
else
  echo "FAIL: yaml_quote helper missing"; FAIL=$((FAIL+1))
fi

expect_ok "docEngine=elasticsearch" \
  --set existingSecret=s --set metadataDb.host=db.svc --set redis.host=r.svc \
  --set storage.minio.host=m.svc --set docEngine.type=elasticsearch \
  --set docEngine.elasticsearch.host=es.svc

expect_ok "docEngine=opensearch" \
  --set existingSecret=s --set metadataDb.host=db.svc --set redis.host=r.svc \
  --set storage.minio.host=m.svc --set docEngine.type=opensearch \
  --set docEngine.opensearch.host=os.svc

echo "--- review regressions: metadata port must follow the backend type ---"
check_port() {
  local t="$1" want="$2" key="$3"
  local got
  got=$(helm template p "$CHART" $BASE --set metadataDb.type=$t 2>/dev/null \
        | grep -E "^  $key:" | head -1 | sed 's/.*: *//' | tr -d '"')
  if [ "$got" = "$want" ]; then
    echo "ok:   $t default port $got"; PASS=$((PASS+1))
  else
    echo "FAIL: $t default port is '$got', expected '$want'"; FAIL=$((FAIL+1))
  fi
}
check_port mysql     3306 MYSQL_PORT
check_port postgres  5432 MYSQL_PORT
check_port oceanbase 2881 MYSQL_PORT
check_port gaussdb   5432 GAUSSDB_METADATA_PORT

# An explicit port must always win over the type default.
got=$(helm template p "$CHART" $BASE --set metadataDb.type=postgres \
      --set metadataDb.port=6543 2>/dev/null \
      | grep -E '^  MYSQL_PORT:' | head -1 | sed 's/.*: *//' | tr -d '"')
if [ "$got" = "6543" ]; then
  echo "ok:   explicit port overrides the default"; PASS=$((PASS+1))
else
  echo "FAIL: explicit port ignored (got '$got')"; FAIL=$((FAIL+1))
fi

echo "--- review regressions: every workload gets the preflight check ---"
out=$(helm template p "$CHART" $BASE 2>/dev/null)
n=$(printf '%s' "$out" | grep -c "name: preflight-credentials" || true)
if [ "$n" -eq 4 ]; then
  echo "ok:   preflight present on all 4 workloads"; PASS=$((PASS+1))
else
  echo "FAIL: preflight found on $n workloads, expected 4"; FAIL=$((FAIL+1))
fi

echo "--- review regressions: helm test must not pull an external image ---"
tst=$(helm template p "$CHART" $BASE 2>/dev/null | grep -A3 "test-health" | grep "image:" || true)
if printf '%s' "$out" | grep -q "curlimages/curl"; then
  echo "FAIL: test pod still depends on curlimages/curl"; FAIL=$((FAIL+1))
else
  echo "ok:   test pod reuses the app image"; PASS=$((PASS+1))
fi

echo "--- review regressions: migration deadline must be bounded ---"
dl=$(helm template p "$CHART" $BASE 2>/dev/null \
     | grep -E "activeDeadlineSeconds:" | head -1 | sed 's/.*: *//')
if [ -n "$dl" ] && [ "$dl" -le 600 ]; then
  echo "ok:   migration activeDeadlineSeconds=$dl (bounded)"; PASS=$((PASS+1))
else
  echo "FAIL: migration deadline is '$dl' (too long or unset)"; FAIL=$((FAIL+1))
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
