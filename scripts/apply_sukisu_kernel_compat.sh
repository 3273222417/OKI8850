#!/usr/bin/env bash
# Apply narrow source compatibility fixes required by Android 16 / 6.12 GKI.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "${1:?kernel workspace required}" && pwd)"
KSU_DIR="$WORKSPACE/KernelSU"
COMMON="$WORKSPACE/common"

test -d "$KSU_DIR/kernel"
test -d "$COMMON"

runner="$KSU_DIR/kernel/preinit/runner/runner.c"
test -s "$runner"
lsm="$KSU_DIR/kernel/hook/lsm_hook.c"
test -s "$lsm"

# The builtin Makefile/Kbuild relative src path resolves outside the symlinked
# drivers/kernelsu tree under the GKI external build. Pin the source root to
# the real source directory so the runner dependency is found reliably.
for makefile in "$KSU_DIR/kernel/Makefile" "$KSU_DIR/kernel/Kbuild"; do
  [[ -f "$makefile" ]] || continue
  python3 - "$makefile" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = """ifeq ($(filter /%,$(src)),)\nKSU_KERNEL_DIR := $(srctree)/$(src)\nelse\nKSU_KERNEL_DIR := $(src)\nendif\n"""
new = """# Resolve the symlinked KernelSU source tree, not the driver's relative src.\nKSU_KERNEL_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))\n"""
if old in text:
    text = text.replace(old, new, 1)
elif "KSU_KERNEL_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))" not in text:
    raise SystemExit("unsupported SukiSU builtin Makefile KSU_KERNEL_DIR block")
path.write_text(text, encoding="utf-8", newline="\n")
PY
  grep -q 'KSU_KERNEL_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))' "$makefile" || {
    echo "KSU source-root resolution was not installed in $makefile" >&2
    exit 1
  }
done

# Android 16's static-call LSM table is sized from MAX_LSM_COUNT. Reserve one
# slot for builtin KSU before it registers its hooks at device_initcall time.
lsm_count="$COMMON/include/linux/lsm_count.h"
security_c="$COMMON/security/security.c"
if [[ -f "$lsm_count" && -f "$security_c" ]] \
  && grep -Eq 'Ran out of static slots|Too many LSMs registered' "$security_c" \
  && grep -q 'security_add_hooks(ksu_hooks' "$lsm" \
  && ! grep -q 'KSU_ENABLED' "$lsm_count"; then
  python3 - "$lsm_count" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
anchor = "#define MAX_LSM_COUNT"
idx = text.find(anchor)
if idx < 0:
    raise SystemExit("MAX_LSM_COUNT not found")
block = """/* Reserve one static-call slot for builtin KernelSU. */
#if IS_ENABLED(CONFIG_KSU)
#define KSU_ENABLED 1,
#else
#define KSU_ENABLED
#endif

"""
text = text[:idx] + block + text[idx:]
count = text.find("COUNT_LSMS(", idx)
if count < 0:
    raise SystemExit("COUNT_LSMS not found")
line_end = text.find("\n", count)
text = text[:line_end + 1] + "\t\tKSU_ENABLED\t\t\\\n" + text[line_end + 1:]
path.write_text(text, encoding="utf-8", newline="\n")
PY
  grep -q 'KSU_ENABLED' "$lsm_count"
fi

# 6.8+ changed security_add_hooks() to take struct lsm_id. Keep the builtin
# source compatible with older kernels through a version guard.
if grep -q 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");' "$lsm" \
  && ! grep -q 'struct lsm_id ksu_lsm_id' "$lsm"; then
  patch -p1 --forward -d "$KSU_DIR" < "$SCRIPT_DIR/sukisu-lsm-id-6.8.patch"
fi
grep -q 'security_add_hooks' "$lsm"

printf 'SukiSU kernel compatibility: runner=%s lsm_id=%s\n' \
  "$([[ -s "$runner" ]] && echo present || echo missing)" \
  "$(grep -q 'struct lsm_id ksu_lsm_id' "$lsm" && echo patched || echo upstream)"
