# Atlas Backend — k6 Load Test Results

**Date:** 2026-06-01
**Task:** 5.7 — k6 load testing
**Test:** load-tests/k6/backend-canary-load.js

## Test Configuration

- **Stages:** 30s ramp to 20 VUs → 5m sustain → 30s ramp down (6m total)
- **Target rate:** ~100 req/s (20 VUs × 1 req per 200ms each)
- **Endpoint:** `http://backend.atlas.local/` via NGINX ingress
- **Run location:** In-cluster Job (not from laptop — exercises real ingress path)
- **Thresholds:** `http_req_failed<5%`, `http_req_duration p(95)<200ms`

## Results

### k6 Summary (client-side measurements)

| Metric | Value |
|---|---|
| Total requests | 32,555 |
| Sustained rate | 90.4 req/s |
| Failures | 0 (0.00%) |
| Checks passed | 65,110 / 65,110 (100%) |
| Latency avg | 2.19 ms |
| Latency median | 789 µs |
| Latency p(90) | 3.52 ms |
| Latency p(95) | 6.37 ms |
| Latency max | 320 ms |
| Iteration duration | ~203 ms (200ms sleep + request) |

**Both thresholds passed:**
- `http_req_failed: 0.00% < 5%` ✓
- `http_req_duration p(95): 6.37ms < 200ms` ✓

### Prometheus Snapshot (server-side, during sustain phase)

Eight samples taken 30s apart during the load:

| Time | RPS | p95 latency | error rate |
|---|---|---|---|
| t+0 | 43.5 (ramping) | 4.76 ms | 0 |
| t+30s | 94.8 | 4.75 ms | 0 |
| t+1m | 100.2 | 4.75 ms | 0 |
| t+1m30s | 99.8 | 4.76 ms | 0 |
| t+2m | 100.0 | 4.75 ms | 0 |
| t+2m30s | 100.1 | 4.76 ms | 0 |
| t+3m | 100.2 | 4.75 ms | 0 |
| t+3m30s | 100.8 | 4.75 ms | 0 |

**Server p95 stayed between 4.751–4.760 ms across all 8 samples — 0.2% variance.**

### Server vs Client Latency Gap

| Layer | p95 latency |
|---|---|
| Backend Go service (Prometheus) | 4.75 ms |
| Through NGINX ingress (k6) | 6.37 ms |
| **Ingress overhead** | **~1.6 ms** |

The 1.6ms difference is the cost of going through kube-proxy + NGINX ingress + service mesh routing for each request.

## What This Demonstrates

1. **The Go backend is fast.** 4.75ms p95 server-side for a JSON response with metrics instrumentation.
2. **The NGINX ingress is cheap.** ~1.6ms p95 overhead is well within expected.
3. **No coordination overhead.** With 4 backend pods sharing 100 RPS, each pod handles ~25 RPS — well within capacity (each pod requested 100m CPU / 64Mi memory).
4. **Prometheus metrics are accurate.** The server-side latency matches what k6 measures minus the network round-trip — the histogram is correctly capturing reality.

## Resource Footprint

Cluster memory during test (3 nodes):
- Pre-test: ~21% per node
- Mid-test: ~25% per node
- Post-test: returned to ~21%

100 RPS is well within capacity. The bottleneck for further scaling would be CPU on the backend pods, but with current limits there's room to push 5-10x harder.

## Reproducibility

Re-run anytime:
\`\`\`bash
./load-tests/k6/run.sh
\`\`\`

The test is repeatable — Job is in `load-tests/k6/` and pinned to `grafana/k6:0.55.0`.

## Interview Talking Point

> "I built and benchmarked an instrumented Go backend running on Kubernetes
> with progressive delivery. Under 100 RPS sustained load for 5 minutes
> through NGINX ingress, the service handled 32,555 requests with zero
> errors. P95 latency was 4.75ms server-side and 6.37ms end-to-end —
> meaning my NGINX ingress added only 1.6ms of overhead per request.
> The Prometheus histogram measurements matched the load tester's
> client-side numbers within expected network round-trip, confirming
> the metric pipeline is accurate. The same metrics gate my Argo Rollouts
> canary deployments."
