#!/usr/bin/env bash
# Run inside common after make Image and before optional KPatch-Next rewriting.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sukisu_sources.env"
SUSFS="${1:?SUSFS true or false required}"
NOMOUNT="${2:-false}"
case "$SUSFS" in true|false) ;; *) exit 1 ;; esac
case "$NOMOUNT" in true|false) ;; *) exit 1 ;; esac

grep -qx 'CONFIG_KSU=y' out/.config
grep -qx 'CONFIG_HEADERS_INSTALL=y' out/.config
if [[ "$SUSFS" == true ]]; then
  grep -qx 'CONFIG_KSU_SUSFS=y' out/.config
  nova_cmd=out/drivers/kernelsu/.ksu_main.o.cmd
else
  if grep -qx 'CONFIG_KSU_SUSFS=y' out/.config; then
    echo 'SUSFS unexpectedly enabled' >&2
    exit 1
  fi
  nova_cmd=out/drivers/kernelsu/core/.init.o.cmd
fi
if grep -qx 'CONFIG_KPM=y' out/.config; then
  echo 'SukiSU-Nova builtin KPM should stay disabled when independent KPatch-Next is used' >&2
  exit 1
fi
if [[ "$NOMOUNT" == true ]] && ! grep -qx 'CONFIG_NOMOUNT=y' out/.config; then
  echo 'NoMount was requested but CONFIG_NOMOUNT is not enabled' >&2
  exit 1
fi
test -s out/usr/include/linux/unistd.h
test -s out/drivers/kernelsu/preinit/runner.elf
test -s out/arch/arm64/boot/Image

CI_VERSION="${SUKISU_CI_VERSION_CODE:-${KSUVER:-}}"
if [[ ! "$CI_VERSION" =~ ^[0-9]+$ && -s ../sukisu-source.txt ]]; then
  CI_VERSION="$(awk -F= '$1 == "KSUVER" {print $2; exit}' ../sukisu-source.txt)"
fi
if [[ ! "$CI_VERSION" =~ ^[0-9]+$ ]]; then
  echo 'SukiSU-Nova CI version is missing from the build environment' >&2
  exit 1
fi
if ! grep -Eq -- "(^|[[:space:]])-DKSU_VERSION=$CI_VERSION([[:space:]]|$)" "$nova_cmd"; then
  echo "SukiSU-Nova compile flags do not match CI $CI_VERSION: $nova_cmd" >&2
  exit 1
fi
echo "SukiSU-Nova CI $CI_VERSION build checks passed (config, UAPI headers, preinit runner, Image)."
