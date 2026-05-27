# Colima inotify Limits Break Promtail (and Loki Stack)

**Date:** 2026-05-26
**Component:** Promtail DaemonSet on kind via Colima
**Severity:** 2 of 3 Promtail pods CrashLoopBackOff

## Symptom

\`\`\`
kubectl logs loki-promtail-b6jsz -n monitoring
level=error msg="error creating promtail" 
  error="failed to make file target manager: too many open files"
\`\`\`

One Promtail per node tries to watch every container's log file in
`/var/log/containers/`. With ~30+ containers across all namespaces,
Promtail hits the Linux inotify limit on the underlying VM.

## Root Cause

Linux uses inotify (file-system event watching) for tailing log files.
Two kernel-level limits:
- `fs.inotify.max_user_instances` — number of inotify instances per user
- `fs.inotify.max_user_watches` — number of files watched per user

Colima's underlying VM ships with low defaults (128 instances, 8192
watches typical). Promtail consumes one instance + many watches; on
nodes with many pods, the watches get exhausted, and Promtail crashes.

## Why This Doesn't Happen On EKS

Production Kubernetes nodes (EC2, etc.) come with much higher defaults
(often 1024+ instances, 65536+ watches). Cloud-managed nodes also
typically run fewer total pods per node than dev workstations cram
into kind clusters.

## Fix

Raise both limits on the Colima VM:

\`\`\`bash
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=512
colima ssh -- sudo sysctl -w fs.inotify.max_user_watches=524288
\`\`\`

Persist across VM restart:

\`\`\`bash
colima ssh -- 'echo "fs.inotify.max_user_instances=512" | sudo tee -a /etc/sysctl.d/99-promtail.conf'
colima ssh -- 'echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.d/99-promtail.conf'
\`\`\`

Restart failing Promtail pods to pick up the change:

\`\`\`bash
kubectl delete pod -n monitoring -l app.kubernetes.io/name=promtail \
  --field-selector status.phase=Failed
\`\`\`

## Interview Talking Point

> "When I installed Promtail on my local kind cluster, two of three
> DaemonSet pods crashed with 'too many open files.' The cause was the
> underlying VM's default inotify limits — Linux uses inotify for log
> file watching, and Colima's defaults are too low for a cluster
> running many pods. I raised the limits on the Colima VM. The
> general lesson: file-watching tools have OS-level resource limits
> that aren't visible at the application layer. In production this
> rarely surfaces because cloud-managed nodes ship with higher limits.
> In dev environments, you tune them explicitly."

## Future Mitigation

A Promtail configuration option could limit how many files it tries
to watch (`positions.sync_period`, batching, etc.) but doing this
in Helm values is fragile. The right durable fix is the OS-level
sysctl on dev environments — accepting the cluster needs tuning,
not the application.
