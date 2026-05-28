# ADR-004: Log Aggregation — Loki over ELK

## Status

Accepted — 2026-05-28

## Context

[Write 2-3 sentences: Atlas needs centralized log aggregation to
complement Prometheus metrics. During incident triage, engineers need
to correlate a metric anomaly with what the application actually logged
at that moment. State the key constraint: this runs on an 8GB
development machine, and the production target is cost-conscious EKS.
Mention that metrics are the primary observability signal; logs are the
secondary correlation signal.]

## Decision

[State plainly: we chose Grafana Loki with Promtail as the log
forwarder, deployed via the loki-stack Helm chart in single-binary
mode. One or two sentences.]

## Alternatives Considered

### Loki + Promtail (chosen)
[2-4 sentences on why. Pull from the "case for Loki" above but in your
own words: index-free architecture, low resource cost critical on 8GB,
shared label model with Prometheus, unified in Grafana, object-storage
backing on EKS.]

### ELK / EFK Stack (Elasticsearch + Logstash/Fluentd + Kibana)
[Be FAIR here — this is the test of a good ADR. 2-4 sentences on what
ELK does better: full-text search across all logs, richer analytics
and aggregations on structured fields, mature Kibana ecosystem. Then
state why it lost FOR ATLAS specifically: resource cost incompatible
with 8GB local, operational complexity of a multi-component JVM stack,
and the fact that logs are our secondary signal not primary.]

### Cloud-managed (CloudWatch Logs, GCP Cloud Logging)
[1-2 sentences: viable on EKS, but creates cloud lock-in and doesn't
work in local kind development. We want the same stack locally and in
cloud. Rejected for portability.]

## Consequences

### Positive
[Bullet a few: low resource footprint, ran in 128-256Mi; same query
model as Prometheus; Grafana unifies metrics+logs; cheap S3-backed
storage on EKS; simple operational model.]

### Negative / Trade-offs accepted
[Be honest: full-text search is weaker than Elasticsearch; complex
cross-cutting log searches without good label filters are slower; if
Atlas ever needs log-based analytics or SIEM-style capabilities, we'd
need to reconsider. Document these as known limitations, not hidden.]

### Neutral / Future
[1-2 sentences: if log volume or analytical needs grow significantly,
revisit. The Promtail→Loki→Grafana pipeline can coexist with or migrate
to other backends since Promtail can ship to multiple sinks.]

## References

- Task 4.2 implementation: gitops/platform/loki/
- Loki docs: https://grafana.com/docs/loki/
- Related: ADR-002 (GitOps engine), the broader observability stack
