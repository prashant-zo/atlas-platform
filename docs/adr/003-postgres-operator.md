# ADR-003: Use CloudNativePG for Managed Postgres

**Status:** Accepted
**Date:** 2026-05-26
**Deciders:** Prashant

## Context

Atlas requires a production-grade Postgres deployment supporting:
- Streaming replication (1 primary + N standbys)
- Automated failover on primary loss
- Continuous WAL archiving to S3-compatible storage
- Scheduled base backups with point-in-time recovery
- Connection pooling
- All managed declaratively via Kubernetes CRs and GitOps

Three serious Kubernetes operators address this space, all CNCF-affiliated or production-proven at scale:
- **CloudNativePG (CNPG)** — CNCF Sandbox, originated at EDB
- **Crunchy PGO** — Postgres Operator from Crunchy Data
- **Zalando postgres-operator** — pioneered the space, runs Zalando's production

The choice affects the entire database layer of Atlas plus the EKS Week 6 validation. Switching operators mid-project would mean rewriting CRs, runbooks, and the backup configuration.

## Decision

We will use **CloudNativePG (CNPG) version 1.24+** as the Postgres operator for Atlas. Installation via the official Helm chart wrapped in our platform's Kustomize ApplicationSet. Workloads consume Postgres through the `Cluster`, `ScheduledBackup`, and `Pooler` CRDs.

## Alternatives Considered

### Option A: Crunchy PGO (Postgres Operator)

- **Pros:** Long production track record, owned by Crunchy Data who employ several Postgres core committers, strong support for advanced features (pg_audit, custom extensions), commercial support available.
- **Cons:** Licensing has changed over its history — the operator is open source but Crunchy Data's commercial Postgres bundle has separate licensing that introduces complexity for adopters comparing it to alternatives. Documentation has been historically denser and less GitOps-native (heavy reliance on the `pgo` CLI tool). Newer versions are improving on both fronts but the operational surface is still larger.
- **Rejected because:** The CLI-first operational model conflicts with Atlas's GitOps-everywhere principle. CNPG's design — every operation expressible as a CR — fits the GitOps pattern more cleanly. The Crunchy track record matters for very large production deployments; for Atlas's scope, the simpler CR-first approach is the better fit.

### Option B: Zalando postgres-operator

- **Pros:** The original Postgres operator in this ecosystem — Zalando runs this at scale across thousands of clusters. Mature handling of complex topologies. Strong logical backups via WAL-E/WAL-G.
- **Cons:** The `postgresql` CR (their custom resource name) is a less expressive API surface than CNPG's. Configuration relies heavily on YAML annotations and ConfigMap parameters rather than first-class CR fields. The operator does not ship its own Helm chart in a maintained state — community charts exist but with varying quality. Project velocity has slowed in recent years as Zalando focuses inward.
- **Rejected because:** The annotation-heavy configuration model is a step backwards from CNPG's typed-field CRs. Active development velocity matters for a multi-year-relevant project like Atlas; CNPG's CNCF Sandbox status and 2024-2026 release cadence signal a healthier project trajectory.

### Option C: Bitnami PostgreSQL HA Helm Chart (No Operator)

- **Pros:** No operator to install — just `helm install`. Lighter footprint. Uses repmgr for replication management.
- **Cons:** All operational logic lives in shell scripts inside the Helm chart. Failover, backup, restore, replication reconfiguration — all handled by repmgr running inside containers, not by a Kubernetes-native controller. No CRDs, no declarative state, no GitOps story beyond `helm upgrade`.
- **Rejected because:** This is fundamentally not the "stateful workloads as Kubernetes-native CRs" pattern Atlas is designed to demonstrate. Bitnami's chart is fine for "I need Postgres on Kubernetes quickly" but not for "I am demonstrating senior platform engineering practice."

### Option D: AWS RDS (Cloud-Managed)

- **Pros:** AWS handles all operational concerns. Production-proven. Multi-AZ failover, automated backups, PITR — all click-to-enable.
- **Cons:** Not Kubernetes-native. Backups go to AWS-managed S3, not your control. Tightly couples the project to AWS. Adds significant cost on the EKS validation weekend.
- **Rejected because:** Atlas's purpose includes demonstrating that the platform engineer can run stateful workloads on Kubernetes. Delegating the database to RDS removes the most interesting part of the project from a senior-interview perspective. For real production we'd absolutely consider RDS — different decision context.

## Consequences

### Positive

- **CR-driven everything.** Cluster topology, backup policy, connection pooling are all declarative resources in Git. Disaster recovery is "re-apply the manifests."
- **Idiomatic GitOps integration.** Every CNPG resource fits naturally into the platform ApplicationSet model with no special handling.
- **Active project.** CNPG releases roughly monthly with substantive feature additions. The roadmap aligns with Postgres community direction (logical replication, CDC, Postgres 17+ features).
- **Built-in PgBouncer integration.** The `Pooler` CR is a first-class resource — we don't bolt on a separate pooler.
- **Continuous backup via barman-cloud.** Industry-standard tool, well-understood operationally, S3-protocol-compatible (works on real S3, MinIO, GCS, etc.).
- **Strong defaults.** Streaming replication, automatic failover, health checks, TLS between instances — all on by default. Compare to bare StatefulSet where every safety feature is your responsibility.

### Negative

- **Smaller community than Crunchy PGO.** Stack Overflow answers exist but the depth of historical troubleshooting content is thinner. Mitigated by clear official docs and an active Slack.
- **No commercial support contract available** in the way Crunchy offers. For a real fintech production deployment this matters; for Atlas it doesn't.
- **Operator dependency.** If CNPG ever stagnates (project archived, security disclosure unfixed for months, etc.) we'd need to migrate. Mitigated by the operator's CNCF Sandbox status — that brings governance and continuity guarantees.
- **Helm-in-Kustomize integration friction.** The operator installs via Helm chart but the platform layer uses Kustomize. We hit a real bug here: namespace injection through Kustomize+Helm has [a known sharp edge](../learning/week-3-database/helm-in-kustomize-namespace.md) that took multiple iterations to resolve. Worth being aware of when adopting CNPG via Kustomize.

### Neutral

- **PgBouncer instead of PgCat.** CNPG ships PgBouncer; some newer projects (PgCat from Discord, supabase/supavisor) offer better protocol-level features. PgBouncer is more battle-tested. Not a real downside; would re-evaluate if PgCat reaches similar production maturity.
- **CRD versioning lockstep with the operator.** Major CNPG upgrades require coordinated CRD updates. Standard operator pattern, not a CNPG-specific concern.
- **Cluster API surface is large.** The `Cluster` CR has dozens of fields. We use a subset for Atlas; production deployments at scale use more. Documentation is good but the field count is the cost of doing real database operations declaratively.

## References

- CloudNativePG project: https://cloudnative-pg.io/
- CNCF Sandbox status: https://www.cncf.io/projects/cloudnative-pg/
- Crunchy PGO: https://github.com/CrunchyData/postgres-operator
- Zalando postgres-operator: https://github.com/zalando/postgres-operator
- ADR template (Nygard format): https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions
- Related Atlas docs:
  - [INC-001: Finalizer deadlock](../incidents/001-applicationset-finalizer-deadlock.md)
  - [Helm-in-Kustomize namespace bug](../learning/week-3-database/helm-in-kustomize-namespace.md)
