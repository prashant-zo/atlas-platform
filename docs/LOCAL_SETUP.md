# Local Setup — Running Atlas Platform On Your Mac

This guide walks you through running Atlas Platform locally on a Mac
using kind (Kubernetes IN Docker) on top of Colima as the Docker runtime.

Tested on macOS Sonoma 14+ with M-series Apple Silicon. Should work
on Intel Macs and Linux with minor adjustments.

**Time to first running cluster:** ~10 minutes after prerequisites
are installed.

---

## Prerequisites

You need these tools installed before bringing up the cluster:

| Tool | Purpose | Install Command |
|---|---|---|
| Homebrew | Mac package manager | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| Colima | Docker runtime for Mac (no Docker Desktop needed) | `brew install colima` |
| Docker CLI | Docker client | `brew install docker` |
| kind | Kubernetes in Docker | `brew install kind` |
| kubectl | Kubernetes CLI | `brew install kubectl` |
| Helm | Kubernetes package manager | `brew install helm` |
| Kustomize | Manifest customization | `brew install kustomize` |
| Git | Version control | `brew install git` |
| Make | Build tool (preinstalled on Mac) | — |

Optional but useful:

| Tool | Purpose | Install Command |
|---|---|---|
| k9s | Terminal UI for Kubernetes | `brew install k9s` |
| argo-rollouts plugin | Manage canary rollouts from CLI | `brew install argoproj/tap/kubectl-argo-rollouts` |
| argocd CLI | ArgoCD CLI client | `brew install argocd` |

---

## Hardware Requirements

| Resource | Minimum | Recommended |
|---|---|---|
| RAM | 8 GB | 16 GB |
| CPU | 2 cores | 4 cores |
| Disk | 20 GB free | 40 GB free |

On an 8 GB Mac, Atlas's local cluster will consume most of your
available RAM. Close browser tabs and IDEs before bringing it up.

---

## Step 1 — Start Colima

Colima provides a lightweight VM that runs Docker without needing
Docker Desktop.

Start it with enough resources for kind:

````bash
colima start --cpu 4 --memory 6 --disk 30
````

Flags explained:

- `--cpu 4` — 4 vCPUs for the VM (adjust based on your Mac)
- `--memory 6` — 6 GB RAM allocated to the VM
- `--disk 30` — 30 GB disk for the VM

For 8 GB Macs: use `--cpu 2 --memory 4 --disk 20` (tighter budget).
For 16 GB Macs: use `--cpu 4 --memory 8 --disk 40`.

Verify Colima is running:

````bash
colima status
````

Verify Docker works through Colima:

````bash
docker ps
docker info | grep "Server Version"
````

---

## Step 2 — Clone The Repository

If you haven't already:

````bash
git clone https://github.com/prashant-zo/atlas-platform.git
cd atlas-platform
````

---

## Step 3 — Verify Your Environment

The Makefile has a built-in verification target that checks for all
required tools:

````bash
make verify
````

This confirms that kind, kubectl, helm, kustomize, and Docker are all
installed and accessible. Fix any reported issues before proceeding.

---

## Step 4 — Bring The Cluster Up

Three sequential commands bring up the full platform:

````bash
# 1. Create the kind cluster
make up

# 2. Install platform components (Prometheus, Loki, Grafana, etc.)
make platform

# 3. Bootstrap GitOps (installs ArgoCD and configures app-of-apps)
make bootstrap-gitops
````

Each command takes 2-5 minutes. Watch the output — it streams progress
through each stage.

---

## Step 5 — Verify The Cluster Is Healthy

Quick status check:

````bash
make status
````

You should see:

- 3-node kind cluster running
- ArgoCD pods healthy in `argocd` namespace
- Platform applications synced
- Dev environment workloads scheduled

Manual verification:

````bash
# All pods across all namespaces
kubectl get pods -A

# ArgoCD application status
kubectl get applications -n argocd

# Backend rollout status
kubectl argo rollouts get rollout backend -n three-tier-dev
````

---

## Step 6 — Access The UIs

### ArgoCD UI

````bash
# Port-forward to local
kubectl port-forward -n argocd svc/argocd-server 8080:443

# In browser: https://localhost:8080
# Username: admin
# Password (initial admin):
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
````

### Grafana

````bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# In browser: http://localhost:3000
# Username: admin
# Password: prom-operator (default)
````

### Argo Rollouts UI

````bash
kubectl argo rollouts dashboard
# Opens browser automatically at http://localhost:3100
````

---

## Step 7 — Tear Down When Done

Free up resources when you're not actively using the cluster:

````bash
# Delete kind cluster (frees most resources)
make down

# Stop Colima VM (frees ~4 GB RAM)
colima stop

# Full cleanup including Colima VM disk (frees ~10 GB)
colima delete
````

To verify cleanup worked:

````bash
kind get clusters    # should show no clusters
colima status        # should show stopped or "no instances"
docker ps -a         # should show no containers
````

---

## Common Issues

### Colima Fails To Start With "x86_64 emulation" Error

This affects M-series Macs. Force ARM64 mode:

````bash
colima start --arch aarch64 --cpu 4 --memory 6
````

### kind Cluster Creation Fails

Usually because Colima isn't running or has insufficient resources.
Check:

````bash
colima status
docker info | grep "Total Memory"
````

If Total Memory shows <4 GiB, restart Colima with more memory:

````bash
colima stop
colima start --cpu 4 --memory 6 --disk 30
````

### Pods Stuck In Pending With "Insufficient memory" Errors

Your Mac doesn't have enough RAM allocated to Colima. Increase it:

````bash
colima stop
colima start --cpu 4 --memory 8 --disk 30
````

### kubectl Commands Fail With "Connection refused"

Your kubeconfig context isn't pointing at the kind cluster. Fix it:

````bash
kubectl config use-context kind-atlas
kubectl cluster-info
````

### ArgoCD Apps Stuck Syncing

The platform Apps need to come up in order (sync waves). Wait 5-10
minutes after `make bootstrap-gitops` — operators like CNPG can take
a few minutes to register their CRDs.

Force sync if stuck:

````bash
kubectl patch application three-tier-dev -n argocd \
  --type merge -p '{"operation":{"sync":{}}}'
````

### Disk Filling Up Fast

Docker images accumulate over time. Clean periodically:

````bash
docker system prune -a --volumes -f
````

---

## Resource Footprint

When fully running, Atlas Platform on kind consumes approximately:

| Resource | Usage |
|---|---|
| RAM | 4-6 GB |
| CPU | 2-4 cores active |
| Disk (Docker images + volumes) | 8-15 GB |
| Network ports used | 6080, 8080, 3000, 3100 (port-forwards) |

This is more than a typical local dev environment because Atlas runs
the entire platform stack: 3 environments × multiple components +
observability + GitOps controller + database operator.

For lighter local dev, you can run only the dev environment by
modifying `gitops/apps/workloads-non-prod.yaml` to exclude staging.

---

## Quick Reference — Cluster Lifecycle

````bash
# Start fresh
colima start --cpu 4 --memory 6 --disk 30
make up && make platform && make bootstrap-gitops

# Check status
make status

# Stop for the day (saves resources, can resume)
make down
colima stop

# Resume tomorrow (must recreate kind cluster, Colima resumes)
colima start
make up && make platform && make bootstrap-gitops

# Full nuclear cleanup
make down
colima delete
docker system prune -a --volumes -f
````

---

## See Also

- [README.md](../README.md) — Project overview and architecture
- [Makefile](../Makefile) — All cluster lifecycle commands
- [docs/adr/](./adr/) — Architecture decision records
- [docs/runbooks/](./runbooks/) — Operational procedures
- [infrastructure/terraform/](../infrastructure/terraform/) — AWS EKS setup
  (separate from this local guide)

For running on AWS EKS instead of kind, see the
[Quick Start section in README.md](../README.md#quick-start).
