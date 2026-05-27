# CNPG Backup Ownership: Test Your Assumptions

**Date:** 2026-05-25
**Component:** ScheduledBackup CR
**Severity:** Hygiene — backups worked, but ownership chain was broken

## What I Assumed

I wrote a ScheduledBackup manifest including `backupOwnerReference: self`,
committed it, and trusted that the spec on the cluster matched what I'd
written in Git.

## What Was True

The `backupOwnerReference: self` line was missing from the committed file —
it got dropped during a paste into nvim. The spec on the cluster showed
`backupOwnerReference: none` (the default).

## How I Caught It

Verifying that the first generated Backup had `ownerReferences`. The
expected ownership link to the ScheduledBackup was absent:

\`\`\`bash
kubectl get backup -n three-tier-dev -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.ownerReferences[*].kind}{"\n"}{end}'
pg-daily-20260525150819
pg-daily-20260525150834
# Empty ownership column — both Backups orphaned
\`\`\`

Then comparing what was in Git:

\`\`\`bash
grep "backupOwnerReference" gitops/.../scheduled-backup.yaml
# Empty — the field wasn't in the file
\`\`\`

The fix was to add the missing line.

## Why This Matters

Without ownerReferences:
- Deleting the ScheduledBackup leaves the Backup CRs orphaned in the cluster
- The "deletion cascades to backup history" property doesn't hold
- GitOps disaster recovery model breaks: re-applying the ScheduledBackup
  doesn't reclaim ownership of existing Backups

Functionally, the backups still work — they're real, restorable, in S3.
The issue is lifecycle management, not data integrity.

## Deeper Lesson

**GitOps does not guarantee that what you think you wrote is what's running.**
Three places can break the chain:
1. Editor lost a line during a save
2. Helm/Kustomize template transformed a value
3. A defaulting webhook overwrote the field on apply

For any field where the *behavior* matters (not just the spec value),
verify it in the live resource:

\`\`\`bash
kubectl get <resource> <name> -o jsonpath='{.spec.<field>}'
\`\`\`

Don't trust git, trust what's running.

## Interview Talking Point

> "While building scheduled backups on CNPG, I noticed the Backup CRs
> weren't getting owner references back to the ScheduledBackup, so
> deletion wasn't cascading properly. I checked the live spec on the
> cluster and saw `backupOwnerReference: none` even though I'd written
> `self` in Git. The line had been dropped during an editor paste.
>
> The general lesson: in GitOps, never assume Git matches the live state.
> Editors lose lines, templates rewrite values, webhooks default fields.
> For any field whose behavior matters, verify in the live resource with
> `kubectl get -o jsonpath`. This is the same discipline as `terraform
> plan` showing you what's actually going to change — read the diff
> against reality, not the diff against your last commit."
