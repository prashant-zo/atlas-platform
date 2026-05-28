# Colima Restart Breaks Network Plane (kube-proxy/DNS)

**Date:** 2026-05-28
**Symptom:** After `colima restart`, entire cluster appears broken —
ArgoCD, monitoring, workloads all CrashLoopBackOff. Pod restarts,
rollout restarts, and app syncs all fail to fix it.

## Root Cause

Colima VM restart left kube-proxy in CrashLoopBackOff. With kube-proxy
down, Service ClusterIPs don't route, so in-cluster DNS
(CoreDNS via kube-dns Service) becomes unreachable. Every pod that
resolves a Service name fails with:

    dial tcp: lookup <service>: i/o timeout

This cascades: argocd-server can't reach argocd-redis, pg pods can't
reach each other, etc. The whole cluster looks broken, but the actual
fault is a single layer: networking.

## Why Pod-Level Fixes Failed

Deleting/restarting application pods addresses layer 3 (workloads). The
break was layer 2 (cluster networking). Restarted pods crash again
immediately because the network underneath is still broken. You cannot
restart your way out of a kube-proxy failure at the app layer.

## Fix

Restart the network plane, bottom-up:

\`\`\`bash
kubectl rollout restart daemonset kube-proxy -n kube-system
kubectl rollout restart deployment coredns -n kube-system

# Verify DNS works
kubectl run dns-test --image=busybox:1.28 --rm -it --restart=Never -- \
  nslookup kubernetes.default
\`\`\`

Once DNS resolves, application pods recover on their own within a few
minutes. If kube-proxy won't recover via rollout restart, reboot the
kind node containers (gentler than kind delete):

\`\`\`bash
docker restart atlas-control-plane atlas-worker atlas-worker2
\`\`\`

## Diagnostic Lesson — Check Bottom-Up

When "everything is broken," diagnose in layer order:
1. Nodes Ready? (`kubectl get nodes`)
2. Network plane? (`kube-proxy`, `coredns` Running; DNS resolves)  ← check this
3. Application pods

The signature `dial tcp: lookup <svc>: i/o timeout` points straight to
layer 2. When you see it, go to kube-proxy + CoreDNS first, not the app.

## Interview Talking Point

> "After a VM restart, my whole cluster looked broken — every component
> CrashLooping. Pod restarts didn't help. The signature was
> 'dial tcp: lookup service: i/o timeout' across many pods, which is a
> DNS/networking failure, not an application failure. kube-proxy had
> come back broken, so Service routing was dead, so DNS was unreachable.
> I restarted kube-proxy and CoreDNS, verified DNS resolution, and
> everything above recovered automatically. The lesson: diagnose
> bottom-up — nodes, then network plane, then workloads. Restarting app
> pods can never fix a layer-2 networking break."
