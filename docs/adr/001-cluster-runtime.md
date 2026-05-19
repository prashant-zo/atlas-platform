# ADR-001: Use kind for Local Cluster Runtime

**Status:** Accepted
**Date:** 2026-05-19
**Deciders:** Prashant

## Context

Atlas is a learning-grade platform engineering project intended for portfolio demonstration to senior DevOps / SRE / Platform Engineering interviewers. The build must satisfy three constraints simultaneously:

1. **Production fidelity** — workloads written for the local cluster should run unchanged on AWS EKS. This means real Kubernetes, real multi-node topology, real CNI behavior.
2. **Hardware budget** — single developer machine, MacBook Air M1 (8 GB RAM allocated to Docker via Colima). No always-on cloud cluster.
3. **Cost budget** — $80 total project budget. Cannot afford a long-running managed cluster ($73/month for the EKS control plane alone, before nodes/networking).

The cluster runtime decision determines the inner development loop speed and the credibility of every downstream component (ArgoCD, CloudNativePG, observability stack, Argo Rollouts).

## Decision

We will use **kind (Kubernetes IN Docker)** as the local cluster runtime for all development and the majority of validation work. A 3-node topology (1 control plane + 2 workers labeled with `topology.kubernetes.io/zone`) is provisioned via a versioned config file. Real cloud deployment to AWS EKS in ap-south-1 is reserved for a single validation weekend in last day (finale) to capture evidence (screenshots, walkthrough video), then immediately torn down to control cost.

## Alternatives Considered

### Option A: minikube
- **Pros:** Mature, broad documentation, supports many drivers, native multi-node support.
- **Cons:** Slower startup (~2 min vs ~60 sec for kind), heavier per-node footprint, multi-node story added relatively late in its lifecycle, less commonly the runtime real production CI clusters use.
- **Rejected because:** kind boots faster on M1, has a tighter footprint matching our 8 GB RAM allocation, and is the reference runtime in upstream Kubernetes SIG testing — closer to production behavior.

### Option B: k3d (k3s in Docker)
- **Pros:** Extremely fast startup, very light footprint, built-in load balancer for ingress.
- **Cons:** Runs k3s, not upstream Kubernetes. K3s strips/replaces several components (containerd config layout differs, runs sqlite by default instead of etcd, has different default storage drivers).
- **Rejected because:** Production fidelity is a hard requirement. K3s behavioral differences would introduce "works locally, fails on EKS" surprises in the platform components we're about to install (ArgoCD, CloudNativePG operator, kube-prometheus-stack — all tested primarily on upstream Kubernetes).

### Option C: Docker Desktop's built-in Kubernetes
- **Pros:** Zero setup if Docker Desktop is already installed, single-click enable.
- **Cons:** Single-node only, no node-zone labeling, no easy way to simulate multi-zone topology, Docker Desktop is paid for commercial use.
- **Rejected because:** Single-node hides scheduling behaviors we explicitly want to exercise (topology spread constraints, DaemonSet behavior, StatefulSet pod placement across zones). Also: the user runs Colima specifically to avoid Docker Desktop.

### Option D: Always-on AWS EKS
- **Pros:** Maximum production fidelity, real cloud networking, real IAM/IRSA integration, real EBS storage class.
- **Cons:** ~$110–190/month minimum (control plane + node group + NAT gateway + LB). Far outside the $80 total project budget. A single billing mistake (e.g., forgetting to destroy a NAT gateway over a weekend) could exhaust the budget in days.
- **Rejected because:** Budget. However, we accept that local-only is a credibility gap and mitigate it by deploying the *same* Atlas stack to real EKS for a 48-hour validation weekend (Week 6), capturing evidence, and tearing it down — getting 5% of the credibility for 5% of the cost.

## Consequences

### Positive
- Cluster comes up in ~60 seconds — supports tight iteration loops.
- 3-node topology with zone labels lets us exercise real scheduling primitives (`topologySpreadConstraints`, DaemonSets, StatefulSet pod-per-zone placement).
- Upstream Kubernetes — manifests written here transfer to EKS without rewrites.
- Cost: zero. Eliminates the largest financial risk to project completion.
- Multi-platform contributors can use the same bootstrap (Linux developers and other M1/M2 Macs).

### Negative
- Persistent volumes use kind's local-path provisioner, not EBS — storage class names and provisioner annotations will need swapping for EKS deployment. We will manage this via Kustomize overlays in coming days.
- No real cloud load balancer integration locally — we proxy through host port mappings (80, 443) instead. Service `type: LoadBalancer` won't allocate an external IP locally without MetalLB; we sidestep this entirely by exposing through nginx-ingress.
- No real IAM integration locally — we cannot exercise IRSA (IAM Roles for Service Accounts) until the EKS validation weekend.
- No multi-cluster scenarios — Atlas is explicitly single-cluster scope.

### Neutral
- Container runtime is containerd inside the kind node containers (matches modern EKS, which also uses containerd since 1.24). Behavior is consistent.
- Inner-loop image push uses a local registry container (`localhost:5001`); on EKS we will push to ECR. The Kustomize overlays will handle this image reference swap.

## References

- kind project: https://kind.sigs.k8s.io/
- Michael Nygard's ADR format: https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions
- Kubernetes SIG testing reference uses kind: https://github.com/kubernetes-sigs/kind/blob/main/README.md
- EKS pricing (ap-south-1): https://aws.amazon.com/eks/pricing/
- kind multi-node configuration: https://kind.sigs.k8s.io/docs/user/configuration/
