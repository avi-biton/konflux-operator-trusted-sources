---
name: align-konflux-trusted-sources
description: >-
  Regenerates data/trusted-sources.yaml from aligned Konflux onboarding pipeline bundles and
  verifies against konflux-ci operator tests. Use when updating trusted task heads,
  build-pipeline-config bundle digests, Enterprise Contract trusted_sources Git ref, or
  when the user mentions onboarding pipeline alignment, data-acceptable-bundles, or
  TestOnboardingPipelineTaskBundlesMatchTrustedTasksCatalogHead.
---

# Align Konflux trusted sources (onboarding pipelines)

## Goal

Keep **`trusted_sources`** task heads consistent with **immutable pipeline bundle digests** that all come from the **same `build-definitions` git revision** (Quay tag on `quay.io/konflux-ci/tekton-catalog/pipeline-*`).

## Automated path (preferred)

In **`konflux-operator-trusted-sources`**:

1. Set **`BUILD_DEFINITIONS_REV`** to the full git SHA you want (must exist as an image tag on each `pipeline-*` repository in Quay).

2. Run:

   ```bash
   export BUILD_DEFINITIONS_REV=<sha>
   export KONFLUX_CI_ROOT=/path/to/konflux-ci   # optional: runs head test
   ./scripts/align-onboarding-trusted-sources.sh
   ```

3. This writes **`onboarding-pipeline-bundles.generated.yaml`** (gitignored), updates **`data/trusted-sources.yaml`** (or **`TRUSTED_OUTPUT`**), and optionally runs **`go test`** for **`TestOnboardingPipelineTaskBundlesMatchTrustedTasksCatalogHead`** in **`konflux-ci/operator`**.

4. **`SKIP_GENERATE=1`** — only writes the generated pipelines file; no regeneration or test.

5. Commit and push **`data/trusted-sources.yaml`** on the branch referenced by **`EnterpriseContractPolicy`** (`konflux-ci` embedded manifests).

6. Update **`konflux-ci`** embedded **`build-pipeline-config`** so each **`bundle:`** matches the same digests (from the generated YAML or Quay). Re-run the test after embedding.

## Manual / fallback

- Run **`./scripts/generate-trusted-sources.sh`** with **`--pipelines-file`** (a **`build-pipeline-config`** ConfigMap export or **`onboarding-pipeline-bundles.example.yaml`** shape), **`--data-bundles-ref`** (same acceptable-bundles image the align script uses; see **README.md**), and **`--output ./data/trusted-sources.yaml`** so the catalog overwrites **`data/trusted-sources.yaml`** in the repo.

Example:

```bash
./scripts/generate-trusted-sources.sh \
  --pipelines-file /path/to/build-pipeline-config.yaml \
  --data-bundles-ref oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest \
  --output ./data/trusted-sources.yaml
```

See repository **README.md** for details.

## Files

| Path | Role |
|------|------|
| `scripts/align-onboarding-trusted-sources.sh` | Resolver + generator + optional test |
| `scripts/generate-trusted-sources.sh` | Core promotion logic |
| `data/trusted-sources.yaml` | Generated catalog (committed; overwritten by scripts) |
| `onboarding-pipeline-bundles.example.yaml` | Example pipelines input |
| `onboarding-pipeline-bundles.generated.yaml` | Script output (gitignored) |

## Prerequisites

`bash`, `skopeo`, `yq`, network to Quay; `go` if using **`KONFLUX_CI_ROOT`**.
