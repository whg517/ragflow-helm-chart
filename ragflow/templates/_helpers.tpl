{{/* vim: set filetype=mustache: */}}

{{- define "ragflow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ragflow.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "ragflow.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ragflow.labels" -}}
helm.sh/chart: {{ include "ragflow.chart" . }}
{{ include "ragflow.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ragflow
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "ragflow.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ragflow.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component-scoped names and labels.
Usage: {{ include "ragflow.componentLabels" (dict "root" . "component" "api") }}
*/}}
{{- define "ragflow.componentName" -}}
{{- printf "%s-%s" (include "ragflow.fullname" .root) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ragflow.componentLabels" -}}
{{ include "ragflow.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "ragflow.componentSelectorLabels" -}}
{{ include "ragflow.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "ragflow.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ragflow.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference with optional global registry override.
*/}}
{{- define "ragflow.image" -}}
{{- $registry := .Values.image.registry | default .Values.global.imageRegistry -}}
{{- $repo := .Values.image.repository -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if .Values.image.digest -}}
{{- if $registry -}}{{ $registry }}/{{ end }}{{ $repo }}@{{ .Values.image.digest }}
{{- else -}}
{{- if $registry -}}{{ $registry }}/{{ end }}{{ $repo }}:{{ $tag }}
{{- end -}}
{{- end }}

{{- define "ragflow.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.image.pullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ if kindIs "string" . }}{{ . }}{{ else }}{{ .name }}{{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Default port for the selected metadata backend. Explicit metadataDb.port always
wins; this only supplies the default so that switching `type` does not silently
keep MySQL's 3306.
*/}}
{{- define "ragflow.metadataDbPort" -}}
{{- if .Values.metadataDb.port -}}
{{- .Values.metadataDb.port -}}
{{- else if eq .Values.metadataDb.type "postgres" -}}5432
{{- else if eq .Values.metadataDb.type "gaussdb" -}}5432
{{- else if eq .Values.metadataDb.type "oceanbase" -}}2881
{{- else -}}3306
{{- end -}}
{{- end }}

{{/*
Name of the Secret holding credentials. Either user-supplied or chart-managed.
*/}}
{{- define "ragflow.secretName" -}}
{{- if .Values.existingSecret -}}
{{ .Values.existingSecret }}
{{- else -}}
{{ include "ragflow.fullname" . }}-env
{{- end -}}
{{- end }}

{{/*
Doc engine host env vars. Rendered into the non-secret ConfigMap.
*/}}
{{- define "ragflow.docEngineEnv" -}}
{{- $e := .Values.docEngine -}}
DOC_ENGINE: {{ $e.type | quote }}
{{- if eq $e.type "infinity" }}
INFINITY_HOST: {{ required "docEngine.infinity.host is required when type=infinity" $e.infinity.host | quote }}
{{- else if eq $e.type "elasticsearch" }}
ES_HOST: {{ required "docEngine.elasticsearch.host is required when type=elasticsearch" $e.elasticsearch.host | quote }}
ES_PORT: {{ $e.elasticsearch.port | default 9200 | quote }}
ES_USER: {{ $e.elasticsearch.user | default "elastic" | quote }}
{{- else if eq $e.type "opensearch" }}
OS_HOST: {{ required "docEngine.opensearch.host is required when type=opensearch" $e.opensearch.host | quote }}
OS_PORT: {{ $e.opensearch.port | default 9201 | quote }}
OS_USER: {{ $e.opensearch.user | default "admin" | quote }}
{{- else }}
{{- fail (printf "docEngine.type must be one of: infinity, elasticsearch, opensearch (got %q)" $e.type) }}
{{- end }}
{{- end }}

{{/*
Validate metadata database type against what the application actually supports.
Source of truth: api/db/db_models.py PooledDatabase enum.
*/}}
{{- define "ragflow.validateDbType" -}}
{{- $valid := list "mysql" "postgres" "oceanbase" "gaussdb" -}}
{{- $t := .Values.metadataDb.type -}}
{{- if not (has $t $valid) -}}
{{- fail (printf "metadataDb.type must be one of %v (got %q). Source: api/db/db_models.py PooledDatabase" $valid $t) -}}
{{- end -}}
{{- end }}

{{/*
Common pod spec fragment shared by all three workloads.
*/}}
{{- define "ragflow.podSecurityContext" -}}
{{- with .Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "ragflow.containerSecurityContext" -}}
{{- with .Values.containerSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
envFrom block: shared ConfigMap + Secret, plus any extra sources.
*/}}
{{- define "ragflow.envFrom" -}}
envFrom:
  - configMapRef:
      name: {{ include "ragflow.fullname" . }}-config
  - secretRef:
      name: {{ include "ragflow.secretName" . }}
{{- with .Values.extraEnvFrom }}
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Volume + mount for the optional service_conf override.
*/}}
{{/*
local.service_conf.yaml lives in a SECRET (it may hold a literal DB password);
llm_factories.json lives in a ConfigMap. Mount whichever exist.
*/}}
{{/*
True when local.service_conf.yaml has to be generated at runtime: either a
database backend that is configured through it, or user-supplied extra sections.
*/}}
{{- define "ragflow.needsGeneratedServiceConf" -}}
{{- if or .Values.serviceConf (has .Values.metadataDb.type (list "postgres" "oceanbase")) -}}true{{- end -}}
{{- end }}

{{- define "ragflow.serviceConfVolume" -}}
{{- if include "ragflow.needsGeneratedServiceConf" . }}
{{- /* emptyDir written by the render-service-conf initContainer. The password
       comes from the Secret via env, so it never enters values or a manifest. */}}
- name: service-conf
  emptyDir: {}
{{- end }}
{{- if .Values.llmFactories }}
- name: llm-factories
  configMap:
    name: {{ include "ragflow.fullname" . }}-service-conf
{{- end }}
{{- end }}

{{- define "ragflow.serviceConfMounts" -}}
{{- if include "ragflow.needsGeneratedServiceConf" . }}
{{- /* subPath, NOT a directory mount: /ragflow/conf holds 17 other files
       (private.pem, *_mapping.json, service_conf.yaml). Mounting the directory
       would shadow all of them. */}}
- name: service-conf
  mountPath: /ragflow/conf/local.service_conf.yaml
  subPath: local.service_conf.yaml
  readOnly: true
{{- end }}
{{- if .Values.llmFactories }}
- name: llm-factories
  mountPath: /ragflow/conf/llm_factories.json
  subPath: llm_factories.json
  readOnly: true
{{- end }}
{{- end }}

{{/*
Emit a complete volumeMounts: block, or nothing at all when there is nothing
to mount. Avoids rendering a bare `volumeMounts:` key with a null value.
Usage: {{ include "ragflow.volumeMountsBlock" (dict "root" . "extra" .Values.api.extraVolumeMounts) | nindent 10 }}
*/}}
{{- define "ragflow.volumeMountsBlock" -}}
{{- $sc := include "ragflow.serviceConfMounts" .root | trim -}}
{{- $extra := .extra | default list -}}
{{- if or $sc $extra -}}
volumeMounts:
{{- if $sc }}
{{- $sc | nindent 2 }}
{{- end }}
{{- with $extra }}
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Emit a complete volumes: block, or nothing when empty.
*/}}
{{- define "ragflow.volumesBlock" -}}
{{- $sc := include "ragflow.serviceConfVolume" .root | trim -}}
{{- $extra := .extra | default list -}}
{{- if or $sc $extra -}}
volumes:
{{- if $sc }}
{{- $sc | nindent 2 }}
{{- end }}
{{- with $extra }}
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Checksum annotations so pods roll when config changes.
*/}}
{{- define "ragflow.configChecksums" -}}
checksum/config: {{ include (print $.Template.BasePath "/common/configmap.yaml") . | sha256sum }}
{{- if not .Values.existingSecret }}
checksum/secret: {{ include (print $.Template.BasePath "/common/secret.yaml") . | sha256sum }}
{{- end }}
{{- if include "ragflow.needsGeneratedServiceConf" . }}
{{- /* The init script is templated, so hash it: changing db host/port/type
       must roll the pods. */}}
checksum/service-conf: {{ include "ragflow.serviceConfInitScript" . | sha256sum }}
{{- end }}
{{- if .Values.llmFactories }}
checksum/llm-factories: {{ include (print $.Template.BasePath "/common/configmap-service-conf.yaml") . | sha256sum }}
{{- end }}
{{- end }}
