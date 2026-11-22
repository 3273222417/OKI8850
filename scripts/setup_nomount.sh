#!/usr/bin/env bash
# Integrate the NoMount kernel side and enable its Kconfig option.
# Usage: bash scripts/setup_nomount.sh kernel_workspace
set -euo pipefail

WORKSPACE="$(cd -- "${1:?kernel workspace required}" && pwd)"
COMMON="$WORKSPACE/common"
SETUP_URL="https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh"

test -d "$COMMON"
cd "$COMMON"
test ! -e "fs/nomount" || { echo 'NoMount is already integrated' >&2; exit 1; }

# No argument makes the upstream installer select its newest tagged release.
# This keeps the kernel integration and the companion module on a rolling
# release policy without pinning a branch or commit in this repository.
curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "$SETUP_URL" \
  | bash -s --

test -L "fs/nomount"
grep -Fqx 'source "fs/nomount/Kconfig"' "fs/Kconfig"
grep -q '^config NOMOUNT$' "fs/nomount/Kconfig"

DEFCONFIG="arch/arm64/configs/gki_defconfig"
if ! grep -q '^CONFIG_NOMOUNT=y$' "$DEFCONFIG"; then
  printf '\nCONFIG_NOMOUNT=y\n' >> "$DEFCONFIG"
fi
grep -q '^CONFIG_NOMOUNT=y$' "$DEFCONFIG"
printf 'NoMount integrated: %s\n' "$(git -C "$COMMON/NoMount" rev-parse HEAD 2>/dev/null || git -C "$WORKSPACE/NoMount" rev-parse HEAD 2>/dev/null || echo unknown)"
