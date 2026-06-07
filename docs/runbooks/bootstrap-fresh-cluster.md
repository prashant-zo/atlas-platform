# Bootstrap A Fresh Atlas Cluster: Battle-Tested Runbook

**Purpose:** End-to-end commands to bring up a fresh atlas-eks-dev cluster with all platform components healthy, avoiding every issue encountered during Phase B and Phase B Take 2.

**Last updated:** 2026-06-08 (post Phase B Take 2)
**Validated against:** EKS v1.31, ap-south-1, ArgoCD 7.6.12, kube-prometheus-stack 65.5.1

---

## Prerequisites

Before starting, verify on your laptop:

```bash
# AWS profile configured
aws sts get-caller-identity --profile atlas
# Expected: account 816621202130, user atlas-admin

# Tools installed
terraform version    # >= 1.6
kubectl version --client
helm version
aws-iam-authenticator version
kubectl-argo-rollouts version

# Working directory clean
cd "/Users/prashant/Documents/The Helios Project/DevOps/Project/atlas"
git status   # should be clean on main
```

---

## Phase 0: Cost Awareness

A full bootstrap costs ~$0.20/hour while running. Plan to destroy within 4–6 hours unless you're actively working.

---

## Phase 1: Infrastructure (Terraform)

**Goal:** VPC, EKS cluster, IRSA roles, EBS CSI driver, gp3 StorageClass — all via Terraform.

```bash
cd infrastructure/terraform
./bootstrap.sh
```

This script handles:
- `terraform init` with S3 backend (`prashant-terraform-state-2024`)
- `terraform apply` for VPC, EKS, node group
- `terraform apply` for IRSA module (ALB Controller, External Secrets, EBS CSI)
- EBS CSI addon registration with EKS
- gp3 default StorageClass creation via kubernetes provider

**Expected duration:** ~22 minutes (EKS cluster creation dominates).

**Validate before proceeding:**

```bash
# Cluster accessible
aws eks update-kubeconfig --name atlas-eks-dev --region ap-south-1 --profile atlas
kubectl get nodes
# Expected: 2 nodes Ready (t3.large SPOT)

# IRSA roles created
aws iam list-roles --profile atlas | grep atlas-eks-dev
# Expected: aws-lb-controller, external-secrets, ebs-csi-driver

# EBS CSI driver running
kubectl get pods -n kube-system | grep ebs-csi
# Expected: ebs-csi-controller (2 pods), ebs-csi-node DaemonSet (1 per node)

# gp3 is the default StorageClass
kubectl get storageclass
# Expected: gp3 (default), gp2 (no default annotation)
```

---

## Phase 2: Platform Bootstrap (Helm)

**Goal:** Install ALB Controller, ArgoCD, Prometheus CRDs — the bare minimum so ArgoCD can take over the rest.

```bash
cd "/Users/prashant/Documents/The Helios Project/DevOps/Project/atlas"
./scripts/platform-install.sh
```

This script handles:
- AWS Load Balancer Controller install with **explicit** `vpcId` and `region` (avoids IMDS auto-discovery race)
- Prometheus Operator CRDs pre-install (avoids ArgoCD ServiceMonitor sync failures later)
- ArgoCD chart 7.6.12 install with bootstrap config

**Expected duration:** ~3 minutes.

**Validate before proceeding:**

```bash
# ALB Controller running
kubectl get pods -n kube-system | grep aws-load-balancer-controller
# Expected: 2 pods Running 1/1

# ArgoCD running
kubectl get pods -n argocd
# Expected: server, repo-server, application-controller, applicationset-controller,
#           dex-server, notifications-controller, redis — all Running

# Prometheus CRDs installed
kubectl get crd | grep monitoring.coreos.com
# Expected: ServiceMonitor, PodMonitor, PrometheusRule, Probe, etc.
```

---

## Phase 3: ArgoCD Bootstrap

**Goal:** Get ArgoCD CLI logged in. Then ArgoCD takes over the rest.

```bash
./scripts/argocd-bootstrap.sh
```

**KNOWN ISSUE (will be fixed):** This script uses `localhost:${LOCAL_PORT}` for `argocd login`. On modern macOS, `localhost` resolves to IPv6 `[::1]` but the port-forward binds to IPv4 `127.0.0.1`. Connection refused.

**WORKAROUND until script is fixed:** edit `scripts/argocd-bootstrap.sh` and change:
```bash
argocd login "localhost:${LOCAL_PORT}" --insecure --plaintext ...
```
to:
```bash
argocd login "127.0.0.1:${LOCAL_PORT}" --insecure --plaintext ...
```

**Validate:**

```bash
argocd account get-user-info
# Expected: Logged In: true, Username: admin
```

---

## Phase 4: GitOps Bootstrap

**Goal:** Apply the root App-of-Apps. ArgoCD then syncs all platform and workload components.

```bash
make bootstrap-gitops
```

This applies `gitops/root-app-of-apps.yaml` which references all ApplicationSets.

**Expected duration:** ~5–10 minutes for everything to sync.

**Watch progress:**

```bash
# In one terminal
watch -n 5 'kubectl get applications -n argocd'

# Or via UI
kubectl port-forward -n argocd svc/argocd-server 8080:443
# Open https://127.0.0.1:8080 (admin / password from bootstrap script output)
```

**Expected end state:** All 8 applications Synced + Healthy:
- argo-rollouts
- cnpg-operator
- ingress-nginx
- kube-prometheus
- loki
- metrics-server
- root-app-of-apps
- three-tier-dev (the workload)

---

## Phase 5: Known Issues To Watch For

### Issue: CNPG webhook TLS race on three-tier-dev sync

**Symptom:** `three-tier-dev` Application shows `Failed` with `tls: failed to verify certificate: x509: certificate signed by unknown authority` for `mcluster.cnpg.io`.

**Cause:** CNPG operator generates self-signed webhook CA on first start (~30–90s). If three-tier-dev syncs before the CA is propagated, webhooks reject CNPG Cluster creation.

**Fix:**
```bash
kubectl patch application three-tier-dev -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD","syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}'
```

Within 30 seconds: CNPG Cluster created, Pooler created, ScheduledBackup created.

**Long-term fix:** ArgoCD sync waves on ApplicationSets (cnpg-operator wave -1, workloads wave 0). Tracked in `phase-b-take-2-todo.md`.

### Issue: three-tier-dev shows OutOfSync (but Healthy) after sync

**Symptom:** App stays OutOfSync because Argo Rollouts mutates the canary Service with `rollouts-pod-template-hash` selector and `argo-rollouts.argoproj.io/managed-by-rollouts` annotation.

**Fix:** Already in `gitops/apps/workloads-non-prod.yaml` ApplicationSet template via `ignoreDifferences`. Should auto-sync.

### Issue: Prometheus pod OOMKills periodically

**Symptom:** `prometheus-kps-kube-prometheus-stack-prometheus-0` restarts every ~10 minutes with Exit Code 137.

**Fix:** Already in `gitops/platform/kube-prometheus/values.yaml` (limits.memory: 2Gi, requests.memory: 1Gi). Should NOT happen on fresh cluster after this fix.

---

## Phase 6: Workload Verification

Once everything is green:

```bash
# Backend Rollout healthy
kubectl argo rollouts get rollout backend -n three-tier-dev
# Expected: Status Healthy, Step 6/6, 4/4 pods Ready

# Postgres healthy
kubectl get cluster pg -n three-tier-dev
# Expected: 3 pods (pg-1 primary, pg-2/pg-3 replicas) Ready, Status "Cluster in healthy state"

# Connection pooler
kubectl get pods -n three-tier-dev -l cnpg.io/poolerName=pg-pooler-rw
# Expected: 2 pods Running

# All PVCs bound to gp3
kubectl get pvc -A
# Expected: all STORAGECLASS = gp3, all STATUS = Bound

# Continuous archiving working
kubectl describe scheduledbackup pg-daily -n three-tier-dev | grep -A2 "Last Backup"
# Expected: success status
```

---

## Phase 7: Teardown

When done for the day:

```bash
cd "/Users/prashant/Documents/The Helios Project/DevOps/Project/atlas/infrastructure/terraform"
./destroy.sh
# Type "destroy atlas" when prompted
```

**Expected duration:** ~15 minutes.

**Validate destruction:**

```bash
aws eks describe-cluster --name atlas-eks-dev --region ap-south-1 --profile atlas 2>&1 | head -3
# Expected: ResourceNotFoundException

# Confirm no lingering EBS volumes (CSI sometimes leaves them)
aws ec2 describe-volumes --region ap-south-1 --profile atlas \
  --filters "Name=tag:kubernetes.io/cluster/atlas-eks-dev,Values=owned" \
  --query 'Volumes[*].VolumeId' --output text
# Expected: empty
```

---

## Total Timing (Fresh Bootstrap)

| Phase | Duration | What Happens |
|---|---|---|
| 1. Terraform | ~22 min | VPC, EKS, IRSA, gp3 |
| 2. Platform bootstrap | ~3 min | ALB, ArgoCD, Prom CRDs |
| 3. ArgoCD login | ~30 sec | CLI auth |
| 4. GitOps sync | ~10 min | All Applications green |
| 5. CNPG webhook retry | ~1 min | Manual patch if hit |
| 6. Verification | ~2 min | Smoke tests |
| **Total** | **~40 min** | Healthy cluster ready for work |

---

## Quick Reference: Common Commands

```bash
# Get ArgoCD admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# Port-forward ArgoCD UI (use 127.0.0.1 not localhost)
kubectl port-forward -n argocd svc/argocd-server 8080:443

# Watch all Apps
watch -n 5 'kubectl get applications -n argocd'

# Watch backend Rollout
kubectl argo rollouts get rollout backend -n three-tier-dev --watch

# Force ArgoCD refresh of an app
kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=normal --overwrite

# Force sync an app
kubectl patch application <name> -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

---

## Pending Improvements (Will Eliminate Steps Above)

Tracked in `docs/learning/week-6-eks/phase-b-take-2-todo.md`:

1. Fix `scripts/argocd-bootstrap.sh` to use `127.0.0.1` (eliminates Phase 3 workaround)
2. Add ArgoCD sync waves to ApplicationSets (eliminates Phase 5 CNPG race)
3. Add `/healthz` to atlas-backend, decouple liveness probe from data endpoint (eliminates canary contamination)
4. Write ADR-010: gp3 over gp2 decision rationale
5. Write ADR-011: health-check endpoint separation
6. Write ADR-012 (Phase B retrospective)

Once these land, this runbook should be: `terraform apply && wait 40 min && work`.
