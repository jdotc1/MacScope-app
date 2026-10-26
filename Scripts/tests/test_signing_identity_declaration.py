#!/usr/bin/env python3
"""Host-independent parity gate for MacScope's permanent signing identity."""

from __future__ import annotations

import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
DECLARATION = ROOT / "MacScope/SigningIdentity.xcconfig"
IDENTITY_ASSIGNMENT = re.compile(r"^MACSCOPE_SIGNING_IDENTITY\s*=\s*(.+)$", re.MULTILINE)
TEAM_ASSIGNMENT = re.compile(r"^MACSCOPE_SIGNING_TEAM\s*=\s*([A-Z0-9]+)$", re.MULTILINE)
APPLE_DEVELOPMENT_LITERAL = re.compile(
    r"Apple Development: [^\"\n]+ \([A-Z0-9]+\)"
)
OU_LITERAL = re.compile(
    r"certificate leaf\[subject\.OU\]\s*=\s*\\?\"([A-Z0-9]+)\\?\""
)

FULL_PEER_REQUIREMENTS = (
    "MacScope/Services/XPC/AnalysisWorkerXPCPeerRequirement.swift",
    "MacScope/Models/NativeDecompilerWire/NativeDecompilerXPCPeerRequirement.swift",
    "MacScope/Plugins/PluginXPCPeerRequirement.swift",
)
CN_INTERMEDIATE_PEER_REQUIREMENTS = (
    "MacScope/Models/Phase2/Phase2ShellBrokerXPCProtocol.swift",
    "MacScope/AIWorkerProtocol/Phase2AIWorkerXPCProtocol.swift",
)
QUALIFICATION_AUTHORITY = (
    ROOT
    / "MacScope/Services/Phase2/QualificationGate/"
    "Phase2QualificationGateBuildAuthority.swift"
)
ALTERNATE_IDENTITY_FIXTURE_FILES = {
    "Scripts/tests/test_debugger_darwin_process_backend.py",
    "Scripts/tests/test_debugger_process_supervisor.py",
    "Scripts/tests/test_debugger_ws18_runtime_bridge.py",
    "Scripts/tests/test_local_signing_policy.py",
}
EXPECTED_IDENTITY_OCCURRENCES = {
    "MacScope/SigningIdentity.xcconfig": 1,
    "MacScope/AIWorkerProtocol/Phase2AIWorkerXPCProtocol.swift": 1,
    "MacScope/Models/NativeDecompilerWire/NativeDecompilerXPCPeerRequirement.swift": 1,
    "MacScope/Models/Phase2/Phase2ShellBrokerXPCProtocol.swift": 1,
    "MacScope/Plugins/PluginXPCPeerRequirement.swift": 1,
    "MacScope/Services/Phase2/QualificationGate/Phase2QualificationGateBuildAuthority.swift": 1,
    "MacScope/Services/XPC/AnalysisWorkerXPCPeerRequirement.swift": 1,
    "MacScope/Tests/CoreTests/AnalysisWorkerXPCPeerRequirementTests.swift": 3,
    "MacScope/Tests/CoreTests/NativeDecompilerLiveXPCTests.swift": 1,
    "MacScope/Tests/CoreTests/NativeDecompilerXPCPeerRequirementTests.swift": 2,
    "MacScope/Tests/Phase2Tests/Phase2AIWorkerWireTests.swift": 2,
    "MacScope/Tests/Phase2Tests/Phase2QualificationGateBuildAuthorityTests.swift": 2,
    "MacScope/Tests/Phase2Tests/Phase2ShellBrokerXPCBoundaryTests.swift": 2,
    "MacScope/Tests/CoreTests/PluginXPCPeerRequirementTests.swift": 2,
    "Scripts/check_local_signing_policy.py": 1,
    "Scripts/debugger-fixture/fixture_tool.py": 1,
    "Scripts/debugger-fixture/ws18_runtime_bridge.py": 1,
    "Scripts/tests/test_debugger_fixture_tool.py": 1,
    "Scripts/tests/test_local_signing_policy.py": 24,
}


def declaration_values() -> tuple[str, str]:
    text = DECLARATION.read_text(encoding="utf-8")
    identity = IDENTITY_ASSIGNMENT.findall(text)
    team = TEAM_ASSIGNMENT.findall(text)
    if len(identity) != 1 or len(team) != 1:
        raise AssertionError("SigningIdentity.xcconfig must have one identity and one team")
    return identity[0].strip(), team[0].strip()


def tracked_non_document_texts() -> list[tuple[str, str]]:
    result = subprocess.run(
        ["/usr/bin/git", "ls-files", "--stage", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    texts: list[tuple[str, str]] = []
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        metadata, raw_path = raw.split(b"\t", 1)
        mode, _object_id, stage = metadata.split()
        if stage != b"0":
            raise AssertionError("signing scan requires an unconflicted Git index")
        if mode in {b"160000", b"120000"}:
            # Gitlinks are separate repositories; symlinks are not source text.
            continue
        if mode not in {b"100644", b"100755"}:
            raise AssertionError(f"unsupported tracked mode for signing scan: {mode!r}")
        relative = raw_path.decode("utf-8")
        if relative.startswith("docs/") or relative.endswith(".md"):
            continue
        path = ROOT
        parts = Path(relative).parts
        for index, part in enumerate(parts):
            path = path / part
            actual_mode = path.lstat().st_mode
            ordinary = stat.S_ISREG(actual_mode) if index == len(parts) - 1 else stat.S_ISDIR(actual_mode)
            if not ordinary:
                raise AssertionError(f"tracked source is not an ordinary symlink-free path: {relative}")
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        texts.append((relative, text))
    return texts


class SigningIdentityDeclarationTests(unittest.TestCase):
    def test_tracked_scan_classifies_gitlinks_and_symlinks_without_losing_blobs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["/usr/bin/git", "init", "-q", str(root)], check=True)
            (root / "source.swift").write_text("ordinary source\n", encoding="utf-8")
            (root / "tool.sh").write_text("executable source\n", encoding="utf-8")
            (root / "tool.sh").chmod(0o755)
            (root / "binary").write_bytes(b"\xff\xfe")
            (root / "README.md").write_text("excluded documentation", encoding="utf-8")
            (root / "linked.swift").symlink_to("source.swift")
            subprocess.run(["/usr/bin/git", "add", "."], cwd=root, check=True)
            subprocess.run(
                ["/usr/bin/git", "update-index", "--add", "--cacheinfo",
                 "160000," + "a" * 40 + ",ThirdParty/Lumen"],
                cwd=root, check=True,
            )
            (root / "ThirdParty/Lumen").mkdir(parents=True)
            (root / "ThirdParty/Lumen/hidden.swift").write_text("not parent source", encoding="utf-8")
            with mock.patch(__name__ + ".ROOT", root):
                self.assertEqual(tracked_non_document_texts(), [
                    ("source.swift", "ordinary source\n"),
                    ("tool.sh", "executable source\n"),
                ])
                (root / "source.swift").unlink()
                (root / "source.swift").symlink_to("tool.sh")
                with self.assertRaisesRegex(AssertionError, "symlink-free"):
                    tracked_non_document_texts()
                (root / "source.swift").unlink()
                (root / "source.swift").mkdir()
                with self.assertRaisesRegex(AssertionError, "ordinary"):
                    tracked_non_document_texts()

    def test_declaration_is_local_apple_development_not_distribution(self) -> None:
        identity, _team = declaration_values()
        self.assertTrue(identity.startswith("Apple Development: "))
        self.assertFalse(identity.startswith("Developer ID Application: "))
        self.assertFalse(identity.startswith("Apple Distribution: "))

    def test_every_tracked_identity_and_ou_literal_matches_the_declaration(self) -> None:
        identity, team = declaration_values()
        observed_identities: list[tuple[str, str]] = []
        observed_teams: list[tuple[str, str]] = []
        for relative, text in tracked_non_document_texts():
            observed_identities.extend(
                (relative, value) for value in APPLE_DEVELOPMENT_LITERAL.findall(text)
            )
            observed_teams.extend((relative, value) for value in OU_LITERAL.findall(text))
        self.assertGreater(len(observed_identities), 10)
        self.assertGreaterEqual(len(observed_teams), 3)
        unexpected_identities = [
            (path, value)
            for path, value in observed_identities
            if value != identity and path not in ALTERNATE_IDENTITY_FIXTURE_FILES
        ]
        self.assertEqual(unexpected_identities, [])
        self.assertEqual(
            [(path, value) for path, value in observed_teams if value != team],
            [],
        )
        for relative, expected_count in EXPECTED_IDENTITY_OCCURRENCES.items():
            with self.subTest(identity_count=relative):
                self.assertEqual(
                    (ROOT / relative).read_text(encoding="utf-8").count(identity),
                    expected_count,
                )

    def test_peer_requirement_security_clauses_remain_present(self) -> None:
        identity, team = declaration_values()
        intermediate = "1[field.1.2.840.113635.100.6.2.1]"
        for relative in FULL_PEER_REQUIREMENTS:
            with self.subTest(file=relative):
                text = (ROOT / relative).read_text(encoding="utf-8")
                self.assertIn("certificate leaf[subject.CN]", text)
                self.assertIn(identity, text)
                self.assertIn("certificate leaf[subject.OU]", text)
                self.assertIn(team, text)
                self.assertIn(intermediate, text)
        for relative in CN_INTERMEDIATE_PEER_REQUIREMENTS:
            with self.subTest(file=relative):
                text = (ROOT / relative).read_text(encoding="utf-8")
                self.assertIn("certificate leaf[subject.CN]", text)
                self.assertIn(identity, text)
                self.assertIn(intermediate, text)

    def test_qualification_gate_constants_match_the_declaration(self) -> None:
        identity, team = declaration_values()
        text = QUALIFICATION_AUTHORITY.read_text(encoding="utf-8")
        self.assertIn(f'approvedTeamIdentifier = "{team}"', text)
        self.assertIn(f'"{identity}"', text)

    def test_project_consumes_only_the_tracked_signing_variables(self) -> None:
        project = (ROOT / "MacScope/project.yml").read_text(encoding="utf-8")
        self.assertIn('DEVELOPMENT_TEAM: "$(MACSCOPE_SIGNING_TEAM)"', project)
        self.assertIn('CODE_SIGN_IDENTITY: "$(MACSCOPE_SIGNING_IDENTITY)"', project)
        identity, team = declaration_values()
        self.assertNotIn(identity, project)
        self.assertNotIn(f"DEVELOPMENT_TEAM: {team}", project)



if __name__ == "__main__":
    unittest.main()
