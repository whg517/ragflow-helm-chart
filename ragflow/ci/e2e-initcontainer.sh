#!/usr/bin/env bash
# In-cluster end-to-end verification of the initContainer password flow.
#
# Runs the chart's ACTUAL rendered init script (extracted via helm template +
# YAML parse, not hand-copied) in the REAL RAGFlow image, then has RAGFlow's
# own config loader read the generated file back.
#
# Requires: a kind cluster with infiniflow/ragflow:<tag> already loaded, and
# kubectl pointed at it. Slow under QEMU (amd64 image on arm64 host).
#
# Usage: bash ci/e2e-initcontainer.sh [kube-context] [image-tag]
set -eu
CTX="${1:-$(kubectl config current-context)}"
IMAGE_TAG="${2:-v0.27.0}"
CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$CHART_DIR/.." && pwd)"
NS=pg-e2e
PW='EXAMPLE-0O1234'  # FAKE fixture. Hostile on purpose: numeric-looking
                     # (would parse as octal int if unquoted), carries the
                     # EXAMPLE marker so secret scanners ignore it.

echo "== chart : $CHART_DIR"
echo "== ctx   : $CTX"
echo "== image : infiniflow/ragflow:$IMAGE_TAG"

# ---------------------------------------------------------------- extract script
TMP=$(mktemp -d)
helm template rf "$CHART_DIR" -n "$NS" \
  --set existingSecret=creds \
  --set metadataDb.type=postgres \
  --set metadataDb.host=postgres.e2e.svc \
  --set metadataDb.user=ragflow \
  --set redis.host=redis.e2e.svc \
  --set storage.minio.host=minio.e2e.svc \
  --set docEngine.infinity.host=infinity.e2e.svc \
  > "$TMP/rendered.yaml"

python3 - "$TMP/rendered.yaml" "$TMP/init.sh" <<'PY'
import sys, yaml
docs = yaml.safe_load_all(open(sys.argv[1]))
for d in docs:
    if not d or d.get("kind") != "Job":
        continue
    for ic in d["spec"]["template"]["spec"].get("initContainers") or []:
        if ic.get("name") == "render-service-conf":
            s = ic["args"][0]
            assert "yaml_quote" in s and "MYSQL_PASSWORD" in s
            open(sys.argv[2], "w").write(s)
            sys.exit(0)
sys.exit("init script not found in rendered Job")
PY
echo "extracted real init script ($(wc -c < "$TMP/init.sh") bytes)"

# ---------------------------------------------------------------- build pod
python3 - "$TMP" "$IMAGE_TAG" "$PW" <<'PY'
import sys, json, pathlib
tmp, tag, pw = sys.argv[1], sys.argv[2], sys.argv[3]
script = pathlib.Path(tmp + "/init.sh").read_text()

# indent script into the pod yaml
body = "".join("          " + ln + "\n" for ln in script.split("\n"))

pod = """apiVersion: v1
kind: Secret
metadata:
  name: creds
stringData:
  # fixture_pw is the EXAMPLE-marked fake value passed in as argv[3].
  MYSQL_PASSWORD: "{fixture_pw}"
  REDIS_PASSWORD: EXAMPLE-fake-redis
  MINIO_PASSWORD: EXAMPLE-fake-minio
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cfg
data:
  DB_TYPE: postgres
  MYSQL_HOST: postgres.e2e.svc
  MYSQL_PORT: "5432"
  MYSQL_USER: ragflow
  MYSQL_DBNAME: rag_flow
  REDIS_HOST: redis.e2e.svc
  REDIS_PORT: "6379"
  MINIO_HOST: minio.e2e.svc
  MINIO_PORT: "9000"
  MINIO_USER: rag_flow
  MINIO_ROOT_USER: rag_flow
  MINIO_SECURE: "false"
  DOC_ENGINE: infinity
  INFINITY_HOST: infinity.e2e.svc
  TZ: Asia/Shanghai
  DOC_BULK_SIZE: "4"
  EMBEDDING_BATCH_SIZE: "16"
---
apiVersion: v1
kind: Pod
metadata:
  name: pg-e2e
spec:
  restartPolicy: Never
  volumes:
    - name: service-conf
      emptyDir: {{}}
  initContainers:
    - name: render-service-conf
      image: infiniflow/ragflow:{tag}
      command: ["/bin/sh", "-c"]
      args:
        - |
{body}
      envFrom:
        - configMapRef: {{name: cfg}}
        - secretRef: {{name: creds}}
      volumeMounts:
        - name: service-conf
          mountPath: /ragflow-conf
  containers:
    - name: verify
      image: infiniflow/ragflow:{tag}
      envFrom:
        - configMapRef: {{name: cfg}}
        - secretRef: {{name: creds}}
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -eu
          echo "== mounted file =="
          cat /ragflow/conf/local.service_conf.yaml
          echo "== conf dir intact: $$(ls /ragflow/conf | wc -l) files =="
          test -f /ragflow/conf/private.pem && echo "private.pem present"
          echo "== RAGFlow loader round-trip =="
          cd /ragflow
          python3 -c '
          import os
          from common import settings
          db = settings.DATABASE
          exp = os.environ["MYSQL_PASSWORD"]
          got = db["password"]
          print("DATABASE_TYPE :", settings.DATABASE_TYPE)
          print("password type :", type(got).__name__)
          print("round-trip    :", "EXACT MATCH" if got == exp else "MISMATCH")
          assert settings.DATABASE_TYPE == "postgres" and got == exp
          from api.db.db_models import PooledDatabase
          cfg = dict(db); n = cfg.pop("name"); cfg.update(max_retries=1, retry_delay=1)
          print("driver        :", type(PooledDatabase["POSTGRES"].value(n, **cfg)).__name__)
          print("RESULT: OK")
          '
      volumeMounts:
        - name: service-conf
          mountPath: /ragflow/conf/local.service_conf.yaml
          subPath: local.service_conf.yaml
          readOnly: true
""".format(fixture_pw=json.dumps(pw)[1:-1], tag=tag, body=body)
pathlib.Path(tmp + "/pod.yaml").write_text(pod)
PY

# ---------------------------------------------------------------- run
kubectl delete pod pg-e2e -n "$NS" --ignore-not-found >/dev/null
kubectl apply -f "$TMP/pod.yaml" >/dev/null
echo "waiting for pod (QEMU is slow; up to 10 min)..."
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/pg-e2e -n "$NS" --timeout=600s

echo
echo "===== initContainer log ====="
kubectl logs pg-e2e -n "$NS" -c render-service-conf
echo
echo "===== verify log ====="
kubectl logs pg-e2e -n "$NS" -c verify

kubectl delete -f "$TMP/pod.yaml" >/dev/null 2>&1 || true
rm -rf "$TMP"
