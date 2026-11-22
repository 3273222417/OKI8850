#!/usr/bin/env python3
"""Drop the redundant ZSTD BMI2 hunk when the vendor tree already has it."""

from pathlib import Path
import re
import sys


SECTION = "diff --git a/lib/zstd/common/portability_macros.h "
HUNK = re.compile(r"^@@ -55,7 \+56,7 @@")
VENDOR_CONDITION = "&& (__GNUC__ >= 11)))"


def normalize(patch_text: str, source_header: str) -> str:
	if VENDOR_CONDITION not in source_header:
		return patch_text

	lines = patch_text.splitlines(keepends=True)
	result = []
	in_portability_section = False
	i = 0
	removed = False
	while i < len(lines):
		line = lines[i]
		if line.startswith("diff --git "):
			in_portability_section = line.startswith(SECTION)
		if in_portability_section and HUNK.match(line):
			i += 1
			while i < len(lines) and not lines[i].startswith(("@@ ", "diff --git ")):
				i += 1
			removed = True
			continue
		result.append(line)
		i += 1
	if not removed:
		raise ValueError("expected ZSTD portability BMI2 hunk was not found")
	return "".join(result)


def main() -> None:
	if len(sys.argv) != 3:
		raise SystemExit("usage: normalize_zstd_patch.py patch-file vendor-header")
	patch_text = Path(sys.argv[1]).read_text(encoding="utf-8").replace("\r\n", "\n")
	header = Path(sys.argv[2]).read_text(encoding="utf-8").replace("\r\n", "\n")
	try:
		sys.stdout.write(normalize(patch_text, header))
	except (OSError, ValueError) as exc:
		raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
	main()
