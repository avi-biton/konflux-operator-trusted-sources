# Konflux Operator Trusted Sources

This repository stores Conforma (Enterprise Contract) policy data used by the
[Konflux operator](https://github.com/konflux-ci/konflux-ci)'s default
`EnterpriseContractPolicy`. The operator references this data via a git ref in
its policy manifest.

## Data files

The `data/` directory contains rule data consumed by Conforma during policy
evaluation.

| File | Purpose |
|------|---------|
| `trusted_task_rules.yaml` | [ADR 0053](https://github.com/konflux-ci/architecture/blob/main/ADR/0053-trusted-task-model.md) rule-based trust model — allow/deny patterns and version constraints for Tekton tasks. Sets `trusted_task_rules_enabled: true`. |
| `trusted_task_rules_deprecated.yaml` | Allow/deny rules for deprecated task locations (`integration-service-catalog`, `konflux-vanguard`) during migration to `tekton-catalog`. |
| `rule_data.yml` | General rule configuration — allowed registries, required labels, informative tests, RPM signature keys. |
| `required_tasks.yml` | Required tasks for the `docker-build-oci-ta-min` pipeline, including `-min` task variants. |
| `trusted-sources.yaml` | Legacy digest-based trusted task list (see [Legacy scripts](#legacy-scripts-reference-only) below). |

### Trust model

The new trust model (ADR 0053) replaces the old digest-based "acceptable
bundles" approach. Instead of matching exact image digests, task trust is
determined by OCI registry patterns and version constraints defined in
`trusted_task_rules.yaml`. The `trusted_task_rules_enabled: true` flag
activates this model.

Tasks from `quay.io/konflux-ci/tekton-catalog/` and
`quay.io/konflux-ci/integration-service-catalog/` are trusted by default.
Version-based deny rules in the same file enforce minimum task versions and
expire old ones on scheduled dates.

### How the operator uses this data

The operator's default `EnterpriseContractPolicy` references this repository
as a git data source:

```yaml
sources:
- data:
  - github.com/konflux-ci/konflux-operator-trusted-sources//data?ref=<sha-or-branch>
  config:
    include:
    - '@redhat'
```

Conforma loads all YAML files from the `data/` directory and merges them into
the policy evaluation context.

### CI validation

A GitHub Actions workflow validates rule data format on every push and PR using
the Conforma CLI with the `@policy_data` rule collection. See `ci-policy.yaml`
for the policy configuration.

---

## Legacy scripts (reference only)

> The scripts and `data/trusted-sources.yaml` below predate the ADR 0053
> rule-based trust model. They are kept for reference but are superseded by
> `trusted_task_rules.yaml` and related data files described above.

### Generator script

Use `scripts/generate-trusted-sources.sh` to build `data/trusted-sources.yaml` from:

- a list of pipeline bundle references
- a source `data-acceptable-bundles` OCI artifact

The script:

1. extracts all `resolver: bundles` task refs from provided pipeline bundles
2. validates each referenced digest exists in `trusted_tasks`
3. promotes referenced digests to head entries (index `0`) with no `expires_on`
4. writes the resulting YAML file

### Prerequisites

- `bash`
- `skopeo`
- `yq`
- network access to pull pipeline and data bundle images
- registry auth if required by the source images

### Usage

```bash
./scripts/generate-trusted-sources.sh \
  --pipelines-file /path/to/build-pipeline-config.yaml \
  --data-bundles-ref oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest \
  --output ./data/trusted-sources.yaml
```

### Align onboarding bundles + regenerate (recommended)

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

### Example for konflux-ci operator

```bash
./scripts/generate-trusted-sources.sh \
  --pipelines-file ../konflux-ci/operator/upstream-kustomizations/build-service/core/build-pipeline-config.yaml \
  --data-bundles-ref oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest \
  --output ./data/trusted-sources.yaml
```

### Input formats for `--pipelines-file`

The script accepts any of:

- build-pipeline-config ConfigMap (`data.config.yaml`)
- YAML with `.pipelines[].bundle`
- YAML sequence of bundle refs
- plain text file (one bundle ref per line, `#` comments allowed)

### Conflict behavior

If different pipelines reference different digests for the same `oci://...:tag` key:

- the script verifies all referenced digests exist in `trusted_tasks`
- then chooses the newest known trusted one (lowest existing index in the source list)
- logs the candidates and selected digest

This allows generation to complete while preserving validation guarantees.
