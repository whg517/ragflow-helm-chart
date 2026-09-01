# RAGFlow chart — full validation suite.
# Run: bash ci/verify.sh
.DEFAULT_GOAL := verify

CHART ?= ./ragflow
NS    ?= ragflow
IMAGE ?= infiniflow/ragflow:v0.27.0

.PHONY: lint template validate negative verify verify-image e2e clean

lint:
	helm lint $(CHART) -f $(CHART)/ci/minimal-values.yaml
	helm lint $(CHART) -f $(CHART)/ci/full-values.yaml
	helm lint $(CHART) -f $(CHART)/ci/production-values.yaml

template:
	@for f in minimal full production; do \
	  echo "--- rendering $$f ---"; \
	  helm template rf $(CHART) -n $(NS) -f $(CHART)/ci/$$f-values.yaml > /tmp/rf-$$f.yaml || exit 1; \
	done

validate: template
	@for f in minimal full production; do \
	  echo "--- kubeconform $$f ---"; \
	  kubeconform -strict -summary -ignore-missing-schemas /tmp/rf-$$f.yaml || exit 1; \
	done

negative:
	bash $(CHART)/ci/negative-tests.sh $(CHART)

# Checks the chart's design assumptions against the real image. Slow (pulls a
# 3.2GB image, and is very slow under QEMU on arm64), so it is NOT part of the
# default `verify` target. Run it when bumping appVersion.
verify-image:
	bash $(CHART)/ci/verify-image-assumptions.sh $(IMAGE)

# Full lifecycle test on a live kind cluster (stub image, ~2 min): install,
# readiness, migration hook, preflight, rendered config, HTTP probes, rolling
# upgrade, datasync singleton invariant, uninstall leftovers.
e2e:
	bash $(CHART)/ci/e2e-deploy.sh

# Required before 'helm dependency build' for fresh checkouts.
repos:
	helm repo add valkey https://valkey.io/valkey-helm/ 2>/dev/null || true
	helm repo add opensearch https://opensearch-project.github.io/helm-charts/ 2>/dev/null || true

verify: lint validate negative
	@echo "all checks passed"

clean:
	rm -f /tmp/rf-*.yaml
