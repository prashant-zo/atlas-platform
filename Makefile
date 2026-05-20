# Atlas — Makefile

# Shell settings — strict mode for any inline shell snippets
SHELL          := bash
.SHELLFLAGS    := -euo pipefail -c
MAKEFLAGS      += --no-print-directory --warn-undefined-variables

# Project variables
CLUSTER_NAME   := atlas
REGISTRY_NAME  := kind-registry
REGISTRY_PORT  := 5001
KUBECTL_CTX    := kind-$(CLUSTER_NAME)

# Phony declarations — none of these are filenames
.PHONY: help verify up down restart platform status logs context \
        registry-list registry-size registry-gc \
        clean nuke

# Default target — show help
.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "Atlas — Makefile targets"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} \
		/^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@echo ""
	@echo "Examples:"
	@echo "  make verify              check environment is ready"
	@echo "  make up && make platform bring cluster online and install platform"
	@echo "  make down                tear cluster down (asks for confirmation)"

# Environment & cluster lifecycle
verify:
	@./scripts/verify-setup.sh

up:
	@./scripts/cluster-up.sh

down: 
	@./scripts/cluster-down.sh

restart: 
	@./scripts/cluster-down.sh --force --keep-registry
	@./scripts/cluster-up.sh


platform:
	@./scripts/platform-install.sh

# Observability into current state
status: 
	@echo "─── Cluster context ───"
	@kubectl config current-context 2>/dev/null || echo "(no cluster)"
	@echo ""
	@echo "─── Nodes ───"
	@kubectl get nodes -o wide 2>/dev/null || echo "(cluster unreachable)"
	@echo ""
	@echo "─── kube-system pods ───"
	@kubectl get pods -n kube-system 2>/dev/null || echo "(cluster unreachable)"
	@echo ""
	@echo "─── Registry ───"
	@docker ps --filter "name=$(REGISTRY_NAME)" \
		--format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true

logs: 
	@kubectl logs -n kube-system -l component=kube-apiserver --tail=50 -f

context:
	@kubectl config use-context $(KUBECTL_CTX)

# Registry helpers
registry-list: 
	@./scripts/registry-inspect.sh list

registry-size:
	@./scripts/registry-inspect.sh size

registry-gc:
	@./scripts/registry-inspect.sh gc

# Cleanup
clean:
	@./scripts/cluster-down.sh --force --keep-registry

nuke:
	@./scripts/cluster-down.sh --force
	@rm -rf $$HOME/.atlas/registry-data
	@echo "✓ All Atlas state removed"
