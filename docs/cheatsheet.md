# Atlas — Personal Cheatsheet

## kubectl

# List things
kubectl get pods -n <ns>
kubectl get pods -n <ns> -l <label-selector>           # filter by label
kubectl get pods -n <ns> -o wide                       # show node + IP
kubectl get pods -A | grep <name>                      # search all namespaces
kubectl get all -n <ns>                                # everything in namespace

# Describe (when something is broken)
kubectl describe pod <name> -n <ns>
kubectl describe cluster <name> -n <ns>                # CNPG CRD

# Logs (when describe doesn't show enough)
kubectl logs <pod> -n <ns> --tail=50
kubectl logs <pod> -n <ns> --previous                  # crashed pod's last logs
kubectl logs <pod> -n <ns> --all-containers            # multi-container pod
kubectl logs -l <label> -n <ns>                        # all pods matching label

# Exec into running pods
kubectl exec -it <pod> -n <ns> -- bash                 # or sh if no bash
kubectl exec <pod> -n <ns> -c <container> -- <command>

# Delete things
kubectl delete pod <name> -n <ns>
kubectl delete pod <name> -n <ns> --grace-period=0 --force  # hard kill
kubectl rollout restart deployment <name> -n <ns>      # gentler than delete

# Find an IP/value from a resource
kubectl get cluster pg -n three-tier-dev -o jsonpath='{.status.currentPrimary}'

## argocd

argocd app list
argocd app get <name>                                  # detailed status
argocd app sync <name>                                 # force a sync
argocd app sync <name> --prune                         # also remove orphans
argocd app refresh <name>                              # re-read Git
argocd app diff <name>                                 # what differs from cluster
argocd app terminate-op <name>                         # clear stuck sync

## kubectl-argo-rollouts

# Status & watching
kubectl argo rollouts get rollout <name> -n <ns>                # full status with tree
kubectl argo rollouts get rollout <name> -n <ns> --watch        # live updates
kubectl argo rollouts list rollouts -n <ns>                     # all rollouts in ns

# Driving a canary
kubectl argo rollouts promote <name> -n <ns>           # advance past current pause
kubectl argo rollouts promote <name> -n <ns> --full    # skip all remaining steps
kubectl argo rollouts abort <name> -n <ns>             # cancel in-flight, scale canary RS to 0
kubectl argo rollouts retry rollout <name> -n <ns>     # restart a Degraded rollout
kubectl argo rollouts pause <name> -n <ns>             # manually pause a Progressing rollout

# Inspect analysis
kubectl get analysisrun -n <ns>                        # list all analysis runs
kubectl describe analysisrun <name> -n <ns>            # see actual Prometheus values

# Most recent AnalysisRun (when you don't know its name yet)
kubectl get analysisrun -n <ns> --sort-by=.metadata.creationTimestamp -o name | tail -1

# Restart workflow (when CRD changes don't propagate)
kubectl rollout restart deployment argo-rollouts -n argo-rollouts

## load testing (k6)

# Run the canonical canary load test (in-cluster Job, ~6 min, ~100 RPS sustained)
./load-tests/k6/run.sh

# Watch the job logs while it runs
kubectl logs -n three-tier-dev -l app=k6-load-test -f

# Check live RPS during a run (port-forward Prometheus first)
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=sum(rate(http_requests_total{job=~"backend-svc.*"}[1m]))/2'
pkill -f "port-forward.*prometheus"

## Misc Atlas-specific

# After git revert of a bad release, force a sync (Argo Rollouts skips canary on known-good RS)
git revert HEAD --no-edit && git push && argocd app sync three-tier-dev

# What version is currently stable? (image tag may lag — check actual pod env)
kubectl exec deploy/<pod-template> -n three-tier-dev -- env | grep VERSION

# Build & push a new backend image (apple silicon, kind cluster)
cd apps/backend
docker buildx build --platform linux/arm64 -t localhost:5001/atlas-backend:<tag> --load .
docker push localhost:5001/atlas-backend:<tag>

# Get postgres credentials
kubectl get secret pg-app -n three-tier-dev -o jsonpath='{.data.password}' | base64 -d

# Find current primary
kubectl get cluster pg -n three-tier-dev -o jsonpath='{.status.currentPrimary}'

# Trigger a controlled failover
kubectl delete pod <current-primary> -n three-tier-dev --grace-period=0 --force

# Force ArgoCD to re-read Git (use when you've pushed a fix)
kubectl rollout restart deployment argocd-repo-server -n argocd

# After a Colima stop/start, restart kube-proxy + CoreDNS (fixes in-cluster DNS timeouts)
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout restart daemonset kube-proxy -n kube-system
