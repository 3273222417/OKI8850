#!/usr/bin/env bash
# Apply the current OKI SUSFS branch and adapt its hooks to Nova builtin.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sukisu_sources.env"
WORKSPACE="$(cd -- "${1:?kernel workspace required}" && pwd)"
cd "$WORKSPACE"
test -f KernelSU/kernel/Makefile
SUKISU_BUILTIN_COMMIT="${SUKISU_BUILTIN_COMMIT:-$(git -C KernelSU rev-parse HEAD)}"
test "$(git -C KernelSU rev-parse HEAD)" = "$SUKISU_BUILTIN_COMMIT"
test ! -e susfs4ksu || { echo 'susfs4ksu already exists; use a clean workspace' >&2; exit 1; }
git init susfs4ksu
git -C susfs4ksu remote add origin "$SUKISU_SUSFS_REPOSITORY"
git -C susfs4ksu fetch --depth=1 origin "$SUKISU_SUSFS_BRANCH"
git -C susfs4ksu checkout --detach FETCH_HEAD
SUSFS_COMMIT="$(git -C susfs4ksu rev-parse HEAD)"

PATCH="$WORKSPACE/susfs-oki.patch"
SUSFS_PATCH="susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION:-android16}-${KERNEL_VERSION:-6.12}.patch"
python3 "$SCRIPT_DIR/prepare_susfs_patch.py" \
  "$SUSFS_PATCH" \
  common/fs/proc/task_mmu.c "$PATCH"
# A partially applied hook patch is not a successful integration. Dry-run first
# and stop on rejects rather than continuing with missing hooks/undefined symbols.
patch --batch --forward --dry-run -p1 -F 3 -d common < "$PATCH"
cp susfs4ksu/kernel_patches/fs/* common/fs/
cp susfs4ksu/kernel_patches/include/linux/* common/include/linux/
patch --batch --forward -p1 -F 3 -d common < "$PATCH"
python3 "$SCRIPT_DIR/adapt_sukisu_susfs.py" common KernelSU
printf 'susfs_source=%s\nsusfs_branch=%s\nsusfs_commit=%s\n' "$SUKISU_SUSFS_REPOSITORY" "$SUKISU_SUSFS_BRANCH" "$SUSFS_COMMIT" >> sukisu-source.txt
# Do not apply the unrelated legacy 69_hide_stuff.patch to this SUSFS
# layout. Its contexts predate SUSFS 2.4 and partial application is unsafe.
