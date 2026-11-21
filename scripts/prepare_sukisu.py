#!/usr/bin/env python3
"""Wire a reviewed Nova checkout into an OKI source tree, without running setup.sh."""

import argparse
import re
from pathlib import Path


def set_config(text, name, value):
    text = re.sub(rf"^(?:{name}=.*|# {name} is not set)\n?", "", text, flags=re.M)
    line = f"# {name} is not set" if value == "n" else f"{name}={value}"
    return text.rstrip("\n") + "\n" + line + "\n"


def prepare(workspace, susfs, version, count, ref, tag):
    common = workspace / "common"
    kernel = workspace / "KernelSU" / "kernel"
    build = kernel / ("Makefile" if susfs else "Kbuild")
    config = common / "arch/arm64/configs/gki_defconfig"
    makefile = common / "drivers/Makefile"
    kconfig = common / "drivers/Kconfig"
    for path in (build, kernel / "Kconfig", config, makefile, kconfig):
        if not path.is_file():
            raise ValueError(f"required source file missing: {path}")
    source = build.read_text(encoding="utf-8")
    if not re.search(r"^KSU_PACKAGE_NAME\s*\?=\s*com\.sukisu\.nova$", source, re.M):
        raise ValueError("checkout is not the expected SukiSU-Nova source")
    if susfs and not re.search(r"^config KSU_SUSFS$", (kernel / "Kconfig").read_text(), re.M):
        raise ValueError("SUSFS requires the Nova builtin source, not main")

    # Keep the actual checked-out source SHA in KSU_VERSION_FULL. Resolve the
    # version once from the complete current main history (also used by Nova's manager),
    # never from BakaSU's +30700 formula or live HTTP calls during make.
    replacements = {
        "REPO_BRANCH": ref,
        "LOCAL_COUNT": str(count),
        "KSU_VERSION": str(version),
        "VERSION_TAG": tag,
    }
    for key, value in replacements.items():
        source, hits = re.subn(rf"^{key}\s*:=.*$", f"{key} := {value}", source, flags=re.M)
        if hits != 1:
            raise ValueError(f"expected one {key} assignment in {build}, found {hits}")
    # Use stable branding instead of exposing detached-checkout metadata such
    # as @HEAD/@builtin in the manager's full-version display.
    full_version_line = "KSU_VERSION_FULL := v$(VERSION_TAG)-by.贝利亚大王"
    source, hits = re.subn(
        r"^KSU_VERSION_FULL\s*:=.*$",
        full_version_line,
        source,
        flags=re.M,
    )
    if hits != 1:
        raise ValueError(f"expected one KSU_VERSION_FULL assignment in {build}, found {hits}")
    for key in ("KSU_RELEASE_VER", "RELEASE_COMMITS", "KSU_GITHUB_VER", "GITHUB_COMMITS"):
        source = re.sub(rf"^{key}\s*:=.*$", f"{key} :=", source, flags=re.M)
    source = "\n".join(line for line in source.split("\n") if "fetch --unshallow" not in line)

    driver_make = makefile.read_text(encoding="utf-8")
    driver_config = kconfig.read_text(encoding="utf-8")
    make_line = "obj-$(CONFIG_KSU) += kernelsu/"
    config_line = 'source "drivers/kernelsu/Kconfig"'
    if make_line not in driver_make:
        if "kernelsu/" in driver_make:
            raise ValueError("conflicting KernelSU Makefile integration")
        driver_make = driver_make.rstrip("\n") + "\n" + make_line + "\n"
    if config_line not in driver_config:
        if 'drivers/kernelsu/' in driver_config:
            raise ValueError("conflicting KernelSU Kconfig integration")
        pos = driver_config.rfind("endmenu")
        if pos < 0:
            raise ValueError("drivers/Kconfig has no endmenu")
        driver_config = driver_config[:pos] + config_line + "\n" + driver_config[pos:]

    link = common / "drivers/kernelsu"
    if link.is_symlink():
        if link.resolve() != kernel.resolve():
            raise ValueError("drivers/kernelsu points to a different source tree")
    elif link.exists():
        raise ValueError("drivers/kernelsu exists and is not a symlink; refusing to replace it")

    defconfig = config.read_text(encoding="utf-8")
    for key, value in {
        "CONFIG_KSU": "y",
        "CONFIG_KSU_SUSFS": "y" if susfs else "n",
        "CONFIG_KPM": "n",  # kpm_enable selects the independent KPatch-Next path.
        "CONFIG_HEADERS_INSTALL": "y",  # Nova preinit/runner requires installed UAPI headers.
    }.items():
        defconfig = set_config(defconfig, key, value)

    if not link.is_symlink():
        link.symlink_to("../../KernelSU/kernel", target_is_directory=True)
    for path, text in ((build, source), (config, defconfig), (makefile, driver_make), (kconfig, driver_config)):
        path.write_text(text, encoding="utf-8", newline="\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    parser.add_argument("--susfs", choices=("true", "false"), required=True)
    parser.add_argument("--version", type=int, required=True)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    if args.version <= 30000 or args.count <= 0:
        parser.error("version/count must come from complete main history")
    if not re.fullmatch(r"[0-9a-f]{40}", args.ref) or not re.fullmatch(r"[0-9A-Za-z._+-]+", args.tag):
        parser.error("invalid version reference/tag")
    try:
        prepare(args.workspace.resolve(), args.susfs == "true", args.version, args.count, args.ref, args.tag)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"SukiSU-Nova integration failed: {exc}\n")


if __name__ == "__main__":
    main()
