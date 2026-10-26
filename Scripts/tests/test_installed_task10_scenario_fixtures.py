#!/usr/bin/env python3

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[2]
CORE_SUPPORT = (
    ROOT
    / "MacScope"
    / "Tests"
    / "CoreTests"
    / "Task10InstalledScenarioFixtureSupport.swift"
)
GENERATOR = (
    ROOT
    / "MacScope"
    / "Tests"
    / "CoreTests"
    / "Task10InstalledWorkspaceFixtureGeneratorTests.swift"
)
INSTALLED_CATALOG = (
    ROOT
    / "MacScope"
    / "Tests"
    / "MacScopeInstalledAppUITests"
    / "Task10InstalledScenarioFixtureCatalog.swift"
)
PROVIDER = (
    ROOT
    / "MacScope"
    / "Tests"
    / "MacScopeInstalledAppUITests"
    / "InstalledDeterministicLocalAIProvider.swift"
)
INSTALLED_UI_TESTS = (
    ROOT
    / "MacScope"
    / "Tests"
    / "MacScopeInstalledAppUITests"
    / "WS24InstalledAppUITests.swift"
)
ORACLE = (
    ROOT
    / "MacScope"
    / "Tests"
    / "MacScopeInstalledAppUITests"
    / "Fixtures"
    / "Task10InstalledScenarios.fixture.json"
)
SCENARIO_ROOT = ORACLE.parent / "Task10InstalledScenarios"
REQUIRED_SCENARIOS = [
    "active-executing-reads",
    "active-retrieving",
    "checkpoint-stale",
    "navigation-current",
    "navigation-stale",
    "no-job",
    "paused-model-unavailable-awaiting-model",
    "paused-user-retrieving",
    "terminal-completed",
]


def python_provider_source() -> str:
    source = PROVIDER.read_text(encoding="utf-8")
    anchor = 'private static let pythonProvider = #"""\n'
    start = source.find(anchor)
    if start < 0:
        raise AssertionError("the installed provider Python literal is missing")
    start += len(anchor)
    end = source.find('\n"""#', start)
    if end < 0:
        raise AssertionError("the installed provider Python literal is unterminated")
    return source[start:end]


def http_json(origin: str, method: str, path: str, value: object | None = None) -> object:
    data = None
    headers = {"Accept": "application/json"}
    if value is not None:
        data = json.dumps(value, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = Request(origin + path, data=data, headers=headers, method=method)
    with urlopen(request, timeout=3) as response:
        if response.status != 200:
            raise AssertionError(f"unexpected provider status {response.status}")
        return json.loads(response.read().decode("utf-8"))


class InstalledTask10ScenarioFixtureTests(unittest.TestCase):
    def test_destination_switch_fixture_has_the_persisted_editor_selection_it_asserts(self) -> None:
        source = INSTALLED_UI_TESTS.read_text(encoding="utf-8")
        mapping = source.split("var fixtureScenarioID: String {", 1)[1].split(
            "\n    }", 1
        )[0]
        mapping = re.sub(r"//[^\n]*", "", mapping)
        fixture_id = next(
            fixture_id
            for cases, fixture_id in re.findall(
                r'case\s+([^:]+):\s*"([^"]+)"', mapping
            )
            if ".destinationSwitchRestoresEditorAuthority" in cases
        )
        oracle = next(
            row for row in json.loads(ORACLE.read_text())["scenarios"]
            if row["scenarioID"] == fixture_id
        )
        manifest = json.loads(
            (SCENARIO_ROOT / oracle["packageName"] / "manifest.json").read_text()
        )
        self.assertIsInstance(oracle.get("expectedFunctionAddress"), int)
        self.assertEqual(
            oracle["expectedFunctionAddress"], manifest["session"]["selectedAddress"]
        )
        self.assertEqual(oracle["expectedEditorMode"], manifest["session"]["editorMode"])
        selected_binary_id = manifest["session"]["selectedSidebarItemID"].split(":", 1)[1]
        selected_binary = next(
            row for row in manifest["binaries"] if row["id"] == selected_binary_id
        )
        self.assertEqual(oracle["expectedFocusedImageName"], selected_binary["displayName"])

    def test_copied_manifest_identity_changes_only_two_scope_values(self) -> None:
        helper = INSTALLED_CATALOG.with_name("Task10FixtureDocumentIdentity.swift")
        self.assertTrue(helper.is_file(), "per-copy identity isolation helper is missing")
        if shutil.which("xcrun") is None:
            self.skipTest("Swift Foundation behavior test requires macOS Xcode")
        with tempfile.TemporaryDirectory(prefix="task10-identity-", dir=ROOT.parent) as work:
            work = Path(work)
            driver = work / "main.swift"
            driver.write_text(helper.read_text() + '''
let input = FileHandle.standardInput.readDataToEndOfFile()
do {
    let output = try Task10FixtureDocumentIdentity.isolatedManifest(from: input)
    FileHandle.standardOutput.write(output)
} catch { exit(1) }
''')
            executable = work / "identity-test"
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path",
                            str(work / "module-cache"), str(driver), "-o", str(executable)], check=True)
            for row in json.loads(ORACLE.read_text())["scenarios"]:
                original = (SCENARIO_ROOT / row["packageName"] / "manifest.json").read_bytes()
                source = json.loads(original)
                outputs = [subprocess.run([str(executable)], input=original, capture_output=True,
                                          check=True).stdout for _ in range(2)]
                documents, workspaces = set(), set()
                for output in outputs:
                    actual = json.loads(output)
                    documents.add(actual["documentID"])
                    workspaces.add(actual["workspaceUUID"])
                    for key in ("documentID", "workspaceUUID"):
                        self.assertNotEqual(actual[key], source[key])
                        actual[key] = source[key]
                    self.assertEqual(actual, source)
                    restored = output
                    parsed = json.loads(output)
                    for key in ("documentID", "workspaceUUID"):
                        restored = restored.replace(parsed[key].encode(), source[key].encode())
                    self.assertEqual(restored, original, "unrelated manifest bytes changed")
                self.assertEqual(len(documents), 2)
                self.assertEqual(len(workspaces), 2)
            original = (SCENARIO_ROOT / "no-job.mscope" / "manifest.json").read_bytes()
            for invalid in [b"{", original.replace(b'"documentID"', b'"wrongKey"'),
                            original.replace(b'{', b'{"documentID":"10000000-0000-0000-0000-000000000001",', 1),
                            original.replace(b'{', b'{"document\\u0049D":"10000000-0000-0000-0000-000000000001",', 1),
                            original.replace(b'"assistantSessionRecords" : [', b'"assistantSessionRecords" : [ {} ', 1)]:
                result = subprocess.run([str(executable)], input=invalid, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")

    def test_catalog_source_freezes_the_closed_sorted_scenario_set(self) -> None:
        core = CORE_SUPPORT.read_text(encoding="utf-8")
        installed = INSTALLED_CATALOG.read_text(encoding="utf-8")
        raw_values = re.findall(r'^\s*case\s+\w+\s*=\s*"([^"]+)"$', core, re.MULTILINE)
        self.assertEqual(raw_values, REQUIRED_SCENARIOS)
        self.assertEqual(raw_values, sorted(raw_values))
        for scenario in REQUIRED_SCENARIOS:
            self.assertIn(f'"{scenario}"', installed)
        self.assertIn("static let requiredScenarioIDs", installed)
        self.assertIn("scenarioIDs == requiredScenarioIDs", installed)
        for field in (
            "expectedCheckpointFreshness",
            "expectedCorpusOccurrenceCount",
            "expectedCorpusRelationCount",
            "expectedCorpusUniqueContentCount",
            "expectedCorpusUnresolvedRelationCount",
            "expectedCurrentGapOperationID",
            "expectedEvidenceCount",
            "expectedEvidenceCurrentCount",
            "expectedEvidenceHistoricalCount",
            "expectedEvidenceStaleCount",
            "expectedEvidenceUnavailableCount",
            "expectedEditorMode",
            "expectedFocusedImageName",
            "expectedFunctionAddress",
            "expectedGapCount",
            "expectedNavigableEvidenceID",
            "expectedTaskCount",
            "forbiddenRawPathCanary",
            "forbiddenRawPromptCanary",
            "forbiddenRawPseudocodeCanary",
        ):
            self.assertIn(field, installed)
        self.assertNotIn("testTask10C", core + installed)

    def test_rich_scenarios_freeze_real_counts_navigation_and_stale_authority(self) -> None:
        core = CORE_SUPPORT.read_text(encoding="utf-8")
        for fragment in (
            "ReconstructionFunctionCoordinate(",
            "ReconstructionReboundFunctionAuthority.expectedFunctionID",
            "WorkspacePackageAnalysis(",
            "analysisInputFingerprint: inputFingerprint",
            "records: evidence",
            "gaps: [gap]",
            "checkpointRevisionsByID: [firstCheckpointID: 0]",
            "currentCorpusManifestSHA256: currentManifest.canonicalSHA256",
            "rawPromptPrivacyCanary",
            "rawPseudocodePrivacyCanary",
            'reason: .sanitizing("Missing bounded corroboration")',
        ):
            self.assertIn(fragment, core)
        self.assertNotIn("/Users/", core)
        self.assertNotIn("file://", core)
        for canary in (
            "/fixtures/task10-installed.bin",
            "MACSCOPE_TASK10_RAW_PROMPT_CANARY_DO_NOT_EXPOSE",
            "MACSCOPE_TASK10_RAW_PSEUDOCODE_CANARY_DO_NOT_EXPOSE",
        ):
            self.assertIn(canary, core)
        self.assertIn(r"\(rawPromptPrivacyCanary)", core)
        self.assertIn(r"\(rawPseudocodePrivacyCanary)", core)

    def test_generator_uses_production_package_read_and_write_boundaries(self) -> None:
        source = GENERATOR.read_text(encoding="utf-8")
        for fragment in (
            "Task10InstalledScenario.allCases",
            "Task10InstalledScenarioSeedPackage.make(scenario)",
            "WorkspaceStore.restoredPackage(",
            "scheduleDurableRecovery: false",
            "store.writeDocumentPackage(",
            "to: packageURL",
            "MacScopeDocumentPackage.openPackage(from: packageURL)",
            'generator: "WorkspaceStore.restoredPackage/writeDocumentPackage"',
            "oracleRows.map(\\.scenarioID).sorted()",
            "packageTreeSHA256: try packageTreeSHA256(at: packageURL)",
        ):
            self.assertIn(fragment, source)

    def test_navigation_current_fixture_requires_a_distinct_persisted_start_image(self) -> None:
        """Prevent Current Reveal Source from proving a same-image address change instead of focus transfer."""
        core = CORE_SUPPORT.read_text(encoding="utf-8")
        generator = GENERATOR.read_text(encoding="utf-8")
        installed = INSTALLED_CATALOG.read_text(encoding="utf-8")
        for fragment in (
            'private static let startingBinaryID = fixedUUID("10000000-0000-0000-0000-000000000031")',
            "private static let startingImageSlot = ImageSlot(rawValue: 1)",
            'displayName: "Installed starting fixture"',
            "slot: startingImageSlot",
            "binaries: [binary, startingBinary]",
            "focusedImageSlot: startingImageSlot",
            "if scenario == .navigationCurrent",
            "formatVersion: WorkspacePackageManifest.multiImageFormatVersion",
            "expectedStartingImageName",
            "expectedStartingFunctionAddress",
        ):
            self.assertIn(fragment, core)
        for fragment in (
            "expectedStartingImageName: seed.expectedStartingImageName",
            "expectedStartingFunctionAddress: seed.expectedStartingFunctionAddress",
            "XCTAssertEqual(restored.focusedImageSlot, startingBinary.slot)",
            "XCTAssertEqual(restored.selectedAddress, startingAddress)",
            "schemaVersion: 3",
        ):
            self.assertIn(fragment, generator)
        for fragment in (
            "let expectedStartingImageName: String?",
            "let expectedStartingFunctionAddress: UInt64?",
            "catalog.schemaVersion == 3",
            'navigation?.expectedStartingImageName == "Installed starting fixture"',
            "navigation?.expectedStartingFunctionAddress != navigation?.expectedFunctionAddress",
        ):
            self.assertIn(fragment, installed)

    def test_provider_source_is_literal_loopback_pid_owned_and_payload_private(self) -> None:
        swift = PROVIDER.read_text(encoding="utf-8")
        ui_tests = INSTALLED_UI_TESTS.read_text(encoding="utf-8")
        script = python_provider_source()
        for fragment in (
            'ThreadingHTTPServer(("127.0.0.1", 0), Handler)',
            '"/api/v1/models": "discovery"',
            '"/api/v1/models/load": "load"',
            '"/api/v1/models/unload": "unload"',
            '"/v1/chat/completions": "chat"',
            '"body_sha256": hashlib.sha256(body).hexdigest()',
            'atomic_json(summary_path, {"requests": requests})',
        ):
            self.assertIn(fragment, script)
        for fragment in (
            "let ownedPID = process.processIdentifier",
            "ownedPID > 1",
            "process.processIdentifier == ownedPID",
            "stopExactOwnedProcess(process, ownedPID: ownedPID)",
            "process.executableURL = try xcodePythonExecutable()",
            'ProcessInfo.processInfo.environment["DYLD_FRAMEWORK_PATH"]',
            'let developerMarker = "/Contents/Developer/"',
            "func hold(_ route: Route)",
            "func release(_ route: Route)",
            "func waitForRequest(",
        ):
            self.assertIn(fragment, swift)
        for fragment in (
            "try openInstalledSettings(harness: harness, in: app)",
            "app.activate()",
            "app.wait(for: .runningForeground, timeout: 5)",
            'harness.performApplicationMenuCommand(titled: "Settings…")',
        ):
            self.assertIn(fragment, ui_tests)
        harness = (
            ROOT
            / "MacScope"
            / "Tests"
            / "MacScopeInstalledAppUITests"
            / "InstalledAppUITestHarness.swift"
        ).read_text(encoding="utf-8")
        for fragment in (
            "func performApplicationMenuCommand(titled title: String) throws",
            "try assertCandidateIdentityIsUnchanged()",
            'titled: "MacScope"',
            "kAXMenuBarAttribute as CFString",
            "try Self.accessibilityPress(command",
        ):
            self.assertIn(fragment, harness)
        project = (ROOT / "MacScope/project.yml").read_text(encoding="utf-8")
        ui_target = project.split("  MacScopeInstalledAppUITests:", 1)[1].split(
            "schemes:", 1
        )[0]
        self.assertIn("ENABLE_INCOMING_NETWORK_CONNECTIONS: YES", ui_target)
        self.assertNotIn('URL(fileURLWithPath: "/usr/bin/python3")', swift)
        self.assertNotRegex(swift, r"(?i)lm\s*studio")
        self.assertNotIn('("0.0.0.0", 0)', script)
        self.assertNotIn('json.dump(body', script)
        self.assertNotIn('"body": body', script)

    def test_provider_startup_preserves_bounded_owned_diagnostics(self) -> None:
        swift = PROVIDER.read_text(encoding="utf-8")
        for fragment in (
            'maximumStartupDiagnosticBytes = 16 * 1_024',
            'startupDiagnosticName = "provider-startup.log"',
            'attributes: [.posixPermissions: 0o600]',
            'process.standardOutput = diagnosticLog',
            'process.standardError = diagnosticLog',
            'process.terminationStatus',
            'boundedStartupDiagnostics(at: diagnosticLogURL)',
            'Bounded diagnostics were preserved at',
        ):
            self.assertIn(fragment, swift)
        self.assertNotIn("process.standardOutput = Pipe()", swift)
        self.assertNotIn("process.standardError = Pipe()", swift)

        start = swift.index("static func start(")
        hold = swift.index("    func hold(", start)
        startup = swift[start:hold]
        self.assertNotIn("removeItem(at: rootURL)", startup)

    def test_loopback_provider_exercises_discovery_lifecycle_chat_and_hold_release(self) -> None:
        with tempfile.TemporaryDirectory(prefix="macscope-installed-provider-test-") as temporary:
            root = Path(temporary)
            (root / "control").mkdir()
            script_path = root / "provider.py"
            script_path.write_text(python_provider_source(), encoding="utf-8")
            process = subprocess.Popen(
                [
                    "/usr/bin/python3",
                    "-B",
                    str(script_path),
                    str(root),
                    "task10-installed-model",
                    "Task 10 Deterministic Model",
                    "MacScope Tests",
                    "task10-installed-instance",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env={
                    "LANG": "C.UTF-8",
                    "PATH": "/usr/bin:/bin",
                    "PYTHONDONTWRITEBYTECODE": "1",
                },
            )
            self.assertGreater(process.pid, 1)
            try:
                port_path = root / "port.json"
                deadline = time.monotonic() + 3
                while not port_path.exists() and time.monotonic() < deadline:
                    if process.poll() is not None:
                        stdout, stderr = process.communicate()
                        self.fail(f"provider exited early: {stdout!r} {stderr!r}")
                    time.sleep(0.01)
                port = json.loads(port_path.read_text(encoding="utf-8"))["port"]
                origin = f"http://127.0.0.1:{port}"

                catalog = http_json(origin, "GET", "/api/v1/models")
                self.assertEqual(catalog["models"][0]["key"], "task10-installed-model")
                loaded = http_json(
                    origin,
                    "POST",
                    "/api/v1/models/load",
                    {"model": "task10-installed-model", "context_length": 4096},
                )
                self.assertEqual(loaded["instance_id"], "task10-installed-instance")
                loaded_catalog = http_json(origin, "GET", "/api/v1/models")
                self.assertEqual(
                    loaded_catalog["models"][0]["loaded_instances"],
                    [{"id": "task10-installed-instance", "config": {"context_length": 4096}}],
                )

                hold = root / "control" / "hold-chat"
                hold.write_bytes(b"")
                request_value = {
                    "jobID": "10000000-0000-0000-0000-000000000006",
                    "checkpointRevision": 1,
                    "roundID": "10000000-0000-0000-0000-000000000009",
                    "handles": [{"handleID": "10000000-0000-0000-0000-000000000010"}],
                }
                chat_request = {
                    "model": "task10-installed-model",
                    "messages": [
                        {"role": "system", "content": "fixture"},
                        {"role": "user", "content": json.dumps(request_value)},
                    ],
                    "tools": [{"type": "function", "function": {"name": "fixture"}}],
                    "response_format": {"type": "json_object"},
                }
                with ThreadPoolExecutor(max_workers=1) as executor:
                    future = executor.submit(
                        http_json,
                        origin,
                        "POST",
                        "/v1/chat/completions",
                        chat_request,
                    )
                    summary_path = root / "request-summary.json"
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        requests = json.loads(summary_path.read_text(encoding="utf-8"))["requests"]
                        if any(item["path"] == "/v1/chat/completions" for item in requests):
                            break
                        time.sleep(0.01)
                    self.assertFalse(future.done(), "the deterministic chat hold must block reply")
                    hold.unlink()
                    chat = future.result(timeout=3)
                content = json.loads(chat["choices"][0]["message"]["content"])
                self.assertEqual(content["job_id"], request_value["jobID"])
                self.assertEqual(content["round_id"], request_value["roundID"])

                unloaded = http_json(
                    origin,
                    "POST",
                    "/api/v1/models/unload",
                    {"instance_id": "task10-installed-instance"},
                )
                self.assertEqual(unloaded["instance_id"], "task10-installed-instance")
                requests = json.loads(
                    (root / "request-summary.json").read_text(encoding="utf-8")
                )["requests"]
                self.assertEqual(
                    [item["path"] for item in requests],
                    [
                        "/api/v1/models",
                        "/api/v1/models/load",
                        "/api/v1/models",
                        "/v1/chat/completions",
                        "/api/v1/models/unload",
                    ],
                )
                self.assertTrue(
                    all(
                        set(item) == {
                            "body_bytes",
                            "body_sha256",
                            "method",
                            "path",
                            "sequence",
                        }
                        for item in requests
                    )
                )
                for item in requests:
                    self.assertRegex(item["body_sha256"], r"^[0-9a-f]{64}$")
            finally:
                if process.poll() is None:
                    process.terminate()
                process.communicate(timeout=3)

    def test_generated_oracle_is_sorted_and_matches_every_package_tree(self) -> None:
        catalog = json.loads(ORACLE.read_text(encoding="utf-8"))
        self.assertEqual(catalog["schemaVersion"], 3)
        self.assertEqual(
            catalog["generator"],
            "WorkspaceStore.restoredPackage/writeDocumentPackage",
        )
        self.assertEqual(
            [row["scenarioID"] for row in catalog["scenarios"]],
            REQUIRED_SCENARIOS,
        )
        self.assertEqual(
            set(catalog["provider"]),
            {"displayName", "instanceID", "modelKey", "publisher"},
        )
        expected_presentation = {
            "active-executing-reads": (3, 0, 0, "current", None, None),
            "active-retrieving": (3, 0, 0, "current", None, None),
            "checkpoint-stale": (1, 13, 1, "stale", None, None),
            "navigation-current": (
                1,
                13,
                1,
                "current",
                "10000000-0000-0000-0000-000000000030",
                0x1_0000_0000,
            ),
            "navigation-stale": (1, 13, 1, "current", None, 0x1_0000_0000),
            "no-job": (0, 0, 0, None, None, None),
            "paused-model-unavailable-awaiting-model": (
                3,
                0,
                0,
                "current",
                None,
                None,
            ),
            "paused-user-retrieving": (3, 0, 0, "current", None, None),
            "terminal-completed": (0, 0, 0, "current", None, None),
        }
        for row in catalog["scenarios"]:
            expected = expected_presentation[row["scenarioID"]]
            self.assertEqual(row["expectedTaskCount"], expected[0])
            self.assertEqual(row["expectedEvidenceCount"], expected[1])
            self.assertEqual(row["expectedGapCount"], expected[2])
            self.assertEqual(row.get("expectedCheckpointFreshness"), expected[3])
            self.assertEqual(row.get("expectedNavigableEvidenceID"), expected[4])
            self.assertEqual(row.get("expectedFunctionAddress"), expected[5])
            self.assertEqual(
                row["expectedEvidenceCount"],
                row["expectedEvidenceCurrentCount"]
                + row["expectedEvidenceHistoricalCount"]
                + row["expectedEvidenceStaleCount"]
                + row["expectedEvidenceUnavailableCount"],
            )
            package = SCENARIO_ROOT / row["packageName"]
            self.assertTrue(package.is_dir(), row["scenarioID"])
            package_entries = list(package.rglob("*"))
            self.assertFalse(
                any(entry.is_symlink() for entry in package_entries),
                f"{row['scenarioID']} fixture package must not contain a symlink",
            )
            digest = hashlib.sha256()
            for file_path in sorted(path for path in package_entries if path.is_file()):
                relative = file_path.relative_to(package).as_posix()
                digest.update(relative.encode("utf-8"))
                digest.update(b"\0")
                digest.update(file_path.read_bytes())
                digest.update(b"\0")
            self.assertEqual(digest.hexdigest(), row["packageTreeSHA256"])

            manifest = json.loads((package / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["formatVersion"], 3)
            binary_slots = {
                binary["id"]: binary.get("slot", 0) for binary in manifest["binaries"]
            }
            self.assertEqual(len(binary_slots), len(manifest["binaries"]))
            self.assertEqual(
                set(binary_slots),
                {analysis["binaryID"] for analysis in manifest["imageAnalyses"]},
                row["scenarioID"],
            )
            analysis_slots = {
                analysis["binaryID"]: analysis["imageSlot"]
                for analysis in manifest["imageAnalyses"]
            }
            self.assertEqual(binary_slots, analysis_slots, row["scenarioID"])
            for binary in manifest["binaries"]:
                relative = PurePosixPath(binary["attachmentRelativePath"])
                self.assertFalse(relative.is_absolute(), row["scenarioID"])
                self.assertNotIn("..", relative.parts, row["scenarioID"])
                attachment = package.joinpath(*relative.parts)
                self.assertTrue(attachment.is_file(), binary["attachmentRelativePath"])
                self.assertFalse(attachment.is_symlink(), binary["attachmentRelativePath"])
                attachment_bytes = attachment.read_bytes()
                self.assertEqual(len(attachment_bytes), binary["fileSize"])
                self.assertEqual(
                    hashlib.sha256(attachment_bytes).hexdigest(), binary["fileHash"]
                )

            session = manifest["session"]
            selected_item = session["selectedSidebarItemID"]
            self.assertIsInstance(selected_item, str)
            self.assertTrue(selected_item)
            if row["scenarioID"] == "navigation-current":
                self.assertEqual(len(manifest["binaries"]), 2)
                self.assertEqual(len(manifest["imageAnalyses"]), 2)
                self.assertEqual(manifest["session"]["focusedImageSlot"], 1)
            else:
                self.assertEqual(len(manifest["binaries"]), 1, row["scenarioID"])
                self.assertEqual(len(manifest["imageAnalyses"]), 1, row["scenarioID"])
                self.assertNotIn("focusedImageSlot", manifest["session"], row["scenarioID"])
                self.assertEqual(selected_item, f"binary:{manifest['binaries'][0]['id']}")

        navigation = next(
            row for row in catalog["scenarios"] if row["scenarioID"] == "navigation-current"
        )
        self.assertEqual(
            navigation["expectedStartingImageName"],
            "Installed starting fixture",
        )
        self.assertEqual(navigation["expectedStartingFunctionAddress"], 0x1_0000_1000)
        self.assertNotEqual(
            navigation["expectedStartingFunctionAddress"],
            navigation["expectedFunctionAddress"],
        )
        navigation_package = SCENARIO_ROOT / navigation["packageName"]
        manifest = json.loads((navigation_package / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["formatVersion"], 3)
        self.assertEqual(
            [binary["displayName"] for binary in manifest["binaries"]],
            ["Installed fixture", "Installed starting fixture"],
        )
        self.assertEqual(
            [analysis["imageSlot"] for analysis in manifest["imageAnalyses"]],
            [0, 1],
        )
        self.assertEqual(manifest["session"]["focusedImageSlot"], 1)
        self.assertEqual(
            manifest["session"]["selectedAddress"],
            navigation["expectedStartingFunctionAddress"],
        )
        analyses_by_slot = {
            analysis["imageSlot"]: analysis["analysis"]
            for analysis in manifest["imageAnalyses"]
        }
        target_function = next(
            function
            for function in analyses_by_slot[0]["functions"]
            if function["startAddress"] == navigation["expectedFunctionAddress"]
        )
        starting_function = next(
            function
            for function in analyses_by_slot[1]["functions"]
            if function["startAddress"] == navigation["expectedStartingFunctionAddress"]
        )
        self.assertNotEqual(target_function["id"], starting_function["id"])
        self.assertEqual(
            manifest["session"]["selectedSidebarItemID"],
            f"function:{starting_function['id']}",
        )
        self.assertEqual(
            [
                navigation["expectedCorpusOccurrenceCount"],
                navigation["expectedCorpusUniqueContentCount"],
                navigation["expectedCorpusRelationCount"],
                navigation["expectedCorpusUnresolvedRelationCount"],
            ],
            [7, 5, 3, 2],
        )
        self.assertEqual(
            [
                navigation["expectedEvidenceCurrentCount"],
                navigation["expectedEvidenceHistoricalCount"],
                navigation["expectedEvidenceStaleCount"],
                navigation["expectedEvidenceUnavailableCount"],
            ],
            [4, 3, 3, 3],
        )
        self.assertEqual(
            navigation["expectedCurrentGapOperationID"],
            "reconstruction.evidence.query",
        )
        self.assertEqual(navigation["expectedFocusedImageName"], "Installed fixture")
        self.assertEqual(navigation["expectedEditorMode"], "Disassembly")
        self.assertEqual(
            [
                navigation["forbiddenRawPathCanary"],
                navigation["forbiddenRawPromptCanary"],
                navigation["forbiddenRawPseudocodeCanary"],
            ],
            [
                "/fixtures/task10-installed.bin",
                "MACSCOPE_TASK10_RAW_PROMPT_CANARY_DO_NOT_EXPOSE",
                "MACSCOPE_TASK10_RAW_PSEUDOCODE_CANARY_DO_NOT_EXPOSE",
            ],
        )


if __name__ == "__main__":
    unittest.main()
