# Argo Rollouts AnalysisTemplate — Empty Data At Canary Startup

**Date:** 2026-05-31
**Task:** 5.5 — wiring Prometheus AnalysisTemplate to canary

## Symptom

First canary attempt failed with the rollout aborted:

\`\`\`
RolloutAborted: Metric "p95-latency-ms" assessed Error due to
consecutiveErrors (5) > consecutiveErrorLimit (4):
"Error Message: reflect: slice index out of range"
\`\`\`

Stable pods kept serving 100% of traffic — the rollback worked. But
the canary failed for the wrong reason.

## Cause

When the canary pod first starts, no requests have hit it yet, so its
histogram is empty. The query:

\`\`\`promql
histogram_quantile(0.95,
  sum(rate(http_request_duration_seconds_bucket{version="v2"}[2m])) by (le)
) * 1000
\`\`\`

returns an empty vector `result: []` when no v2 samples exist. The
Argo Rollouts controller tries to evaluate `result[0] <= 500` on an
empty slice and panics in Go: `reflect: slice index out of range`.

That's classified as `Error`, not `Failed`. Five consecutive errors
exceeded `consecutiveErrorLimit: 4`, triggering automatic rollback.

## Fix — Two Parts

### 1. `initialDelay: 60s`

Wait one minute after the canary starts before running the first
analysis evaluation. Gives traffic time to flow and the histogram time
to populate. Prevents the first few checks from looking at empty data.

\`\`\`yaml
metrics:
  - name: p95-latency-ms
    initialDelay: 60s
    interval: 30s
    ...
\`\`\`

### 2. `OR on() vector(0)` fallback

Wrap each query so it returns 0 when no data exists, instead of an
empty vector. Even if the initial delay isn't enough, the controller
gets a real number to evaluate.

\`\`\`promql
(
  histogram_quantile(0.95,
    sum(rate(http_request_duration_seconds_bucket{version="v2"}[2m])) by (le)
  ) * 1000
) OR on() vector(0)
\`\`\`

The success-rate query needs this too — `OR on() vector(0)` makes a
zero-traffic canary fail the `>= 0.95` gate cleanly rather than panic.

## What The System Did Right

Even with the broken AnalysisTemplate, the system behaved exactly as
designed:

- Canary pod stayed isolated to 25% traffic (NGINX traffic routing)
- Stable v1 ReplicaSet was never touched — 4 pods kept serving
- When analysis errored 5 times, the rollout aborted automatically
- The canary ReplicaSet was scaled down
- No human action needed for the rollback

The bug was in our gating logic, not in the safety mechanism. The
safety mechanism worked perfectly.

## Lesson — Validate Queries Against Real Data Before Wiring

Before wiring an AnalysisTemplate, run each query directly against
Prometheus while data exists and confirm it returns a single scalar.
Then ask: what does this query return when the canary first starts and
has NO data yet? If the answer is "empty vector", add a fallback.

## Interview Talking Point

> "When I first wired the AnalysisTemplate, the canary aborted with a
> Go runtime error — `reflect: slice index out of range`. The root
> cause was an empty Prometheus result at canary startup: the histogram
> hadn't been populated yet because no v2 traffic had been served. The
> controller couldn't evaluate `result[0] <= 500` on an empty slice and
> classified it as Error, exceeding the error limit and triggering
> automatic rollback. The fix had two parts: an `initialDelay` of 60s
> so the histogram could populate before the first evaluation, and a
> Prometheus `OR on() vector(0)` fallback so empty results return zero
> instead of nothing. The system actually behaved correctly under the
> broken config — automated rollback to stable. The bug was in our
> gating logic, not the safety mechanism."
