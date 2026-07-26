---
name: maintain-trust-model
description: >-
  Maintain Conforma policy data for the Konflux operator's default
  EnterpriseContractPolicy. Use when updating trusted task rules, adding/removing
  allow/deny patterns, changing required tasks, updating rule data, or when the
  user mentions ADR 0053, trusted_task_rules, EnterpriseContractPolicy data, or
  Conforma policy data.
---

# Maintain Konflux trusted sources (ADR 0053 trust model)

## Goal

Keep the Conforma policy data in `data/` aligned with the Konflux operator's
default pipeline (`docker-build-oci-ta-min`) and the ADR 0053 rule-based trust
model.

## Data files

| Path | Purpose |
|------|---------|
| `data/trusted_task_rules.yaml` | Allow/deny patterns with version constraints. Sets `trusted_task_rules_enabled: true`. |
| `data/trusted_task_rules_deprecated.yaml` | Allow/deny rules for deprecated task locations during migration. |
| `data/rule_data.yml` | Allowed registries, required labels, informative tests, RPM signature keys. |
| `data/required_tasks.yml` | Required tasks for the `docker` pipeline type, including `-min` variants. |

## Updating trusted task rules

When a new task is added to the Konflux tekton-catalog or a task version needs
to be denied:

1. **Allow a new task source** — add a pattern to `allow.konflux-defaults` in
   `trusted_task_rules.yaml`:

   ```yaml
   allow:
     konflux-defaults:
       - pattern: oci://quay.io/konflux-ci/tekton-catalog/task-*
       - pattern: oci://quay.io/konflux-ci/new-catalog/*  # new
   ```

2. **Deny old task versions** — add a deny entry with version constraint and
   effective date:

   ```yaml
   deny:
     konflux-defaults:
       - pattern: oci://quay.io/konflux-ci/tekton-catalog/task-my-task
         versions: ['<0.3']
         effective_on: "2026-12-01T00:00:00Z"
   ```

3. **Deprecated task locations** — if a task registry is being sunsetted, add
   transitional allow/deny rules in `trusted_task_rules_deprecated.yaml`.

## Updating required tasks

When the `docker-build-oci-ta-min` pipeline changes (tasks added/removed):

1. Check current pipeline tasks:

   ```bash
   BUNDLE=$(yq eval-all 'select(.kind == "ConfigMap" and .metadata.name == "build-pipeline-config") | .data["config.yaml"]' \
     /path/to/konflux-ci/operator/pkg/manifests/build-service/manifests.yaml \
     | yq eval '.pipelines[] | select(.name == "docker-build-oci-ta-min") | .bundle' -)
   tkn bundle list "$BUNDLE" -o json | python3 -c "
   import json, sys
   data = json.load(sys.stdin)
   for t in data.get('spec',{}).get('tasks',[]) + data.get('spec',{}).get('finally',[]):
       ref = t.get('taskRef',{}).get('params',[])
       name = next((p['value'] for p in ref if p.get('name')=='name'), t.get('name','?'))
       print(name)
   "
   ```

2. Update `data/required_tasks.yml` to match — include `-min` variants as
   alternatives (e.g. `[buildah-oci-ta, buildah-oci-ta-min]`).

3. Ensure the e2e exclusion list in
   `konflux-ci/test/go-tests/tests/conformance/setup.go` (`e2eECPExclusions`)
   covers any required tasks not present in the min pipeline.

## Updating rule data

Edit `data/rule_data.yml` when changing:
- Allowed base image registries (`allowed_registry_prefixes`)
- Required OCI labels (`required_labels`)
- Informative test list (`informative_tests`)
- RPM signature keys (`allowed_rpm_signature_keys`)

## CI validation

A GitHub Actions workflow (`.github/workflows/validate-data.yaml`) runs the
Conforma CLI with the `@policy_data` rule collection against the `data/`
directory. This validates the format of all known rule data keys. The policy
config is in `ci-policy.yaml`.

Run locally:

```bash
echo '{}' > /tmp/empty-input.json
ec validate input /tmp/empty-input.json --policy ci-policy.yaml --show-successes --info --output yaml
```

## Publishing changes

1. Commit and push to the branch referenced by the operator's
   `EnterpriseContractPolicy` data source.

2. If using a branch ref (e.g. `?ref=new-trust-model`), changes take effect
   immediately. If using a commit SHA, update the ref in:

   ```
   konflux-ci/operator/upstream-kustomizations/enterprise-contract/policies/
     enterprise-contract-service_appstudio.redhat.com_v1alpha1_enterprisecontractpolicy_default.yaml
   ```

3. Rebuild the operator's embedded manifests:

   ```bash
   cd /path/to/konflux-ci
   bash operator/pkg/manifests/rebuild-upstream-manifests.sh .
   ```
