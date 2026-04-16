# Konflux Operator Trusted Sources

This repository stores a generated `trusted-sources.yaml` file for Conforma/Enterprise Contract policy data.

The goal is to keep trusted task heads aligned with task bundle digests currently referenced by onboarding pipelines.

## Generator script

Use `generate-trusted-sources.sh` to build `trusted-sources.yaml` from:

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
./generate-trusted-sources.sh \
  --pipelines-file /path/to/build-pipeline-config.yaml \
  --data-bundles-ref oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest \
  --output ./trusted-sources.yaml
```

## Example for konflux-ci operator

```bash
./generate-trusted-sources.sh \
  --pipelines-file ../konflux-ci/operator/upstream-kustomizations/build-service/core/build-pipeline-config.yaml \
  --data-bundles-ref oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest \
  --output ./trusted-sources.yaml
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

