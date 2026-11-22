#!/usr/bin/env bash
# Apply the 6.12 LZ4 1.10.0 and ZSTD 1.5.7 source patches.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$(cd -- "${1:?kernel source directory required}" && pwd)"
cd "$COMMON"

if [[ ! -e .git ]]; then
  git init -q
fi

lz4="$ROOT/zram_patch/001-lz4.patch"
zstd="$ROOT/zram_patch/002-zstd.patch"

# Some 6.12 vendor trees already carry the GCC >= 11 BMI2 condition. The
# upstream 1.5.7 patch still contains the older GCC 4.8 context, so normalize
# that one context line before applying the otherwise complete patch.
zstd_stream() {
  python3 "$ROOT/scripts/normalize_zstd_patch.py" \
    "$zstd" lib/zstd/common/portability_macros.h
}

sed 's/\r$//' "$lz4" | git -c core.autocrlf=false apply --check -p1 -
zstd_stream | patch --batch --forward --dry-run -p1 -F 3
sed 's/\r$//' "$lz4" | git -c core.autocrlf=false apply -p1 -
zstd_stream | patch --batch --forward -p1 -F 3

grep -Eq '^#define LZ4_VERSION_MAJOR[[:space:]]+1\b' lib/lz4/lz4.h
grep -Eq '^#define LZ4_VERSION_MINOR[[:space:]]+10\b' lib/lz4/lz4.h
grep -Eq '^#define LZ4_VERSION_RELEASE[[:space:]]+0\b' lib/lz4/lz4.h
grep -Eq '^#define ZSTD_VERSION_MAJOR[[:space:]]+1\b' include/linux/zstd_lib.h
grep -Eq '^#define ZSTD_VERSION_MINOR[[:space:]]+5\b' include/linux/zstd_lib.h
grep -Eq '^#define ZSTD_VERSION_RELEASE[[:space:]]+7\b' include/linux/zstd_lib.h
echo 'Verified LZ4 1.10.0 and ZSTD 1.5.7 sources.'
