# Phase B Take 2 — Known Issues & Pending Fixes

**Status:** Tracking for Phase B+1 / Week 7
**Created:** 2026-06-07

These are real bugs discovered during Phase B Take 2's EKS deploy.
Both have manual workarounds documented. Both need permanent fixes.

---

## TODO 1: ArgoCD Bootstrap Script — IPv6 localhost Resolution

**File:** `scripts/argocd-bootstrap.sh`
**Symptom:** `argocd login` fails with `dial tcp [::1]:8080: connect: connection refused`
**Root cause:** On modern macOS, `localhost` resolves to `::1` (IPv6) first. The `argocd` CLI uses this resolution and tries to connect to the IPv6 stack. Even when kubectl port-forward binds to both IPv4 and IPv6, the argocd CLI's request triggers an HTTP/2 stream protocol issue that drops the connection.

**Manual workaround used during Phase B Take 2:**
- Skip the script's CLI login step
- Use kubectl-direct operations (`kubectl patch application`, `kubectl get applications`) instead
- Use ArgoCD UI in browser for visual operations

**Permanent fix:**
Change line in `cli_login()` function:

```bash
# Before:
yes | argocd login "localhost:${LOCAL_PORT}" \

# After:
yes | argocd login "127.0.0.1:${LOCAL_PORT}" \
```

This forces explicit IPv4, bypassing the localhost-resolves-to-IPv6 trap.

**Estimated effort:** 2 minutes (one-line change, test, commit)
**Priority:** Medium — script works, just can't auto-login

---

## TODO 2: CNPG Webhook TLS Race On Fresh Deploy

**Files affected:**
- `gitops/platform/applicationsets/*.yaml` (sync wave annotations)
- Possibly `argocd values.yaml` (retry limit defaults)

**Symptom:** On fresh EKS deploys, `three-tier-dev` fails sync with:

failed calling webhook "mcluster.cnpg.io":
tls: failed to verify certificate: x509: certificate signed by unknown authority

After 5 retries (~3 minutes), ArgoCD marks operation Failed and stops auto-retrying.

**Root cause:**
CNPG operator generates self-signed CA on first startup (~30-60s) and injects it into webhook configurations. ArgoCD tries to create CNPG Cluster CRDs BEFORE this trust is established, causing TLS errors. ArgoCD's default retry limit (5) is exhausted before the webhook becomes trustable on a constrained EKS bootstrap.

**Manual workaround used during Phase B Take 2:**
```bash
# Force fresh sync after webhook is ready (verified via curl test)
kubectl patch application three-tier-dev -n argocd \
  --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD","syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}'
```

**Permanent fix (preferred — CNCF-aligned):**

Use ArgoCD sync waves to enforce operators-before-workloads:

```yaml
# In platform-cnpg-operator Application:
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # operators in wave -1

# In three-tier-dev Application:
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"    # workloads in wave 0
```

ArgoCD will wait for wave -1 to be Synced+Healthy before starting wave 0.

**Alternative fix (less elegant):**
Increase retry limit:

```yaml
spec:
  syncPolicy:
    retry:
      limit: 20                    # was 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 5m            # was 3m
```

Gives webhook more time to become available before giving up.

**Estimated effort:** 30 minutes (audit all ApplicationSets, add waves, test)
**Priority:** High — affects every fresh deploy

---

## TODO 3: gp3 StorageClass Already Done (For Reference)

**Status:** ✅ DONE in this session

We Terraform-managed the gp3 StorageClass via Kubernetes provider in iam-irsa module. No more manual `kubectl annotate gp2` needed. Default storage class is now fully reproducible.

See: `infrastructure/terraform/iam-irsa/storage-class-gp3.tf`

---

## Future Work (Lower Priority)

**TODO 4:** ADR-010 documenting gp3 over gp2 decision (we have the code, need the rationale doc)

**TODO 5:** Phase B Take 2 retrospective — what worked, what didn't, comparison to Phase B Take 1

**TODO 6:** Consider adding `cert-manager` to platform stack — manages TLS certs declaratively and could help with webhook bootstrap timing if combined with sync waves

---

## When To Tackle These

**Before any new EKS deploy:** Fix TODO 2 (sync waves) — otherwise the deploy will hit the same webhook race again.

**Before sharing repo publicly / portfolio submission:** Fix TODO 1 (script IPv4) and write TODO 5 (retrospective).

**Nice to have:** TODO 4 (ADR), TODO 6 (cert-manager).
