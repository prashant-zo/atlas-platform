# Tomorrow's Attack Plan — Phase B+1 / Pre-Week 7

**Generated:** 2026-06-08, after Phase B Take 2 demo session  
**Goal:** Land the canary demo we wanted, then move forward to Week 7 (Loki deep-dive, etc.)

---

## Priority 1: Fix The Canary Demo (Morning, ~2 hours)

The Phase 2 canary demo we documented as "false promotion → CrashLoop" exists ONLY because livenessProbe hits `/` which is the same endpoint that applies FAIL_RATE.

### The Fix

**File:** `apps/backend/main.go`

Add a new HTTP handler that always returns 200, regardless of FAIL_RATE:

```go
// In setupRoutes() or main():
http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("ok"))
})
```

The existing `/` handler keeps its FAIL_RATE logic for business traffic.

### The Manifest Change

**File:** `gitops/workloads/three-tier-app/base/backend-rollout.yaml`

Change probes from `path: /` to `path: /healthz`:

```yaml
livenessProbe:
  httpGet:
    path: /healthz   # was: /
    port: 5678
readinessProbe:
  httpGet:
    path: /healthz   # was: /
    port: 5678
```

### Build And Push

```bash
# Tag as v3, push via GitHub Actions workflow
# Already configured in .github/workflows/build-backend.yml
# Tag a new release manually or trigger workflow_dispatch
```

### Test The Demo (Clean Version)

1. Fresh cluster bootstrap (using `bootstrap-fresh-cluster.md` runbook)
2. Verify clean baseline (Phase 1 success demo with LATENCY_MS=5)
3. **The actual interview demo:** Push FAIL_RATE=0.5
   - Expected: AnalysisRun measures success-rate ~0.5, fails (2 > failureLimit 1)
   - Expected: Canary aborts at step 0/6, stable preserved
   - Expected: Pods stay healthy (probes hit `/healthz` always returning 200)
   - **This is the clean canary failure demo for the loom video**

4. Optional: Push FAIL_RATE=0.3
   - Expected: Same — aborts because 0.7 < 0.95 threshold

---

## Priority 2: Loom Video (~1 hour, afternoon)

Once Priority 1 lands and demo is clean:

Record loom showing:
1. Fresh cluster + workload up (use timelapse / fast-forward, real bootstrap is 40 min)
2. Argo Rollouts UI showing healthy Rollout
3. Git commit with FAIL_RATE=0.5
4. ArgoCD UI detecting the commit
5. Rollout creating canary ReplicaSet
6. AnalysisRun querying Prometheus (show kubectl logs)
7. AnalysisRun marked Failed
8. Rollout aborted, stable preserved
9. Brief narration on multi-layer defense and design choices

Save as `docs/learning/week-6-eks/canary-demo-loom.md` with the video link.

---

## Priority 3: Outstanding Phase B Cleanup (~30 min)

### Fix `scripts/argocd-bootstrap.sh`

```bash
# Edit the file
nvim scripts/argocd-bootstrap.sh

# Change line that does:
#   argocd login "localhost:${LOCAL_PORT}" ...
# To:
#   argocd login "127.0.0.1:${LOCAL_PORT}" ...

git add scripts/argocd-bootstrap.sh
git commit -m "fix(scripts): use 127.0.0.1 in argocd login to avoid IPv6 issues on macOS"
git push
```

### Add ArgoCD Sync Waves

**File:** `gitops/apps/platform-non-prod.yaml` (and any other ApplicationSet that includes CNPG)

Add to operators (cnpg-operator, argo-rollouts, etc.):
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

Add to workloads (three-tier-dev):
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"   # default but explicit
```

Effect: operators install first, webhooks ready, then workloads sync without race.

---

## Priority 4: ADRs (~1 hour, evening)

Write three short ADRs documenting today's design decisions:

### ADR-010: Use gp3 as default StorageClass (Atlas-managed via Terraform)

- Context: EKS provides gp2 as default, but no default annotation, causing Pending PVCs.
- Decision: Create gp3 StorageClass via Terraform's kubernetes provider, mark as default.
- Consequences: All Atlas PVCs use gp3 (better cost/IOPS), no dependence on EKS defaults.

### ADR-011: Decouple liveness/readiness probes from business endpoints

- Context: Phase B Take 2 demonstrated canary analysis contamination when probes share the endpoint that has failure injection.
- Decision: Add `/healthz` endpoint always returning 200, point probes there. Keep business endpoint subject to chaos/failure tools.
- Consequences: Probes only catch process crashes. Canary analysis can correctly measure business-level failure rates. Demo works as designed.

### ADR-012: Phase B Take 2 Retrospective

- Context: What went well, what failed, what we learned across two days of intensive Phase B work.
- Lessons:
  - GitOps + Helm vendored charts are robust but vendored charts hide upstream defaults (Prometheus 512Mi limit)
  - Webhook bootstrap races are real (CNPG); sync waves solve this
  - Liveness probes can blind canary analysis (the lesson)
  - Multi-day work with detailed docs lets future-self / Day 2 engineers ramp fast
- References: All Phase B docs in `docs/learning/week-6-eks/`

---

## Priority 5: Move Forward (Week 7 Start)

Once above lands cleanly, Week 7 begins. Topics queued:

1. Loki deep-dive: log queries, alerting on log patterns, troubleshooting flows
2. Grafana dashboards: Atlas-specific dashboards for platform health and workload SLOs
3. Networking deep-dive: ingress patterns, mTLS, network policies
4. (TBD based on interview-prep priorities)

---

## Open Questions / Decisions Pending

1. **Single cluster vs multi-cluster for Atlas demo?** Currently atlas-eks-dev (single cluster, multiple namespaces simulating envs). For senior DevOps interviews, consider adding atlas-eks-staging to show multi-cluster GitOps. **Decision needed before Week 8.**

2. **Continuous bootstrap vs manual?** Should `bootstrap.sh` + `platform-install.sh` + `argocd-bootstrap.sh` + `bootstrap-gitops` be a single `make atlas-up` command? **Decision after Priority 3 lands (the script fix prerequisites it).**

3. **Cost monitoring?** Add a daily `aws-cost-explorer` query to track Atlas spend. **Low priority.**
