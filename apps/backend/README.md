# Atlas Backend — Instrumented Go Service

Minimal HTTP service for testing progressive delivery. Exposes
Prometheus metrics so AnalysisTemplates can gate canary promotion
on real application signals.

## Endpoints

- `GET /` — returns `{"version":...,"status":"healthy","service":"backend-api"}`
- `GET /metrics` — Prometheus metrics

## Metrics

- `http_requests_total{version, status}` — counter
- `http_request_duration_seconds{version}` — histogram

## Env vars

- `VERSION` — version string (default `v1`)
- `PORT` — listen port (default `5678`)
- `FAIL_RATE` — fraction of requests returning 500 (default `0`)
- `LATENCY_MS` — artificial latency in ms (default `0`)

`FAIL_RATE` and `LATENCY_MS` exist so we can ship a deliberately
broken canary for the INC-004 GameDay (Task 5.9) — the AnalysisTemplate
should detect the elevated error rate / latency and trigger rollback.

## Build and push

\`\`\`bash
cd apps/backend

# linux/arm64 matches the kind nodes on M1
docker buildx build \
  --platform linux/arm64 \
  -t localhost:5001/atlas-backend:<tag> \
  --load .

docker push localhost:5001/atlas-backend:<tag>
\`\`\`

For a broken-canary build later, set FAIL_RATE in the Rollout's
env (no rebuild needed — the env var changes runtime behavior).

## Image base

`gcr.io/distroless/static-debian12:nonroot` — ~10MB final image,
no shell, runs as nonroot. Production-grade base.
