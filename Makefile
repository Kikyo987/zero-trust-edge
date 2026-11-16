# Zero-trust edge — local developer targets.
# Production apply still goes through terraform / k3s scripts with a human looking at the plan.

SHELL := /bin/bash
COMPOSE := docker compose -f docker/compose/docker-compose.yml
APP_IMAGE := ghcr.io/example/edge-echo
APP_TAG ?= dev

.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: dev-up
dev-up: ## Run app + Prometheus + Grafana + Loki + node-exporter + cAdvisor
	$(COMPOSE) up -d --build
	@echo "app          http://127.0.0.1:8080/healthz"
	@echo "grafana      http://127.0.0.1:3000"
	@echo "prometheus   http://127.0.0.1:9090"
	@echo "alertmanager http://127.0.0.1:9093"

.PHONY: dev-down
dev-down: ## Stop the local stack
	$(COMPOSE) down

.PHONY: dev-logs
dev-logs: ## Tail compose logs
	$(COMPOSE) logs -f --tail=100

.PHONY: image
image: ## Multi-stage production image
	docker build -t $(APP_IMAGE):$(APP_TAG) --target runtime docker/app

.PHONY: image-scan
image-scan: image ## Trivy FS + image (fails on HIGH/CRIT)
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
		aquasec/trivy:latest image --severity HIGH,CRITICAL --exit-code 1 $(APP_IMAGE):$(APP_TAG)

.PHONY: tf-fmt
tf-fmt: ## terraform fmt recursive
	terraform fmt -recursive terraform

.PHONY: tf-validate
tf-validate: ## validate the dev env (requires init)
	cd terraform/environments/dev && terraform validate

.PHONY: verify
verify: ## Zero-trust inbound checks (auto: compose laptop or node)
	./scripts/zero-trust-verify.sh

.PHONY: verify-compose
verify-compose: ## Laptop/compose: prove 127.0.0.1-only publishes
	./scripts/zero-trust-verify.sh --compose

.PHONY: mtu
mtu: ## Path MTU probe
	./scripts/mtu-path-check.sh

.PHONY: cost
cost: ## AWS idle-resource snapshot (needs AWS creds)
	./scripts/cost-snapshot.sh
