# Release Process: atlas-backend

The atlas-backend image is built and published to GHCR by the GitHub Actions workflow `.github/workflows/build-backend.yml`. Three release flows are supported.

---

## Continuous Builds (Every Commit To main)

Any commit to `main` that touches `apps/backend/**` or `.github/workflows/build-backend.yml` triggers a build. Tags pushed:

- `:main` — branch pointer (mutable; updated on every push)
- `:<short-sha>` — immutable, e.g. `:5482bf2` (this is the only tag manifests should reference)
- `:latest` — only updated on default branch (mutable)

**Use the SHA tag in production manifests.** Branch pointers and `:latest` are mutable and unsafe for rollback determinism.

---

## Semver Releases (Git Tag Driven)

To publish a versioned release:

```bash
# 1. Tag the commit
git tag v3.0.0
git push origin v3.0.0
```

This triggers the workflow with semver tag extraction. Tags pushed:

- `:3.0.0` — full version
- `:3.0` — minor pointer (advances with patch releases)
- `:3` — major pointer (advances with minor releases)
- `:<short-sha>` — still pushed for traceability

**Use semver tags in user-facing changelogs and READMEs.** Use SHA tags in deployment manifests.

---

## Manual Builds

To rebuild without pushing a commit:

1. Visit https://github.com/prashant-zo/atlas-platform/actions
2. Click the `build-backend` workflow
3. Click `Run workflow` → choose branch → `Run workflow`

Useful for emergency rebuilds when an upstream dependency (e.g. base image) needs a refresh.

---

## Promoting An Image To An Environment

Each environment overlay pins to a specific SHA tag.

```yaml
# gitops/workloads/three-tier-app/overlays/dev/kustomization.yaml
images:
  - name: ghcr.io/prashant-zo/atlas-backend
    newTag: "5482bf2"   # short SHA from a successful CI run
```

To promote a new image:

1. Verify the image exists: `docker manifest inspect ghcr.io/prashant-zo/atlas-backend:<sha>`
2. Update the relevant overlay's `newTag` value
3. Commit + push
4. ArgoCD syncs the change → Rollout triggers a canary deployment
5. Watch: `kubectl argo rollouts get rollout backend -n three-tier-<env> --watch`

For prod, never use `:main` or `:latest`. Always pin to a specific SHA or semver tag.

---

## Anti-Patterns To Avoid

- ❌ Referencing `:latest` from a Rollout/Deployment manifest — non-deterministic
- ❌ Referencing `:main` from a Rollout/Deployment manifest — same problem
- ❌ Hardcoding mutable tags (`:v1`, `:v2`) in the workflow — overwritten on next push
- ❌ Using the package's GitHub HTML page to verify a tag exists — cached, can show stale data. Use `docker manifest inspect` or the registry API instead.
- ❌ Skipping the SHA tag for a "human-friendly" tag — loses traceability and breaks deterministic rollbacks
