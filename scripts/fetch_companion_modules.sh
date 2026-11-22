#!/usr/bin/env bash
# Fetch the current companion modules for the same rolling Nova build.
# Usage: bash scripts/fetch_companion_modules.sh output_dir true|false
set -euo pipefail

OUT="$(mkdir -p -- "${1:?output directory required}" && cd -- "$1" && pwd)"
NOMOUNT="${2:?true or false required}"
case "$NOMOUNT" in true|false) ;; *) exit 1 ;; esac
mkdir -p "$OUT"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sukisu_sources.env"

AUTH_ARGS=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer $GITHUB_TOKEN")
elif [[ -n "${GH_TOKEN:-}" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer $GH_TOKEN")
fi

get_latest_release_asset() {
  local repo="$1" pattern="$2" label="$3"
  local json tag url
  json="$(curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors \
    "${AUTH_ARGS[@]}" "https://api.github.com/repos/$repo/releases/latest")"
  tag="$(jq -r '.tag_name // empty' <<<"$json")"
  url="$(jq -r --arg pattern "$pattern" '[.assets[]? | select(.name | test($pattern; "i")) | .browser_download_url][0] // empty' <<<"$json")"
  [[ -n "$url" && "$url" != null ]] || { echo "No $label asset in $repo release $tag" >&2; return 1; }
  local source_file="$OUT/.${label}-source.zip"
  curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors -o "$source_file" "$url"
  unzip -t "$source_file" >/dev/null
  local version
  version="$(module_prop_value_from_zip "$source_file" version || true)"
  version="${version:-$tag}"
  version="$(safe_version "$version")"
  local output="${label}-${version}.zip"
  mv -- "$source_file" "$OUT/$output"
  printf '%s=%s\n' "${label^^}_RELEASE" "$tag" >> "$OUT/companion-source.txt"
  printf '%s=%s\n' "${label^^}_VERSION" "$version" >> "$OUT/companion-source.txt"
  printf '%s=%s\n' "${label^^}_FILE" "$output" >> "$OUT/companion-source.txt"
  printf '%s=%s\n' "${label^^}__SOURCE_ASSET" "$(basename "$url")" >> "$OUT/companion-source.txt"
  write_output "${label}_version" "$version"
  write_output "${label}_file" "$output"
  write_output "${label}_artifact_name" "${label}-${version}"
}

write_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

safe_version() {
  local value="$1"
  value="$(printf '%s' "$value" | sed -E 's/[^A-Za-z0-9._+()-]+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$value" ]] || { echo 'module version is empty after sanitization' >&2; return 1; }
  printf '%s' "$value"
}

module_prop_value() {
  local prop="$1" key="$2"
  awk -F= -v key="$key" '$1 == key {sub(/\r$/, "", $2); print $2; exit}' "$prop"
}

module_prop_value_from_zip() {
  local zip="$1" key="$2" entry
  entry="$(unzip -Z1 "$zip" | awk '$0 ~ /(^|\/)module\.prop$/ {print; exit}')"
  [[ -n "$entry" ]] || return 1
  unzip -p "$zip" "$entry" | awk -F= -v key="$key" '$1 == key {sub(/\r$/, "", $2); print $2; exit}'
}

# SUSFS's upstream module is produced by its GitHub Actions workflow. Use the
# newest successful artifact on the module branch, rather than a Release asset.
get_latest_ci_module() {
  local repo="$1" workflow="$2" branch="$3" prefix="$4" label="$5"
  local runs run_id run_created run_sha artifacts artifact_row artifact_id artifact_name artifact_url
  local tmp module_prop module_root version output
  runs="$(curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors \
    "${AUTH_ARGS[@]}" "https://api.github.com/repos/$repo/actions/workflows/$workflow/runs?status=success&per_page=50")"
  while IFS=$'\t' read -r run_id run_created run_sha; do
    [[ -n "$run_id" ]] || continue
    artifacts="$(curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors \
      "${AUTH_ARGS[@]}" "https://api.github.com/repos/$repo/actions/runs/$run_id/artifacts?per_page=100")"
    artifact_row="$(jq -r --arg prefix "$prefix" '[.artifacts[]? | select(.expired == false and (.name | startswith($prefix)))] | sort_by(.created_at) | reverse | .[0] | if . then [.id, .name, .archive_download_url] | @tsv else empty end' <<<"$artifacts")"
    [[ -n "$artifact_row" ]] || continue
    IFS=$'\t' read -r artifact_id artifact_name artifact_url <<< "$artifact_row"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors \
      "${AUTH_ARGS[@]}" -o "$tmp/artifact.zip" "$artifact_url"
    unzip -oq "$tmp/artifact.zip" -d "$tmp/extracted"
    module_prop="$(find "$tmp/extracted" -type f -name module.prop -print -quit)"
    [[ -n "$module_prop" ]] || { rm -rf "$tmp"; trap - RETURN; continue; }
    module_root="${module_prop%/module.prop}"
    version="$(module_prop_value "$module_prop" version || true)"
    version="${version:-CI-${run_sha:0:7}}"
    version="$(safe_version "$version")"
    output="${label}-${version}.zip"
    (cd "$module_root" && zip -qr "$OUT/$output" .)
    unzip -t "$OUT/$output" >/dev/null
    printf '%s=%s\n' "${label^^}_CI_RUN" "$run_id" >> "$OUT/companion-source.txt"
    printf '%s=%s\n' "${label^^}_CI_CREATED" "$run_created" >> "$OUT/companion-source.txt"
    printf '%s=%s\n' "${label^^}_CI_HEAD" "$run_sha" >> "$OUT/companion-source.txt"
    printf '%s=%s\n' "${label^^}_CI_ARTIFACT" "$artifact_name" >> "$OUT/companion-source.txt"
    printf '%s=%s\n' "${label^^}_VERSION" "$version" >> "$OUT/companion-source.txt"
    printf '%s=%s\n' "${label^^}_CI_FILE" "$output" >> "$OUT/companion-source.txt"
    write_output "${label}_version" "$version"
    write_output "${label}_file" "$output"
    write_output "${label}_artifact_name" "${label}-${version}"
    rm -rf "$tmp"
    trap - RETURN
    return 0
  done < <(jq -r --arg branch "$branch" '[.workflow_runs[]? | select(.status == "completed" and .conclusion == "success" and ($branch == "" or .head_branch == $branch))] | sort_by(.created_at) | reverse | .[] | [.id, .created_at, .head_sha] | @tsv' <<<"$runs")
  echo "No successful CI module artifact found for $repo/$workflow branch $branch" >&2
  return 1
}

get_latest_ci_module "$SUSFS_MODULE_REPOSITORY" "$SUSFS_MODULE_WORKFLOW" \
  "$SUSFS_MODULE_BRANCH" "$SUSFS_MODULE_ARTIFACT_PREFIX" susfs
if [[ "$NOMOUNT" == true ]]; then
  get_latest_release_asset 'maxsteeel/nomount' '[.]zip$' nomount
fi
