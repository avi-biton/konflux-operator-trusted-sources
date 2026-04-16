#!/usr/bin/env bash
set -euo pipefail

WORK_DIR=""

usage() {
  cat <<'EOF'
Generate trusted-sources.yaml from pipeline bundle task refs.

Required:
  --pipelines-file <path>         YAML file describing pipeline bundles.
                                  Supported formats:
                                    1) build-pipeline-config ConfigMap (data.config.yaml)
                                    2) plain YAML with .pipelines[].bundle
                                    3) YAML sequence of bundle refs
                                    4) plain text (one bundle ref per line)
  --data-bundles-ref <image-ref>  OCI image ref for data-acceptable-bundles.
                                  Accepts with or without oci:: prefix.
  --output <path>                 Output trusted-sources.yaml path.

Optional:
  --work-dir <path>               Working directory (default: mktemp dir).
  --help                          Show this message.

Examples:
  ./generate-trusted-sources.sh \
    --pipelines-file /path/to/build-pipeline-config.yaml \
    --data-bundles-ref oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest \
    --output ./trusted-sources.yaml
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"
}

normalize_image_ref() {
  local ref="$1"
  ref="${ref#oci::}"
  # skopeo does not accept refs in name:tag@digest form. Normalize to name@digest.
  if [[ "$ref" == *@sha256:* ]]; then
    local without_digest digest tail
    without_digest="${ref%@*}"
    digest="${ref##*@}"
    tail="${without_digest##*/}"
    if [[ "$tail" == *:* ]]; then
      without_digest="${without_digest%:*}"
    fi
    ref="${without_digest}@${digest}"
  fi
  printf '%s' "$ref"
}

extract_pipeline_bundle_refs() {
  local input_file="$1"
  local output_file="$2"

  : >"$output_file"

  # ConfigMap format: data.config.yaml is YAML text.
  if yq -e '.data["config.yaml"]' "$input_file" >/dev/null 2>&1; then
    yq -r '.data["config.yaml"] | from_yaml | .pipelines[]?.bundle // ""' "$input_file" \
      | awk 'NF { print $0 }' >"$output_file"
  # Direct pipelines list format.
  elif yq -e '.pipelines' "$input_file" >/dev/null 2>&1; then
    yq -r '.pipelines[]?.bundle // ""' "$input_file" \
      | awk 'NF { print $0 }' >"$output_file"
  # YAML sequence.
  elif yq -e 'type == "!!seq"' "$input_file" >/dev/null 2>&1; then
    yq -r '.[]' "$input_file" \
      | awk 'NF { print $0 }' >"$output_file"
  else
    # Plain text: one ref per line, comments allowed.
    awk 'NF && $1 !~ /^#/ { print $1 }' "$input_file" >"$output_file"
  fi

  awk '!seen[$0]++' "$output_file" >"${output_file}.dedup"
  mv "${output_file}.dedup" "$output_file"

  if [[ ! -s "$output_file" ]]; then
    die "no pipeline bundle refs found in: $input_file"
  fi
}

copy_image_to_dir() {
  local image_ref="$1"
  local dest_dir="$2"
  local max_attempts=5
  local attempt
  for attempt in $(seq 1 "$max_attempts"); do
    if skopeo copy "docker://${image_ref}" "dir:${dest_dir}" >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$attempt" -lt "$max_attempts" ]]; then
      log "Retrying pull for ${image_ref} (attempt ${attempt}/${max_attempts})"
      sleep $((attempt * 2))
    fi
  done
  die "failed to pull image after ${max_attempts} attempts: ${image_ref}"
}

extract_bundles_from_pipeline_doc() {
  local doc_file="$1"
  local out_file="$2"

  if ! yq -e '.kind == "Pipeline"' "$doc_file" >/dev/null 2>&1; then
    return 0
  fi

  yq -r '
    .. |
    select(type == "!!map" and .taskRef.resolver == "bundles") |
    .taskRef.params[]? |
    select(.name == "bundle") |
    .value
  ' "$doc_file" \
  | awk 'NF { print $0 }' >>"$out_file"
}

extract_task_bundle_refs_from_pipeline_image() {
  local pipeline_image_ref="$1"
  local image_dir="$2"
  local out_file="$3"
  local blob tmp_doc

  copy_image_to_dir "$pipeline_image_ref" "$image_dir"

  for blob in "$image_dir"/*; do
    [[ -f "$blob" ]] || continue
    case "$(basename "$blob")" in
      manifest.json|version) continue ;;
    esac

    # Case 1: blob itself is a Pipeline document (JSON/YAML).
    extract_bundles_from_pipeline_doc "$blob" "$out_file"

    # Case 2: blob is gzip-compressed tar containing the Pipeline document.
    if gzip -t "$blob" >/dev/null 2>&1; then
      while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        tmp_doc="$(mktemp)"
        if gzip -dc "$blob" | tar -xOf - "$entry" >"$tmp_doc" 2>/dev/null; then
          extract_bundles_from_pipeline_doc "$tmp_doc" "$out_file"
        fi
        rm -f "$tmp_doc"
      done < <(gzip -dc "$blob" | tar -tf - 2>/dev/null || true)
    fi
  done
}

extract_trusted_yaml_from_data_image() {
  local data_image_ref="$1"
  local image_dir="$2"
  local output_yaml="$3"
  local blob tmp_doc

  copy_image_to_dir "$data_image_ref" "$image_dir"

  for blob in "$image_dir"/*; do
    [[ -f "$blob" ]] || continue
    case "$(basename "$blob")" in
      manifest.json|version) continue ;;
    esac

    # Case 1: blob itself is trusted_tasks YAML.
    if yq -e '.trusted_tasks | type == "!!map"' "$blob" >/dev/null 2>&1; then
      cp "$blob" "$output_yaml"
      return 0
    fi

    # Case 2: blob is gzip tar containing trusted_tasks YAML.
    if gzip -t "$blob" >/dev/null 2>&1; then
      while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        tmp_doc="$(mktemp)"
        if gzip -dc "$blob" | tar -xOf - "$entry" >"$tmp_doc" 2>/dev/null; then
          if yq -e '.trusted_tasks | type == "!!map"' "$tmp_doc" >/dev/null 2>&1; then
            cp "$tmp_doc" "$output_yaml"
            rm -f "$tmp_doc"
            return 0
          fi
        fi
        rm -f "$tmp_doc"
      done < <(gzip -dc "$blob" | tar -tf - 2>/dev/null || true)
    fi
  done

  return 1
}

main() {
  require_bin skopeo
  require_bin yq
  require_bin awk
  require_bin sort

  local pipelines_file=""
  local data_bundles_ref=""
  local output_file=""
  local work_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pipelines-file)
        pipelines_file="${2:-}"
        shift 2
        ;;
      --data-bundles-ref)
        data_bundles_ref="${2:-}"
        shift 2
        ;;
      --output)
        output_file="${2:-}"
        shift 2
        ;;
      --work-dir)
        work_dir="${2:-}"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$pipelines_file" ]] || die "--pipelines-file is required"
  [[ -n "$data_bundles_ref" ]] || die "--data-bundles-ref is required"
  [[ -n "$output_file" ]] || die "--output is required"
  [[ -f "$pipelines_file" ]] || die "pipelines file not found: $pipelines_file"

  if [[ -z "$work_dir" ]]; then
    work_dir="$(mktemp -d)"
    WORK_DIR="$work_dir"
    trap 'rm -rf "${WORK_DIR:-}"' EXIT
  else
    mkdir -p "$work_dir"
  fi

  local pipeline_refs_file="${work_dir}/pipeline-bundles.txt"
  local task_bundle_refs_file="${work_dir}/task-bundles.txt"
  local trusted_yaml="${work_dir}/trusted-source-base.yaml"
  local idx=0

  data_bundles_ref="$(normalize_image_ref "$data_bundles_ref")"

  log "Reading pipeline bundle refs from: $pipelines_file"
  extract_pipeline_bundle_refs "$pipelines_file" "$pipeline_refs_file"
  log "Found $(wc -l <"$pipeline_refs_file" | awk '{print $1}') pipeline bundle refs"

  : >"$task_bundle_refs_file"
  while IFS= read -r pipeline_ref; do
    [[ -n "$pipeline_ref" ]] || continue
    pipeline_ref="$(normalize_image_ref "$pipeline_ref")"
    idx=$((idx + 1))
    log "Extracting bundle task refs from pipeline image [$idx]: $pipeline_ref"
    extract_task_bundle_refs_from_pipeline_image "$pipeline_ref" "${work_dir}/pipeline-image-${idx}" "$task_bundle_refs_file"
  done <"$pipeline_refs_file"

  awk '!seen[$0]++' "$task_bundle_refs_file" >"${task_bundle_refs_file}.dedup"
  mv "${task_bundle_refs_file}.dedup" "$task_bundle_refs_file"

  if [[ ! -s "$task_bundle_refs_file" ]]; then
    die "no task bundle refs were extracted from provided pipeline images"
  fi
  log "Found $(wc -l <"$task_bundle_refs_file" | awk '{print $1}') unique task bundle refs"

  log "Fetching trusted_tasks data from: $data_bundles_ref"
  if ! extract_trusted_yaml_from_data_image "$data_bundles_ref" "${work_dir}/data-image" "$trusted_yaml"; then
    die "could not find trusted_tasks YAML in data image: $data_bundles_ref"
  fi

  declare -A key_to_digests=()

  local bundle_ref image digest key
  while IFS= read -r bundle_ref; do
    [[ -n "$bundle_ref" ]] || continue
    if [[ "$bundle_ref" != *@* ]]; then
      die "task bundle ref is missing @digest: $bundle_ref"
    fi
    image="${bundle_ref%@*}"
    digest="${bundle_ref##*@}"
    if [[ "$digest" != sha256:* ]]; then
      die "task bundle ref digest must start with sha256: $bundle_ref"
    fi
    key="oci://${image}"

    if [[ -n "${key_to_digests[$key]:-}" ]]; then
      if [[ " ${key_to_digests[$key]} " == *" ${digest} "* ]]; then
        continue
      fi
      key_to_digests["$key"]+="${key_to_digests[$key]:+ }${digest}"
    else
      key_to_digests["$key"]="${digest}"
    fi
  done <"$task_bundle_refs_file"

  log "Promoting pipeline task refs to trusted_tasks head (index 0)"
  local promote_count=0
  for key in "${!key_to_digests[@]}"; do
    local selected_digest=""
    local selected_index=-1
    local current_index
    read -r -a digests_for_key <<<"${key_to_digests[$key]}"

    # Verify key exists and digest is already in the trusted list.
    local key_exists
    key_exists="$(KEY="$key" yq -r '.trusted_tasks[strenv(KEY)] != null' "$trusted_yaml")"
    if [[ "$key_exists" != "true" ]]; then
      die "trusted_tasks key not found for pipeline task: ${key}"
    fi

    for digest in "${digests_for_key[@]}"; do
      current_index="$(KEY="$key" DIGEST="$digest" yq -r '
        (.trusted_tasks[strenv(KEY)] // [])
        | to_entries
        | map(select(.value.ref == strenv(DIGEST)).key)
        | (.[0] // -1)
      ' "$trusted_yaml")"
      if [[ "$current_index" == "-1" ]]; then
        die "pipeline task digest not present in trusted_tasks for key ${key}: ${digest}"
      fi
      if [[ "$selected_index" == "-1" || "$current_index" -lt "$selected_index" ]]; then
        selected_index="$current_index"
        selected_digest="$digest"
      fi
    done

    if [[ "${#digests_for_key[@]}" -gt 1 ]]; then
      log "Multiple pipeline digests found for ${key}; choosing newest known trusted ref: ${selected_digest} (candidates: ${key_to_digests[$key]})"
    fi

    KEY="$key" DIGEST="$selected_digest" yq -i '
      .trusted_tasks[strenv(KEY)] = (
        [ .trusted_tasks[strenv(KEY)][] | select(.ref == strenv(DIGEST)) | del(.expires_on) ] +
        [ .trusted_tasks[strenv(KEY)][] | select(.ref != strenv(DIGEST)) ]
      )
    ' "$trusted_yaml"

    promote_count=$((promote_count + 1))
  done

  mkdir -p "$(dirname "$output_file")"
  cp "$trusted_yaml" "$output_file"
  log "Wrote output file: $output_file"
  log "Promoted ${promote_count} trusted_tasks entries to non-expiring head refs"
}

main "$@"
