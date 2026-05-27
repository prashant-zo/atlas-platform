# ServiceMonitor Port Name Mismatch (ArgoCD + KPS)

**Date:** 2026-05-28
**Component:** ArgoCD metrics ↔ Prometheus
**Severity:** Silent failure — ServiceMonitor created, zero scrapes

## Symptom

After enabling `metrics.enabled: true` on every ArgoCD subcomponent and
creating a ServiceMonitor via `extraObjects`, Prometheus showed no
argocd targets and PromQL queries like `argocd_app_info` returned
empty results. No error logs in Prometheus or the Operator.

## Why It's Silent

ServiceMonitor matching has multiple layers:
1. `namespaceSelector` — which namespaces to watch
2. `selector.matchLabels` / `matchExpressions` — which services to pick
3. `endpoints[].port` — which named port on the selected services

If layers 1 and 2 match but layer 3 doesn't, Prometheus reports zero
targets but no error. The ServiceMonitor "works" — it just doesn't
discover any endpoints to scrape.

## Root Cause

ArgoCD Helm chart 7.6.12 creates four metrics services
(`argocd-server-metrics`, `argocd-repo-server-metrics`,
`argocd-application-controller-metrics`,
`argocd-applicationset-controller-metrics`).

Each service exposes a port **named `http-metrics`**, not `metrics`.

Our ServiceMonitor specified `port: metrics`, which matched zero ports.
Prometheus discovered the services via the label selector, looked for
a port named `metrics`, found none, scraped nothing, returned no error.

## Verification Pattern

Before writing any ServiceMonitor `endpoints[].port` value, query the
actual port names on the target services:

\`\`\`bash
for svc in argocd-server-metrics argocd-repo-server-metrics \
           argocd-application-controller-metrics \
           argocd-applicationset-controller-metrics; do
  echo "--- $svc ---"
  kubectl get svc -n argocd $svc -o jsonpath='{.spec.ports[*].name}'
  echo
done
\`\`\`

Output reveals the actual port names. ServiceMonitor `endpoints[].port`
must match exactly.

## Fix

\`\`\`yaml
endpoints:
  - port: http-metrics    # was: metrics
    interval: 30s
    path: /metrics
\`\`\`

## Interview Talking Point

> "ServiceMonitor failures are often silent — the resource gets
> created, Prometheus discovery runs, but if the port name doesn't
> match what the chart actually exposes, you get zero scrapes and
> no error. The lesson: always verify the actual port name on the
> target service before writing the ServiceMonitor. Chart conventions
> aren't standardized — some use `metrics`, some use `http-metrics`,
> some use `http`. The 1-second `kubectl get svc -o jsonpath` check
> saves the half-hour debug cycle."

## Diagnostic Sequence (For Reuse)

When `kubectl get servicemonitor` shows the resource exists but
PromQL returns nothing:

1. Verify ServiceMonitor was discovered by Prometheus:
   - Open `/service-discovery` in Prometheus UI
   - Look for the ServiceMonitor by namespace/name
   - If absent → namespace selector or RBAC issue

2. Verify Service labels match selector:
   - `kubectl get svc -n <ns> <svc> --show-labels`
   - Compare against ServiceMonitor selector matchExpressions

3. Verify port names match endpoints:
   - `kubectl get svc -n <ns> <svc> -o jsonpath='{.spec.ports[*].name}'`
   - Compare against ServiceMonitor endpoints[].port

4. Verify the scrape path returns metrics:
   - `kubectl exec -n <ns> deploy/prometheus -- wget -O- http://<svc>:<port>/metrics`
