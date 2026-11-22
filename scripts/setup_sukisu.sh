#!/usr/bin/env bash
# Usage: bash scripts/setup_sukisu.sh kernel_workspace true|false
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sukisu_sources.env"

WORKSPACE="$(cd -- "${1:?kernel workspace required}" && pwd)"
SUSFS="${2:?SUSFS true or false required}"
case "$SUSFS" in
  true) BRANCH=builtin ;;
  false) BRANCH=main ;;
  *) echo "SUSFS must be true or false" >&2; exit 1 ;;
esac
test -d "$WORKSPACE/common/drivers"
test ! -e "$WORKSPACE/KernelSU" || { echo 'KernelSU already exists; use a clean workspace' >&2; exit 1; }

retry_git() {
  local attempt
  for attempt in 1 2 3 4; do
    if "$@"; then
      return 0
    fi
    if [[ "$attempt" -lt 4 ]]; then
      echo "Git operation failed; retrying in $((attempt * 5))s ($attempt/4): $*" >&2
      sleep "$((attempt * 5))"
    fi
  done
  return 1
}

# Keep the complete main history for the CI version formula and fetch all
# blobs up front. A blobless partial clone can fail later during checkout when
# a transient upstream TLS error interrupts Git's implicit promisor fetch.
clone_main() {
  local attempt
  for attempt in 1 2 3 4; do
    if git clone --no-tags --no-checkout --single-branch --branch main \
      "$SUKISU_REPOSITORY" "$WORKSPACE/KernelSU"; then
      return 0
    fi
    rm -rf -- "$WORKSPACE/KernelSU"
    if [[ "$attempt" -lt 4 ]]; then
      echo "SukiSU clone failed; retrying in $((attempt * 5))s ($attempt/4)" >&2
      sleep "$((attempt * 5))"
    fi
  done
  return 1
}

clone_main || { echo 'Unable to clone SukiSU-Nova main after 4 attempts' >&2; exit 1; }
CURRENT_MAIN_COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse refs/remotes/origin/main)"
git -C "$WORKSPACE/KernelSU" cat-file -e "$CURRENT_MAIN_COMMIT^{commit}"
test "$(git -C "$WORKSPACE/KernelSU" rev-parse --is-shallow-repository)" = false

release_json=''
assets=''
manager_version=''
manager_tag=''
manager_target=''
manager_release_url="$SUKISU_CI_FALLBACK_RELEASE_URL"
refresh_main() {
  retry_git git -C "$WORKSPACE/KernelSU" fetch --no-tags origin \
    "+refs/heads/main:refs/remotes/origin/main" || return 1
  CURRENT_MAIN_COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse refs/remotes/origin/main)" || return 1
  git -C "$WORKSPACE/KernelSU" cat-file -e "$CURRENT_MAIN_COMMIT^{commit}" || return 1
}
for attempt in $(seq 1 "$SUKISU_CI_MAX_ATTEMPTS"); do
  # Never carry a stale release across a transient API/page failure or a
  # rolling-release update observed between attempts.
  release_json=''
  assets=''
  manager_version=''
  manager_tag=''
  manager_target=''
  manager_release_url="$SUKISU_CI_FALLBACK_RELEASE_URL"
  target_count=''
  target_version=''
  target_is_ancestor=false
  if ! refresh_main; then
    if [[ "$attempt" -eq "$SUKISU_CI_MAX_ATTEMPTS" ]]; then
      echo "Unable to refresh SukiSU-Nova main after $attempt attempts" >&2
      exit 1
    fi
    echo "Unable to refresh SukiSU-Nova main; retrying ($attempt/$SUKISU_CI_MAX_ATTEMPTS)" >&2
    sleep "$SUKISU_CI_RETRY_SECONDS"
    continue
  fi
  release_json="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 45 \
    -H 'Cache-Control: no-cache' "$SUKISU_CI_API/releases/tags/$SUKISU_CI_TAG")" || release_json=''
  if [[ -n "$release_json" ]]; then
    manager_tag="$(jq -r '.tag_name // empty' <<<"$release_json")"
    manager_target="$(jq -r '.target_commitish // empty' <<<"$release_json")"
    # Keep the fallback host/path controlled by sukisu_sources.env; the release
    # body is descriptive metadata and is not used as a fetch destination.

    # Derive the expected version from the release target before selecting an
    # APK. This prevents a rolling page with stale files from pairing an old
    # Manager with a newer target commit.
    target_count=''
    target_version=''
    target_is_ancestor=false
    if [[ "$manager_target" =~ ^[0-9a-f]{40}$ ]] \
        && git -C "$WORKSPACE/KernelSU" cat-file -e "$manager_target^{commit}" 2>/dev/null \
        && git -C "$WORKSPACE/KernelSU" merge-base --is-ancestor "$manager_target" "$CURRENT_MAIN_COMMIT"; then
      target_count="$(git -C "$WORKSPACE/KernelSU" rev-list --count "$manager_target")"
      target_version=$((SUKISU_VERSION_BASE + target_count + SUKISU_VERSION_OFFSET))
      target_is_ancestor=true
    fi
    assets=''
    if [[ "$target_is_ancestor" == true ]]; then
      assets="$(jq -r --arg version "$target_version" '[.assets[]? | select(.name | test("release[.]apk$"; "i")) | select(.name | test("arm64-v8a|universal"; "i")) | select(.name | test("debug|spoofed"; "i") | not) | select(.name | contains("_" + $version + "-"))] | sort_by(if (.name | test("arm64-v8a"; "i")) then 0 else 1 end) | .[] | [.name, .browser_download_url] | @tsv' <<<"$release_json")"
    fi

    # Forgejo currently keeps metadata only; APKs are published on the
    # configured rolling CNB tag page. Resolve its current contents instead of
    # pinning a specific CI version.
    if [[ -z "$assets" ]]; then
      fallback_html="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 45 \
        -H 'Cache-Control: no-cache' "$manager_release_url")" || fallback_html=''
      if [[ -n "$fallback_html" && -n "$target_version" ]]; then
        assets="$(printf '%s' "$fallback_html" | \
          python3 "$SCRIPT_DIR/extract_manager_assets.py" "$manager_release_url" "$target_version")"
      fi
    fi
    first_name="$(head -n 1 <<<"$assets" | cut -f1)"
    if [[ "$first_name" =~ _([0-9]+)(-([a-z0-9-]+))?-release[.]apk$ ]]; then
      manager_version="${BASH_REMATCH[1]}"
    else
      manager_version=''
    fi
  fi

  if [[ "$target_is_ancestor" == true && "$manager_version" == "$target_version" && -n "$assets" ]]; then
    MAIN_COMMIT="$manager_target"
    COUNT="$target_count"
    VERSION="$target_version"
    break
  fi
  if [[ "$attempt" -eq "$SUKISU_CI_MAX_ATTEMPTS" ]]; then
    printf 'SukiSU-Nova manager-ci is not ready for current main=%s (release target=%s, expected target version=%s, APK version=%s)\n' \
      "$CURRENT_MAIN_COMMIT" "$manager_target" "${target_version:-unknown}" "${manager_version:-unknown}" >&2
    exit 1
  fi
  echo "manager-ci is ${manager_version:-unavailable}, current main is $CURRENT_MAIN_COMMIT; waiting for the matching latest CI build ($attempt/$SUKISU_CI_MAX_ATTEMPTS)"
  sleep "$SUKISU_CI_RETRY_SECONDS"
done

manager_name="$(head -n 1 <<<"$assets" | cut -f1)"
if [[ "$manager_name" =~ _v?([0-9]+[.][0-9]+[.][0-9]+)(-[^_]+)?_${manager_version}- ]]; then
  manager_name="${BASH_REMATCH[1]}"
else
  manager_name="$manager_tag"
fi

if ! git -C "$WORKSPACE/KernelSU" cat-file -e "refs/remotes/origin/$BRANCH^{commit}" 2>/dev/null; then
  retry_git git -C "$WORKSPACE/KernelSU" fetch --no-tags origin \
    "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || {
      echo "Unable to fetch SukiSU-Nova $BRANCH after 4 attempts" >&2
      exit 1
    }
fi
if [[ "$BRANCH" == main ]]; then
  # Pair the main checkout with the exact commit represented by the Manager.
  COMMIT="$MAIN_COMMIT"
else
  COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse "refs/remotes/origin/$BRANCH")"
fi
git -C "$WORKSPACE/KernelSU" checkout --detach "$COMMIT"
test "$(git -C "$WORKSPACE/KernelSU" rev-parse HEAD)" = "$COMMIT"
BUILTIN_COMMIT=""
if git -C "$WORKSPACE/KernelSU" cat-file -e refs/remotes/origin/builtin^{commit} 2>/dev/null; then
  BUILTIN_COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse refs/remotes/origin/builtin)"
fi
python3 "$SCRIPT_DIR/prepare_sukisu.py" "$WORKSPACE" --susfs "$SUSFS" \
  --version "$VERSION" --count "$COUNT" --ref "$MAIN_COMMIT" --tag "$manager_name"
bash "$SCRIPT_DIR/apply_sukisu_kernel_compat.sh" "$WORKSPACE"

mkdir -p "$WORKSPACE/manager-artifacts"
manager_asset_line="$(head -n 1 <<< "$assets")"
IFS=$'\t' read -r manager_asset_name manager_asset_url <<< "$manager_asset_line"
test -n "$manager_asset_name" && test -n "$manager_asset_url"
curl -fsSL --retry 3 --max-time 300 \
  -o "$WORKSPACE/manager-artifacts/$manager_asset_name" "$manager_asset_url"
test -n "$(find "$WORKSPACE/manager-artifacts" -type f -name '*release.apk' -print -quit)"

printf 'SukiSU-Nova: branch=%s commit=%s main=%s version=%s manager=%s\n' "$BRANCH" "$COMMIT" "$MAIN_COMMIT" "$VERSION" "$manager_name"
printf 'source=%s\nbranch=%s\ncommit=%s\nversion_source=%s\nKSUVER=%s\nci_release=%s\nci_target=%s\nmanager_version=%s\nmanager_name=%s\nmanager_release_page=%s\nmanager_asset=%s\n' \
  "$SUKISU_REPOSITORY" "$BRANCH" "$COMMIT" "$MAIN_COMMIT" "$VERSION" "$SUKISU_CI_RELEASE_URL" "$manager_target" "$manager_version" "$manager_name" "$manager_release_url" "$manager_asset_url" \
  > "$WORKSPACE/sukisu-source.txt"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'KSUVER=%s\nSUKISU_CI_VERSION_CODE=%s\nSUKISU_MAIN_COMMIT=%s\nSUKISU_BUILTIN_COMMIT=%s\nSUKISU_COMMIT=%s\nSUKISU_BRANCH=%s\n' \
    "$VERSION" "$VERSION" "$MAIN_COMMIT" "$BUILTIN_COMMIT" "$COMMIT" "$BRANCH" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'ksuver=%s\nmanager_version=%s\nmain_commit=%s\nbuiltin_commit=%s\n' \
    "$VERSION" "$manager_version" "$MAIN_COMMIT" "$BUILTIN_COMMIT" >> "$GITHUB_OUTPUT"
fi
