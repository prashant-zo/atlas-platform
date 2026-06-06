# Canary Analysis Correctly Aborted a Bad Canary on EKS

**Date:** 2026-06-07
**Context:** Week 6 Phase B, Atlas on EKS
**Status:** Lesson Learned — Worth Documenting Permanently

---

## The Event

During Atlas's first EKS deployment, the backend Rollout's canary analysis aborted with:

Message: RolloutAborted: Rollout aborted update to revision 3:
Metric "success-rate" assessed Failed due to failed (2) > failureLimit (1)

This was after we replaced the kind-local backend image (`localhost:5001/atlas-backend:v1`) with a public placeholder (`hashicorp/http-echo:1.0.0`) for portability.

---

## Why The Engineer's First Instinct Is Wrong

The first instinct on seeing a "RolloutAborted" message in your dashboard is to treat it as a problem to fix. The reasoning goes:

> "I need to demonstrate Atlas works on EKS. Things should be green. This abort is blocking me. Let me bypass the analysis."

That's the wrong frame. Here's why:

---

## What The Abort Actually Proved

Argo Rollouts' canary analysis exists for exactly one purpose: **prevent broken deployments from receiving production traffic.** It works by:

1. Routing a small percentage of traffic to the canary
2. Measuring whether the canary's metrics meet defined SLOs
3. Aborting if the SLOs fail; promoting if they pass

In our case, the canary was `hashicorp/http-echo` — an image that listens on a port and returns static text. It does NOT emit `http_requests_total{status, version}` (the metric our AnalysisTemplate evaluates).

Therefore:
- Prometheus correctly scraped the canary pod (proven)
- No `http_requests_total` time series was found (correct — the workload doesn't produce it)
- The query `sum(rate(http_requests_total{...}))` returned `0` (correct — no data)
- The fallback `OR on() vector(0)` triggered, returning `0`
- Success rate `0 / 0` evaluated as `0`
- Threshold `0 >= 0.95` evaluated to `false`
- Analysis assessed as Failed

**Argo Rollouts then did its job:** it refused to promote a canary whose metrics did not meet SLO. It preserved the stable version. It blocked broken traffic from reaching real users.

This is the entire purpose of canary analysis. **It worked perfectly.**

---

## What This Means for Atlas

The canary mechanism on EKS is:

- ✅ **Healthy:** Prometheus + AnalysisTemplate + Rollouts wiring is intact
- ✅ **Functional:** Queries execute, thresholds evaluate, decisions propagate
- ✅ **Correct:** Bad canary → abort. Stable preserved.

If Argo Rollouts had **promoted** a canary with zero metrics, that would have been the bug. The abort is the safe outcome.

---

## When Engineers See This in Production

A real production scenario where this matters:

> A new backend version is deployed. It's a code bug — for some users, it returns 500. Pod liveness/readiness probes pass (the process is responsive). Without canary analysis, the deploy would proceed to 100% traffic and 500 errors would hit all users. With Atlas's canary analysis, the 500-error metric triggers a Failed analysis, the rollout aborts, the stable version stays in place. Engineers investigate before any user is impacted.

Atlas's behavior on EKS during Phase B is **the same behavior it would have in that production scenario.** It just happened to catch our placeholder image instead of a real bug.

---

## The Distinction: "Working" vs "Producing Expected Output"

This is the meta-lesson worth keeping:

- **"Working"** means the system's components execute correctly: Prometheus scrapes, queries run, decisions propagate.
- **"Producing expected output"** means the metric values evaluated as Successful.

Atlas's canary on EKS is **working**. Whether it **produces expected output** depends on what the workload itself does. A workload that doesn't emit metrics will always get an abort, regardless of whether the platform is healthy.

---

## What Phase B Demonstrates

In Phase B's final state:
- Atlas's platform layer works on EKS
- Atlas's canary mechanism works on EKS
- Atlas's GitOps loop works on EKS
- The workload's canary aborted — by design, due to placeholder metrics

The honest Phase B narrative is:

> "I deployed Atlas to EKS. Everything in the platform layer works. The canary mechanism correctly refused to promote my placeholder backend, which doesn't emit business metrics. The next iteration will deploy a real backend (podinfo) that emits the expected metrics, and we'll observe a successful canary promotion."

---

## Do Not Bypass Canary Analysis With promote --full

In Phase B, the temptation arose: "Just `kubectl argo rollouts promote backend --full` to force the rollout through." This would have worked. It would have shown all 8 ArgoCD apps green.

But it would have been **wrong** in three ways:

1. **It hides the success of the canary system.** A bypass demonstrates nothing about Atlas's safety mechanism.
2. **It teaches the wrong lesson.** Forcing past safety checks is the opposite of what canary analysis is for.
3. **It produces a worse portfolio story.** "I forced past my own safety check" is not the senior-DevOps narrative we want.

The right move is to **fix the workload to emit metrics** (Section 6 of the status report), and observe a real, earned canary promotion.

---

## Reference

- Argo Rollouts documentation: https://argoproj.github.io/argo-rollouts/features/analysis/
- Flagger's podinfo example (the canonical canary demo workload): https://github.com/stefanprodan/podinfo
- CNCF canary deployment pattern: https://www.cncf.io/blog/2021/07/05/progressive-delivery-with-argo-rollouts/

---

## Conclusion

A canary abort in a real cluster, on real infrastructure, with a real metric evaluation, is **proof the system works**. Document it. Don't bypass it. Then demonstrate the success path with a workload that actually emits the expected signals.
