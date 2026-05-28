# ADR-004: Log Aggregation — Loki over ELK

## Status

Accepted — 2026-05-28

## Context

Atlas needs centralized log aggregation to complement Prometheus metrics.
During incident triage, an engineer who sees a metric anomaly needs to
correlate it with what the application actually logged at that moment.
Metrics are Atlas's primary observability signal; logs are the secondary
signal used for correlation and root-cause analysis.

Two hard constraints shape this decision:
- Local development runs on an 8GB MacBook Air. Memory is scarce.
- The production target is cost-conscious EKS. We want the same stack
  locally and in cloud, with low storage and compute cost at scale.

## Decision

We use Grafana Loki with Promtail as the log forwarder, deployed via the
loki-stack Helm chart in single-binary mode. Promtail runs as a DaemonSet,
tailing container logs on every node and shipping them to Loki. Grafana
queries Loki via LogQL, unifying metrics and logs in one interface.

## Alternatives Considered

### Loki + Promtail (chosen)

Loki indexes only labels (namespace, pod, container) — not log content.
Log lines are compressed and stored as chunks, cheaply. This index-free
architecture keeps resource use low: Loki ran in 128-256Mi on our cluster,
which made it viable on 8GB hardware where Elasticsearch could not fit.

Operationally it is simple: one Loki binary plus a Promtail DaemonSet,
versus ELK's multi-component stack. Loki reuses Prometheus's label model,
so LogQL (`{namespace="three-tier-dev"} |= "ERROR"`) matches the mental
model we already use for PromQL. Grafana ties metrics and logs together —
click from a latency spike to the logs at that timestamp. On EKS, Loki
backs onto S3 object storage, keeping cost low at scale.

### ELK / EFK Stack (Elasticsearch + Logstash/Fluentd + Kibana)

ELK is genuinely more powerful for log-centric workflows. Elasticsearch's
inverted index makes full-text search across all logs instant — searching
a stack-trace fragment everywhere is fast without needing good label
filters. Kibana offers deeper log visualization and analytics than
Grafana, and Elasticsearch aggregations on structured log fields are far
richer than LogQL. For a logging-centric product (SIEM, audit, security
analytics), ELK would be the correct choice.

It lost for Atlas specifically because: Elasticsearch's per-token indexing
demands gigabytes of RAM — incompatible with 8GB local development; the
multi-component JVM stack (Elasticsearch cluster + Logstash + Kibana +
Beats) is operationally heavy; and Atlas's logs are a secondary
correlation signal, not the primary product, so ELK's power doesn't
justify its cost here.

### Cloud-managed (CloudWatch Logs, GCP Cloud Logging)

Viable on EKS, but creates cloud lock-in and does not work in local kind
development. We want an identical stack locally and in cloud for
reproducibility. Rejected for portability.

## Consequences

### Positive

- Low resource footprint (128-256Mi) — the deciding factor on 8GB hardware.
- Same query/label model as Prometheus; one paradigm for metrics and logs.
- Grafana unifies metrics and logs for fast incident correlation.
- Cheap S3-backed chunk storage on EKS; low cost at scale.
- Simple operational model — one binary plus a DaemonSet.

### Negative / Trade-offs accepted

- Full-text search is weaker than Elasticsearch. Cross-cutting searches
  without good label filters scan chunks and are slower.
- No rich log-field analytics or aggregations like Kibana provides.
- If Atlas ever needs SIEM-style or log-analytics capabilities, this
  choice would need to be revisited.

### Neutral / Future

- If log volume or analytical needs grow significantly, revisit. Promtail
  can ship to multiple sinks, so migration or coexistence is feasible
  without re-instrumenting the workloads.

## References

- Implementation: gitops/platform/loki/ (Task 4.2)
- Loki documentation: https://grafana.com/docs/loki/
- Related: ADR-002 (GitOps engine); the broader observability stack
  (kube-prometheus-stack, Task 4.1)
