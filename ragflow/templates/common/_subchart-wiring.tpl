{{/*
Subchart dependency wiring that cannot live in values.yaml.

valkey (when valkey.enabled):
  - auth.usersExistingSecret is the SAME Secret RAGFlow reads (existingSecret
    or the chart-managed one), so the `default` ACL user's password is
    REDIS_PASSWORD — one source of truth, nothing in values.
  - auth.aclUsers also needs the raw password for the ACL config when
    usersExistingSecret is not honoured for inline users; the valkey chart
    reads passwordKey from usersExistingSecret, which is what we use.

opensearch (when opensearch.enabled AND docEngine.type=opensearch):
  - admin credentials: RAGFlow's OS_USER/OS_PASSWORD come from existingSecret
    keys OPENSEARCH_USER / OPENSEARCH_PASSWORD; the subchart gets matching
    admin credential env via its `extraEnvs` so both sides agree.
*/}}
{{- define "ragflow.credentialSecretName" -}}
{{- include "ragflow.secretName" . -}}
{{- end }}

{{- define "ragflow.valkey.usersExistingSecret" -}}
{{- if .Values.valkey.enabled -}}
{{- include "ragflow.credentialSecretName" . -}}
{{- end -}}
{{- end }}
