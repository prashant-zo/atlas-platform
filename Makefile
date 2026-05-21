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
	argocd argocd-stop argocd-status \
	bootstrap-gitops \
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
verify: ## Verify local environment is ready (tools, daemon, ports)
	@./scripts/verify-setup.sh

up:     ## Bring up the kind cluster and local registry
	@./scripts/cluster-up.sh

down:   ## Tear down cluster and registry (asks for confirmation)
	@./scripts/cluster-down.sh

restart: ## Tear down and bring back up (force, keeps registry cache) 
	@./scripts/cluster-down.sh --force --keep-registry
	@./scripts/cluster-up.sh


platform: ## Install platform components onto the cluster
	@./scripts/platform-install.sh

# Observability into current state
status: ## Show cluster, nodes, and key pods at a glance
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

logs:   ## Tail key control-plane logs (Ctrl+C to stop)
	@kubectl logs -n kube-system -l component=kube-apiserver --tail=50 -f

context: ## Switch kubectl context to the Atlas cluster
	@kubectl config use-context $(KUBECTL_CTX)

# Registry helpers
registry-list: ## List all images stored in the local registry 
	@./scripts/registry-inspect.sh list

registry-size: ## Show registry disk usage
	@./scripts/registry-inspect.sh size

registry-gc: ## Run garbage collection on the local registry
	@./scripts/registry-inspect.sh gc

# Cleanup
clean:  ## Remove cluster but keep registry data
	@./scripts/cluster-down.sh --force --keep-registry

argocd: ## Bring up ArgoCD port-forward and CLI login
	@./scripts/argocd-bootstrap.sh

argocd-stop: ## Stop the ArgoCD port-forward
	@./scripts/argocd-bootstrap.sh --stop

argocd-status: ## Show ArgoCD port-forward and CLI status
	@./scripts/argocd-bootstrap.sh --status

bootstrap-gitops: ## Apply the root App-of-Apps (one-time setup)
	@echo "Applying root App-of-Apps..."
	@kubectl apply -f gitops/bootstrap/root-app.yaml
	@echo ""
	@echo "Root Application created. ArgoCD will now discover and reconcile"
	@echo "every child Application in gitops/apps/ within 3 minutes."
	@echo ""
	@echo "Watch progress with:"
	@echo "  argocd app list"
	@echo "  argocd app get root-app-of-apps"

nuke:   ## Remove EVERYTHING including registry data (DESTRUCTIVE)
	@./scripts/cluster-down.sh --force
	@rm -rf $$HOME/.atlas/registry-data
	@echo "✓ All Atlas state removed"
