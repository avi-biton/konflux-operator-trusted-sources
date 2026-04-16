# Konflux Operator Trusted Sources

This repository stores a generated `data/trusted-sources.yaml` file for Conforma/Enterprise Contract policy data.

The goal is to keep trusted task heads aligned with task bundle digests currently referenced by onboarding pipelines.

## Generator script

Use `scripts/generate-trusted-sources.sh` to build `data/trusted-sources.yaml` from:

- a list of pipeline bundle references
- a source `data-acceptable-bundles` OCI artifact

The script:

1. extracts all `resolver: bundles` task refs from provided pipeline bundles
2. validates each referenced digest exists in `trusted_tasks`
3. promotes referenced digests to head entries (index `0`) with no `expires_on`
4. writes the resulting YAML file

## Prerequisites

- `bash`
- `skopeo`
- `yq`
- network access to pull pipeline and data bundle images
- registry auth if required by the source images

## Usage

```bash
./scripts/generate-trusted-sources.sh \
  --pipelines-file /path/to/build-pipeline-config.yaml \
  --data-bundles-ref oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest \
  --output ./data/trusted-sources.yaml
```

## Align onboarding bundles + regenerate (recommended)

Use this when you want **one coherent snapshot**: every onboarding pipeline bundle tag equals the same `build-definitions` git revision (the tag pushed to `quay.io/konflux-ci/tekton-catalog/pipeline-*` by CI).

1. Pick **`BUILD_DEFINITIONS_REV`** (full SHA from [build-definitions](https://github.com/konflux-ci/build-definitions) `main`, or another revision you know was published to Quay).

2. From this repository:

```bash
chmod +x ./scripts/align-onboarding-trusted-sources.sh ./scripts/generate-trusted-sources.sh   # once
export BUILD_DEFINITIONS_REV=<git-sha>
export KONFLUX_CI_ROOT=/path/to/konflux-ci   # optional; runs the operator head test after generate
./scripts/align-onboarding-trusted-sources.sh
```

The script writes **`onboarding-pipeline-bundles.generated.yaml`** (gitignored), runs **`scripts/generate-trusted-sources.sh`**, and updates **`data/trusted-sources.yaml`** (override with **`TRUSTED_OUTPUT`**). With **`KONFLUX_CI_ROOT`**, it runs **`TestOnboardingPipelineTaskBundlesMatchTrustedTasksCatalogHead`** in `konflux-ci/operator`.

3. Update **`konflux-ci`** embedded `build-pipeline-config` bundle digests to match the same revision (copy bundle lines from the generated YAML or from Quay), publish **`data/trusted-sources.yaml`**, and point Enterprise Contract policy at that Git ref.

4. **`SKIP_GENERATE=1`** — only refresh the generated pipelines file (no `data/trusted-sources.yaml` update).

See **`onboarding-pipeline-bundles.example.yaml`** for the YAML shape without running the script.

## Example for konflux-ci operator

```bash
./scripts/generate-trusted-sources.sh \
  --pipelines-file ../konflux-ci/operator/upstream-kustomizations/build-service/core/build-pipeline-config.yaml \
  --data-bundles-ref oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest \
  --output ./data/trusted-sources.yaml
```

## Input formats for `--pipelines-file`

The script accepts any of:

- build-pipeline-config ConfigMap (`data.config.yaml`)
- YAML with `.pipelines[].bundle`
- YAML sequence of bundle refs
- plain text file (one bundle ref per line, `#` comments allowed)

## Conflict behavior

If different pipelines reference different digests for the same `oci://...:tag` key:

- the script verifies all referenced digests exist in `trusted_tasks`
- then chooses the newest known trusted one (lowest existing index in the source list)
- logs the candidates and selected digest

This allows generation to complete while preserving validation guarantees.

