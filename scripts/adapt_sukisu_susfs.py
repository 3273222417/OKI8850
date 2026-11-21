#!/usr/bin/env python3
"""Adapt the validated SUSFS kernel hooks to SukiSU-Nova builtin.

Evidence: SukiSU-Nova/SukiSU-Nova builtin 4bec532dd447e2852aa8932afa768255350c103a,
cctv18/susfs4oki oki-android15-6.6 c7f303f504b36d25b9a2e753edde7cd927f47e4f,
and oki-android16-6.12 2ea91d1c37cc974b683d6ffbc2e913c3b728d1f5. The SUSFS
patch uses a static key where Nova exports a bool, and a one-argument void
read hook where Nova exports a three-argument int hook. The same narrow ABI
adapter is validated against the Android 16/6.12 patch layout.

Run AFTER applying the SUSFS kernel patch: adapt_sukisu_susfs.py common KernelSU
Only four kernel files are changed; the Nova checkout remains untouched. Every
input is validated before any file is written. This is deliberately a narrow
adapter, not a general C rewriter: unknown/partially patched layouts fail closed.
"""

import argparse
from pathlib import Path
import re
import sys


class AdaptationError(ValueError):
    """An input no longer has the reviewed source shape."""


BOOL_SYMBOL = "ksu_su_compat_enabled"
READ_SYMBOL = "ksu_handle_sys_read"
BOOL_FILES = ("fs/exec.c", "fs/open.c", "fs/stat.c")
READ_FILE = "fs/read_write.c"
READ_ARGS = "unsigned int fd, char __user **buf_ptr, size_t *count_ptr"


def read_source(path):
    try:
        return path.read_bytes().decode("utf-8")
    except (OSError, UnicodeError) as exc:
        raise AdaptationError(f"cannot read {path}: {exc}") from exc


def code_only(text):
    """Mask comments and string/character literals without changing offsets."""
    pattern = r'//[^\r\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''
    return re.sub(pattern, lambda m: re.sub(r"[^\r\n]", " ", m[0]), text)


def compact(text):
    return re.sub(r"\s+", "", text)


def one_match(pattern, text, label, c_source=True):
    matches = list(re.finditer(pattern, code_only(text) if c_source else text, re.MULTILINE))
    if len(matches) != 1:
        raise AdaptationError(f"{label}: expected exactly one supported match, found {len(matches)}")
    return matches[0]


def check_function(text, name, args, label, expected_count=1):
    pattern = rf"^[ \t]*int\s+{name}\s*\(([^()]*)\)\s*\{{"
    matches = list(re.finditer(pattern, code_only(text), re.MULTILINE))
    wanted = compact(args)
    if sum(compact(m[1]) == wanted for m in matches) != expected_count:
        raise AdaptationError(f"{label}: unsupported definition of {name}")


def validate_nova(ksu_root):
    """Validate definitions, rather than assuming a branch name implies an ABI."""
    kernel = ksu_root / "kernel"
    sucompat = read_source(kernel / "feature/sucompat.c")
    one_match(r"^bool\s+ksu_su_compat_enabled\s+__read_mostly\s*=\s*true\s*;",
              sucompat, "Nova bool definition")
    if re.search(r"DEFINE_STATIC_KEY_\w+\s*\(\s*ksu_su_compat_enabled\s*\)",
                 code_only(sucompat)):
        raise AdaptationError("Nova now exports a static key; this bool adapter must not run")
    check_function(sucompat, "ksu_handle_faccessat",
                   "int *dfd, struct filename **filename, int *mode, int *__unused_flags",
                   "Nova faccessat ABI")
    check_function(sucompat, "ksu_handle_stat", "int *dfd, struct filename **filename, int *flags",
                   "Nova stat ABI")
    check_function(sucompat, "ksu_handle_execveat",
                   "int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags",
                   "Nova execveat ABI", expected_count=2)

    ksud = read_source(kernel / "runtime/ksud.c")
    check_function(ksud, READ_SYMBOL, READ_ARGS, "Nova read ABI")
    for symbol in ("ksu_is_init_rc_hook_enabled", "ksu_is_input_hook_enabled"):
        one_match(rf"DEFINE_STATIC_KEY_TRUE\s*\(\s*{symbol}\s*\)\s*;",
                  ksud, f"Nova {symbol}")
    lsm = read_source(kernel / "hook/lsm_hook.c")
    check_function(lsm, "ksu_handle_setresuid", "uid_t ruid, uid_t euid, uid_t suid",
                   "Nova setresuid ABI")
    kconfig = read_source(kernel / "Kconfig")
    for config in ("KSU_SUSFS", "KSU_SUSFS_PRIORITY_UID_FILTER"):
        one_match(rf"^config[ \t]+{config}[ \t]*\r?$", kconfig, f"Nova {config}", c_source=False)


def apply_replacements(text, replacements):
    for start, end, value in sorted(replacements, reverse=True):
        text = text[:start] + value + text[end:]
    return text


def adapt_bool(text, label):
    declaration = one_match(
        r"\bextern\s+(struct\s+static_key_true|bool)\s+ksu_su_compat_enabled\s*;",
        text, f"{label} bool declaration")
    call = one_match(
        r"\b(?:static_branch_(likely|unlikely)\s*\(\s*&\s*ksu_su_compat_enabled\s*\)"
        r"|(likely|unlikely)\s*\(\s*READ_ONCE\s*\(\s*ksu_su_compat_enabled\s*\)\s*\))",
        text, f"{label} bool read")
    if len(re.findall(r"\bksu_su_compat_enabled\b", code_only(text))) != 2:
        raise AdaptationError(f"{label}: unexpected additional {BOOL_SYMBOL} reference")
    old_declaration = compact(declaration[1]) == "structstatic_key_true"
    old_call = call[1] is not None
    if old_declaration != old_call:
        raise AdaptationError(f"{label}: partially adapted {BOOL_SYMBOL}; refusing mixed ABI")
    if not old_call:
        return text
    return apply_replacements(text, [
        (declaration.start(), declaration.end(), f"extern bool {BOOL_SYMBOL};"),
        (call.start(), call.end(), f"{call[1]}(READ_ONCE({BOOL_SYMBOL}))"),
    ])


def adapt_read(text):
    label = READ_FILE
    declaration = one_match(
        r"\bextern\s+(?:__attribute__\s*\(\(\s*cold\s*\)\)\s+)?"
        r"(void|int)\s+ksu_handle_sys_read\s*\(([^()]*)\)\s*;",
        text, f"{label} read declaration")
    old = declaration[1] == "void" and compact(declaration[2]) == "unsignedintfd"
    new = declaration[1] == "int" and compact(declaration[2]) == compact(READ_ARGS)
    if not (old or new):
        raise AdaptationError(f"{label}: unknown {READ_SYMBOL} declaration")

    # The declaration alone is insufficient: fd, buf and count must refer to
    # this syscall's exact parameter types, not variables in another function.
    syscall = one_match(
        r"\bSYSCALL_DEFINE3\s*\(\s*read\s*,\s*unsigned\s+int\s*,\s*fd\s*,"
        r"\s*char\s+__user\s*\*\s*,\s*buf\s*,\s*size_t\s*,\s*count\s*\)\s*\{",
        text, f"{label} read syscall")
    code = code_only(text)
    start = syscall.end()
    depth = 1
    end = start
    while end < len(code) and depth:
        if code[end] == "{":
            depth += 1
        elif code[end] == "}":
            depth -= 1
        end += 1
    if depth:
        raise AdaptationError(f"{label}: unbalanced read syscall body")
    body = text[start:end - 1]
    call = one_match(
        r"\bksu_handle_sys_read\s*\(\s*(fd(?:\s*,\s*&\s*buf\s*,\s*&\s*count)?)\s*\)",
        body, f"{label} read syscall hook")
    if len(re.findall(r"\bksu_handle_sys_read\b", code)) != 2:
        raise AdaptationError(f"{label}: unexpected additional {READ_SYMBOL} reference")
    if bool(compact(call[1]) == "fd") != old:
        raise AdaptationError(f"{label}: declaration/call ABI mismatch")
    if not old:
        return text
    return apply_replacements(text, [
        (declaration.start(), declaration.end(), f"extern int {READ_SYMBOL}({READ_ARGS});"),
        (start + call.start(), start + call.end(), f"{READ_SYMBOL}(fd, &buf, &count)"),
    ])


def adapt_tree(common, ksu_root, check=False):
    validate_nova(ksu_root)
    planned = {}
    for relative in BOOL_FILES:
        path = common / relative
        old = read_source(path)
        planned[path] = (old, adapt_bool(old, relative))
    path = common / READ_FILE
    old = read_source(path)
    planned[path] = (old, adapt_read(old))
    changes = [path for path, (old, new) in planned.items() if old != new]
    if not check:
        # No writes occur until every file and source ABI has been accepted.
        for path in changes:
            path.write_bytes(planned[path][1].encode("utf-8"))
    return changes


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("common", type=Path, help="patched kernel common directory")
    parser.add_argument("kernelsu", type=Path, help="SukiSU-Nova builtin checkout")
    parser.add_argument("--check", action="store_true", help="validate without changing files")
    args = parser.parse_args(argv)
    try:
        changes = adapt_tree(args.common, args.kernelsu, args.check)
    except AdaptationError as exc:
        print(f"SukiSU-Nova SUSFS ABI check failed: {exc}", file=sys.stderr)
        return 1
    for path in changes:
        print(f"{'Would adapt' if args.check else 'Adapted'}: {path}")
    print(f"SukiSU-Nova SUSFS ABI verified ({len(changes)} file(s) {'pending' if args.check else 'changed'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
