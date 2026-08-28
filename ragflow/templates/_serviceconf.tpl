{{/*
Renders local.service_conf.yaml from ENVIRONMENT VARIABLES at pod startup.

Why this exists: postgres/oceanbase are configured through
local.service_conf.yaml, and entrypoint.sh only expands ${VAR} inside
service_conf.yaml.template — never inside local.service_conf.yaml. Naively that
forces the password to be a literal in the file, and therefore into Helm values.

This init script does the interpolation ourselves, reading the password from the
env (i.e. from `existingSecret`) and writing a properly quoted YAML scalar. The
password never appears in values.yaml, the ConfigMap, or the rendered manifest.

Quoting matters: an unquoted "0012345" is read back as int 5349 (octal), "yes"
as bool True, "&x"/"*x" as YAML anchors/aliases. yaml_quote escapes backslashes
and double quotes and the value is always emitted double-quoted.
*/}}
{{- define "ragflow.serviceConfInitScript" -}}
set -eu

OUT="/ragflow-conf/local.service_conf.yaml"

# Emit the body of a double-quoted YAML scalar: escape \ first, then ".
yaml_quote() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

: "${MYSQL_HOST:?metadata db host missing}"
: "${MYSQL_PORT:=5432}"
: "${MYSQL_USER:?metadata db user missing}"
: "${MYSQL_DBNAME:=rag_flow}"
: "${MYSQL_PASSWORD:?metadata db password missing (check existingSecret keys)}"

{{- if eq .Values.metadataDb.type "postgres" }}
cat > "$OUT" <<EOF
postgres:
  name: "$(yaml_quote "$MYSQL_DBNAME")"
  user: "$(yaml_quote "$MYSQL_USER")"
  password: "$(yaml_quote "$MYSQL_PASSWORD")"
  host: "$(yaml_quote "$MYSQL_HOST")"
  port: $MYSQL_PORT
  max_connections: {{ .Values.metadataDb.postgres.maxConnections | int }}
  stale_timeout: {{ .Values.metadataDb.postgres.staleTimeout | int }}
EOF
{{- else if eq .Values.metadataDb.type "oceanbase" }}
cat > "$OUT" <<EOF
oceanbase:
  scheme: oceanbase
  config:
    db_name: "$(yaml_quote "$MYSQL_DBNAME")"
    user: "$(yaml_quote "$MYSQL_USER")"
    password: "$(yaml_quote "$MYSQL_PASSWORD")"
    host: "$(yaml_quote "$MYSQL_HOST")"
    port: $MYSQL_PORT
EOF
{{- end }}

{{- with .Values.serviceConf }}
# Extra user-supplied sections, appended verbatim. read_config() merges by
# top-level key, so these coexist with the generated database section.
cat >> "$OUT" <<'RAGFLOW_EXTRA_EOF'
{{ toYaml . }}
RAGFLOW_EXTRA_EOF
{{- end }}

chmod 0400 "$OUT"
echo "rendered $OUT (password length ${#MYSQL_PASSWORD}, not echoed)"
{{- end }}

{{/*
Preflight assertion shared by every workload. Runs before anything else and
fails loudly with an actionable message, instead of letting a missing key
surface as an opaque CreateContainerConfigError or a late runtime crash.
*/}}
{{- define "ragflow.preflightInitContainer" -}}
- name: preflight-credentials
  image: {{ include "ragflow.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  {{- include "ragflow.containerSecurityContext" . | nindent 2 }}
  command: ["/bin/sh", "-c"]
  args:
    - |
      missing=""
      for v in MYSQL_HOST MYSQL_USER MYSQL_PASSWORD REDIS_HOST; do
        eval "val=\${$v:-}"
        [ -n "$val" ] || missing="$missing $v"
      done
      if [ -n "$missing" ]; then
        echo "FATAL: missing required environment:$missing" >&2
        echo "" >&2
        echo "These come from the Secret named by .Values.existingSecret" >&2
        echo "(currently: {{ .Values.existingSecret | default "<chart-managed>" }})." >&2
        echo "Verify it exists in namespace {{ .Release.Namespace }} and contains" >&2
        echo "the keys MYSQL_PASSWORD / REDIS_PASSWORD / MINIO_PASSWORD:" >&2
        echo "  kubectl -n {{ .Release.Namespace }} get secret {{ .Values.existingSecret | default (printf "%s-env" (include "ragflow.fullname" .)) }} -o jsonpath='{.data}'" >&2
        exit 1
      fi
      echo "preflight ok: credentials present"
  envFrom:
    - configMapRef:
        name: {{ include "ragflow.fullname" . }}-config
    - secretRef:
        name: {{ include "ragflow.secretName" . }}
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 200m
      memory: 128Mi
{{- end }}

{{/*
The initContainer that runs the script above. Shares an emptyDir with the main
container, which mounts just the single file via subPath so the other 17 files
in /ragflow/conf (including private.pem) are not shadowed.
*/}}
{{- define "ragflow.serviceConfInitContainer" -}}
{{- if include "ragflow.needsGeneratedServiceConf" . }}
- name: render-service-conf
  image: {{ include "ragflow.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  {{- include "ragflow.containerSecurityContext" . | nindent 2 }}
  command: ["/bin/sh", "-c"]
  args:
    - |
      {{- include "ragflow.serviceConfInitScript" . | nindent 8 }}
  envFrom:
    - configMapRef:
        name: {{ include "ragflow.fullname" . }}-config
    - secretRef:
        name: {{ include "ragflow.secretName" . }}
  volumeMounts:
    - name: service-conf
      mountPath: /ragflow-conf
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 200m
      memory: 128Mi
{{- end }}
{{- end }}
