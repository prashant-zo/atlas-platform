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

## Misc Atlas-specific

# Get postgres credentials  
kubectl get secret pg-app -n three-tier-dev -o jsonpath='{.data.password}' | base64 -d

# Find current primary
kubectl get cluster pg -n three-tier-dev -o jsonpath='{.status.currentPrimary}'

# Trigger a controlled failover
kubectl delete pod <current-primary> -n three-tier-dev --grace-period=0 --force

# Force ArgoCD to re-read Git (use when you've pushed a fix)
kubectl rollout restart deployment argocd-repo-server -n argocd
