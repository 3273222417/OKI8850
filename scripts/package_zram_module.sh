#!/usr/bin/env bash
# Package zram/zsmalloc modules built from the matching 6.12 kernel tree.
# Usage: bash scripts/package_zram_module.sh common output.zip version
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMMON="$(cd -- "${1:?common source directory required}" && pwd)"
OUTPUT="$(cd -- "$(dirname -- "${2:?output zip required}")" && pwd)/$(basename -- "$2")"
VERSION="${3:?module version required}"
TEMPLATE="$ROOT/zram.zip"
ZRAM="$COMMON/out/drivers/block/zram/zram.ko"
ZSMALLOC="$COMMON/out/mm/zsmalloc.ko"

test -s "$TEMPLATE"
test -s "$ZRAM"
test -s "$ZSMALLOC"
mkdir -p "$(dirname -- "$OUTPUT")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$TEMPLATE" -d "$TMP/module"
cp "$ZRAM" "$TMP/module/zram.ko"
cp "$ZSMALLOC" "$TMP/module/zsmalloc.ko"
cp "$SCRIPT_DIR/zram_service.sh" "$TMP/module/service.sh"
chmod 0755 "$TMP/module/service.sh"

escaped_version="${VERSION//&/\\&}"
sed -i \
  -e 's/^id=.*/id=zram_lz4_zstd_6_12/' \
  -e 's/^name=.*/name=ZRAM LZ4 1.10.0 + ZSTD 1.5.7/' \
  -e "s/^version=.*/version=1.10.0+1.5.7-$escaped_version/" \
  -e 's/^versionCode=.*/versionCode=11057/' \
  -e 's/^description=.*/description=Kernel-matched zram module with LZ4 1.10.0 and ZSTD 1.5.7/' \
  "$TMP/module/module.prop"

printf 'kernel_version=%s\nzram_source=%s\nzsmalloc_source=%s\n' \
  "$VERSION" "$ZRAM" "$ZSMALLOC" > "$TMP/module/zram-build.txt"
(cd "$TMP/module" && zip -qr -9 "$OUTPUT" .)
unzip -tq "$OUTPUT"
sha256sum "$OUTPUT" > "${OUTPUT%.zip}.sha256"
printf 'Packaged matching ZRAM module: %s\n' "$OUTPUT"
