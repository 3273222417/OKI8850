"""Regression tests for the SM8850 SukiSU-Nova build path."""

from pathlib import Path
import re
import subprocess
import sys
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


def load_workflow(path):
    return yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def run_step(workflow, needle):
    matches = [step for step in workflow["jobs"]["build"]["steps"]
               if needle in step.get("run", "")]
    if len(matches) != 1:
        raise AssertionError(f"expected one step containing {needle!r}, found {len(matches)}")
    return matches[0]


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.paths = sorted((ROOT / ".github/workflows").glob("fastbuild_6.12*.yml"))
        cls.workflows = [(path, load_workflow(path)) for path in cls.paths]

    def test_seven_workflows_are_covered(self):
        self.assertEqual(7, len(self.workflows))

    def test_checkout_precedes_nova_script(self):
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                steps = workflow["jobs"]["build"]["steps"]
                indexes = [i for i, step in enumerate(steps)
                           if step.get("uses", "").startswith("actions/checkout@")]
                self.assertEqual(1, len(indexes))
                self.assertEqual("false", steps[indexes[0]]["with"]["persist-credentials"])
                self.assertLess(indexes[0], steps.index(run_step(workflow, "scripts/setup_sukisu.sh")))

    def test_nova_and_bakasu_are_distinct(self):
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                options = workflow["on"]["workflow_dispatch"]["inputs"]["ksu_type"]["options"]
                self.assertIn("sukisu", options)
                self.assertIn("bakasu", options)
                run = run_step(workflow, "scripts/setup_sukisu.sh")["run"]
                self.assertIn('if [[ "${{ inputs.ksu_type }}" == "sukisu" ]]', run)
                self.assertIn('elif [[ "${{ inputs.ksu_type }}" == "bakasu" ]]', run)
                nova = run.split('elif [[ "${{ inputs.ksu_type }}" == "bakasu" ]]', 1)[0]
                self.assertNotIn("Baka-SU", nova)
                self.assertIn('"$GITHUB_WORKSPACE/scripts/setup_sukisu.sh"', nova)

    def test_headers_and_build_verification_are_nova_only(self):
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                run = run_step(workflow, "scripts/verify_sukisu_build.sh")["run"]
                self.assertIn("set -euo pipefail", run)
                self.assertIn("O=out headers_install", run)
                self.assertIn("out/usr/include/linux/unistd.h", run)
                self.assertLess(run.index("headers_install"), run.index("O=out Image"))

    def test_manager_and_source_evidence_artifacts_exist(self):
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                steps = workflow["jobs"]["build"]["steps"]
                names = [step.get("with", {}).get("name", "") for step in steps]
                self.assertTrue(any(name.startswith("SukiSU-Nova-Manager-") for name in names))
                self.assertIn("sm8850-sukisu-nova-evidence", names)
                paths = "\n".join(step.get("with", {}).get("path", "") for step in steps)
                self.assertIn("manager-artifacts/*.apk", paths)
                self.assertIn("sukisu-source.txt", paths)


class LocalBuilderTests(unittest.TestCase):
    def test_all_local_builders_route_nova_separately(self):
        builders = sorted((ROOT / "local").glob("builder_6.12*.sh"))
        self.assertEqual(7, len(builders))
        for path in builders:
            with self.subTest(builder=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn('KSU_TYPE="SukiSU-Nova"', text)
                self.assertIn('bash "$SCRIPT_DIR/../scripts/setup_sukisu.sh" "$PWD" "$NOVA_SUSFS"', text)
                self.assertIn('bash "$SCRIPT_DIR/../scripts/apply_sukisu_susfs.sh" "$PWD"', text)
                self.assertIn('O=out headers_install', text)
                self.assertIn('verify_sukisu_build.sh" "$NOVA_SUSFS"', text)
                self.assertRegex(text, r'if \[\[ "\$KSU_BRANCH" == \[yY\] \]\]; then\s+NOVA_SUSFS=false')


class DynamicManagerTests(unittest.TestCase):
    def test_asset_parser_filters_and_prefers_current_release(self):
        page = r'''<script type="application/json">
        {"path":"/shirkneko/sukisu-result/-/releases/download/manager-ci/SukiSU_Nova_v3.0.0-r1_35066-x86_64-release.apk"}
        {"path":"/shirkneko/sukisu-result/-/releases/download/manager-ci/SukiSU_Nova_v3.0.0-r1_35066-arm64-v8a-debug.apk"}
        {"path":"/shirkneko/sukisu-result/-/releases/download/manager-ci/SukiSU_Nova_v3.0.0-r1_35066-arm64-v8a-release.apk"}
        {"path":"/shirkneko/sukisu-result/-/releases/download/manager-ci/SukiSU_Nova_v3.0.0-r1_35066-universal-release.apk"}
        </script>'''
        helper = ROOT / "scripts/extract_manager_assets.py"
        result = subprocess.run(
            [sys.executable, str(helper),
             "https://cnb.cool/shirkneko/sukisu-result/-/releases/tag/manager-ci", "35066"],
            input=page, text=True, capture_output=True, check=True,
        )
        self.assertIn("35066-arm64-v8a-release.apk", result.stdout.splitlines()[0])
        self.assertEqual(2, len(result.stdout.splitlines()))

    def test_script_pairs_manager_to_release_target_without_pinning_ci_version(self):
        script = read("scripts/setup_sukisu.sh")
        self.assertIn('rev-list --count "$manager_target"', script)
        self.assertIn('manager_version" == "$target_version"', script)
        self.assertIn('MAIN_COMMIT="$manager_target"', script)
        self.assertIn('COMMIT="$MAIN_COMMIT"', script)
        self.assertNotRegex(script, r"35\d{3}")
        self.assertIn("SUKISU_CI_MAX_ATTEMPTS", read("scripts/sukisu_sources.env"))

    def test_susfs_patch_path_tracks_android_and_kernel_version(self):
        script = read("scripts/apply_sukisu_susfs.sh")
        self.assertIn('50_add_susfs_in_gki-${ANDROID_VERSION:-android16}-${KERNEL_VERSION:-6.12}.patch', script)
        self.assertIn("--dry-run", script)
        self.assertNotIn("|| true", script)
        self.assertIn("SUKISU_SUSFS_BRANCH=oki-android16-6.12", read("scripts/sukisu_sources.env"))

    def test_patch_selector_accepts_single_612_variant(self):
        patch = r"""diff --git a/fs/proc/task_mmu.c b/fs/proc/task_mmu.c
@@ -1,2 +1,3 @@
 one
 two
 three
@@ -10,5 +11,8 @@ show_smaps_rollup
 /* Case 4 above */
 if (vma->vm_end > last_vma_end) {
+#ifdef CONFIG_KSU_SUSFS_SUS_MAP
+\tif (!vma->vm_file) {
+#endif
\tsmap_gather_stats(vma, &mss, last_vma_end);
\tlast_vma_end = vma->vm_end;
\t}
@@ -20,4 +24,12 @@ show_map_vma
+#ifdef VMA_PAD_START
+\tend = VMA_PAD_START(vma);
+#else
+\tend = vma->vm_end;
+#endif
+#ifdef __VM_NO_COMPAT
+\tif (flags & __VM_NO_COMPAT)
+\t\treturn;
+#endif
"""
        source = """static void
show_map_vma(struct seq_file *m, struct vm_area_struct *vma)
{
\tstart = vma->vm_start;
\tend = VMA_PAD_START(vma);
\tif (flags & __VM_NO_COMPAT)
\t\treturn;
\t__fold_filemap_fixup_entry(&iter, &end);
\tshow_vma_header_prefix(m, start, end, flags, pgoff, dev, ino);
}
"""
        namespace = {
            "__file__": str(ROOT / "scripts/prepare_susfs_patch.py"),
            "__name__": "prepare_susfs_patch_test",
        }
        patch = patch.replace("\\t", "\t")
        source = source.replace("\\t", "\t")
        exec(compile((ROOT / "scripts/prepare_susfs_patch.py").read_text(encoding="utf-8"),
                     namespace["__file__"], "exec"), namespace)
        self.assertIn("Case 4 above", namespace["prepare"](patch, source))


if __name__ == "__main__":
    unittest.main()
