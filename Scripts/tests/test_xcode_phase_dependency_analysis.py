from __future__ import annotations

import json
import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = ROOT / "MacScope/project.yml"


class XcodePhaseDependencyAnalysisContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        result = subprocess.run(
            [
                "/usr/bin/ruby",
                "-ryaml",
                "-rjson",
                "-e",
                (
                    "value=YAML.safe_load(File.read(ARGV.fetch(0)), "
                    "permitted_classes: [], aliases: false); "
                    "STDOUT.write(JSON.generate(value))"
                ),
                str(PROJECT),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        cls.project = json.loads(result.stdout)

    def phase(
        self,
        target_name: str,
        collection: str,
        phase_name: str,
    ) -> dict[str, object]:
        target = self.project["targets"][target_name]
        matches = [
            phase
            for phase in target.get(collection, [])
            if phase.get("name") == phase_name
        ]
        self.assertEqual(len(matches), 1, (target_name, collection, phase_name))
        return matches[0]

    def assert_incremental_phase(
        self,
        *,
        target_name: str,
        collection: str,
        phase_name: str,
        input_files: list[str],
        output_files: list[str],
    ) -> None:
        phase = self.phase(target_name, collection, phase_name)
        self.assertIs(phase.get("basedOnDependencyAnalysis"), True)
        self.assertEqual(phase.get("inputFiles"), input_files)
        self.assertEqual(phase.get("outputFiles"), output_files)

    def test_ghostty_surface_staging_has_complete_incremental_graph(self) -> None:
        self.assert_incremental_phase(
            target_name="MacScopeApp",
            collection="preBuildScripts",
            phase_name="Stage verified Ghostty surface build inputs",
            input_files=[
                "$(SRCROOT)/../Scripts/dependencies/stage_verified_ghostty_surface.py",
                "$(MACSCOPE_GHOSTTY_SURFACE_MANIFEST)",
                "$(MACSCOPE_GHOSTTY_SURFACE_INPUT_ARCHIVE)",
                "$(MACSCOPE_GHOSTTY_SURFACE_INPUT_HEADER)",
                "$(MACSCOPE_GHOSTTY_SURFACE_INPUT_MODULE_MAP)",
            ],
            output_files=[
                "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_DESCRIPTOR)",
                "$(MACSCOPE_GHOSTTY_SURFACE_ARCHIVE)",
                "$(MACSCOPE_GHOSTTY_SURFACE_HEADER)",
                "$(MACSCOPE_GHOSTTY_SURFACE_MODULE_MAP)",
            ],
        )

    def test_shell_broker_launch_agent_staging_has_complete_incremental_graph(
        self,
    ) -> None:
        self.assert_incremental_phase(
            target_name="MacScopeApp",
            collection="postBuildScripts",
            phase_name="Stage ShellBroker LaunchAgent property list",
            input_files=[
                "$(SRCROOT)/ShellBrokerService/LaunchAgent.plist",
                "$(BUILT_PRODUCTS_DIR)/ShellBrokerLaunchAgent",
            ],
            output_files=[
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/org.macscope.app.ShellBroker.agent.plist",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/MacOS/ShellBrokerLaunchAgent",
            ],
        )

    def test_coretests_oracle_resources_have_complete_incremental_graph(self) -> None:
        self.assert_incremental_phase(
            target_name="CoreTests",
            collection="preBuildScripts",
            phase_name="Stage call-argument oracle test resources",
            input_files=[
                "$(SRCROOT)/../Scripts/decompiler-oracles/call_argument_oracle.py",
                "$(SRCROOT)/../Scripts/decompiler-oracles/fixtures/call-arguments/call_arguments.c",
                "$(SRCROOT)/../Scripts/decompiler-oracles/fixtures/call-arguments/entry_capture.s",
                "$(SRCROOT)/../Scripts/decompiler-oracles/fixtures/call-arguments/objc_call_arguments.m",
            ],
            output_files=[
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/call_argument_oracle.py",
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/call-arguments/call_arguments.c",
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/call-arguments/entry_capture.s",
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/call-arguments/objc_call_arguments.m",
            ],
        )

    def test_coretests_provenance_copy_has_complete_incremental_graph(self) -> None:
        self.assert_incremental_phase(
            target_name="CoreTests",
            collection="postBuildScripts",
            phase_name="Copy sealed provenance into CoreTests",
            input_files=[
                "$(BUILT_PRODUCTS_DIR)/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json",
            ],
            output_files=[
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/MacScopeBuildProvenance.json",
            ],
        )


if __name__ == "__main__":
    unittest.main()
