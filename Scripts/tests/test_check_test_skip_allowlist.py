#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "Scripts/check_test_skip_allowlist.py"
SPEC = importlib.util.spec_from_file_location("check_test_skip_allowlist", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class CheckTestSkipAllowlistTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.tests = self.root / "Tests"
        self.tests.mkdir()
        self.allowlist = self.root / "skip-allowlist.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_swift(self, name: str, body: str) -> None:
        (self.tests / name).write_text(body, encoding="utf-8")

    def write_allowlist(self, entries: list[dict[str, str]]) -> None:
        self.allowlist.write_text(json.dumps({
            "schemaVersion": 2,
            "countingRule": "direct-and-file-local-transitive-swift-test-methods",
            "knownGap": "Cross-file and dynamic calls require Swift semantic information.",
            "entries": entries,
        }), encoding="utf-8")

    def run_gate(self) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = module.main([
                "--tests-root", str(self.tests),
                "--allowlist", str(self.allowlist),
            ])
        return result, stdout.getvalue(), stderr.getvalue()

    def test_added_skip_capable_method_fails(self) -> None:
        self.write_swift("One.swift", "final class One { func testAllowed() throws { throw XCTSkip(\"host\") } }")
        self.write_swift("Two.swift", "final class Two { func testAdded() throws { throw XCTSkip(\"x\") } }")
        self.write_allowlist([{
            "file": "One.swift", "method": "testAllowed", "reason": "Requires a host-only fixture.",
        }])
        result, _, stderr = self.run_gate()
        self.assertEqual(result, 1)
        self.assertIn("testAdded", stderr)

    def test_removed_skip_capable_method_fails_as_stale_entry(self) -> None:
        self.write_swift("One.swift", "final class One { func testFormerlySkipped() {} }")
        self.write_allowlist([{
            "file": "One.swift",
            "method": "testFormerlySkipped",
            "reason": "Previously required a host-only fixture.",
        }])
        result, _, stderr = self.run_gate()
        self.assertEqual(result, 1)
        self.assertIn("stale", stderr)
        self.assertIn("testFormerlySkipped", stderr)

    def test_missing_allowlist_file_skips_check(self) -> None:
        self.write_swift("One.swift", "final class One {}")
        result, stdout, stderr = self.run_gate()
        self.assertEqual(result, 0)
        self.assertEqual(stdout.strip(), "skip allowlist absent; check skipped")
        self.assertEqual(stderr, "")

    def test_matched_allowlist_passes(self) -> None:
        self.write_swift("One.swift", "final class One { func testAllowed() throws { throw XCTSkip(\"host\") } }")
        self.write_allowlist([{
            "file": "One.swift", "method": "testAllowed", "reason": "Requires a host-only fixture.",
        }])
        result, stdout, stderr = self.run_gate()
        self.assertEqual(result, 0, stderr)
        self.assertTrue(json.loads(stdout)["accepted"])

    def test_skip_inside_called_non_test_helper_is_counted_transitively(self) -> None:
        self.write_swift("One.swift", """
            final class One {
                func requireHost() throws { throw XCTSkip("host") }
                func testCallsHelper() throws { try requireHost() }
            }
        """)
        self.write_allowlist([{
            "file": "One.swift",
            "method": "testCallsHelper",
            "reason": "Calls a same-file helper requiring a host fixture.",
        }])
        result, stdout, stderr = self.run_gate()
        self.assertEqual(result, 0, stderr)
        self.assertEqual(json.loads(stdout)["current"], [{
            "file": "One.swift",
            "method": "testCallsHelper",
        }])

    def test_added_transitive_helper_skip_fails_naming_reachable_test(self) -> None:
        self.write_swift("One.swift", """
            final class One {
                func requireHost() throws { throw XCTSkip("host") }
                func prepare() throws { try requireHost() }
                func testNewlySkippable() throws { try prepare() }
            }
        """)
        self.write_allowlist([])
        result, _, stderr = self.run_gate()
        self.assertEqual(result, 1)
        self.assertIn("testNewlySkippable", stderr)

    def test_removed_transitive_helper_skip_makes_entry_stale(self) -> None:
        self.write_swift("One.swift", """
            final class One {
                func requireHost() throws {}
                func testFormerlySkippable() throws { try requireHost() }
            }
        """)
        self.write_allowlist([{
            "file": "One.swift",
            "method": "testFormerlySkippable",
            "reason": "Previously called a same-file host helper.",
        }])
        result, _, stderr = self.run_gate()
        self.assertEqual(result, 1)
        self.assertIn("stale", stderr)
        self.assertIn("testFormerlySkippable", stderr)

    def test_uncalled_helper_skip_does_not_mark_unrelated_test(self) -> None:
        self.write_swift("One.swift", """
            final class One {
                func requireHost() throws { throw XCTSkip("host") }
                func testIndependent() {}
            }
        """)
        self.write_allowlist([])
        result, stdout, stderr = self.run_gate()
        self.assertEqual(result, 0, stderr)
        self.assertEqual(json.loads(stdout)["current"], [])

    def test_reviewed_installed_app_cross_file_guard_is_counted(self) -> None:
        self.write_swift("Installed.swift", """
            final class Installed {
                func testInstalledProduct() throws {
                    _ = try InstalledAppUITestHarness.requireOptedInCandidate()
                }
            }
        """)
        self.write_allowlist([{
            "file": "Installed.swift",
            "method": "testInstalledProduct",
            "reason": "Requires explicit installed-product automation opt-in.",
        }])
        result, stdout, stderr = self.run_gate()
        self.assertEqual(result, 0, stderr)
        self.assertEqual(json.loads(stdout)["current"], [{
            "file": "Installed.swift",
            "method": "testInstalledProduct",
        }])

    def test_reviewed_host_compiler_fixture_is_counted(self) -> None:
        self.write_swift("Host.swift", """
            final class Host {
                func testCompilesAFixture() throws {
                    let url = try HostCompilerFixture.objc("int main(void) { return 0; }")
                    _ = url
                }
                func testUnrelatedObjc() { objc() }
            }
        """)
        self.write_allowlist([{
            "file": "Host.swift",
            "method": "testCompilesAFixture",
            "reason": "Compiles a host fixture with xcrun; skips without the toolchain.",
        }])
        result, stdout, stderr = self.run_gate()
        self.assertEqual(result, 0, stderr)
        self.assertEqual(json.loads(stdout)["current"], [{
            "file": "Host.swift",
            "method": "testCompilesAFixture",
        }])

    def test_unqualified_cross_file_lookalike_is_not_counted(self) -> None:
        self.write_swift("Lookalike.swift", """
            final class Lookalike {
                func testUnrelated() throws { try requireOptedInCandidate() }
            }
        """)
        self.write_allowlist([])
        result, stdout, stderr = self.run_gate()
        self.assertEqual(result, 0, stderr)
        self.assertEqual(json.loads(stdout)["current"], [])

    def test_comments_and_strings_do_not_create_skip_entries(self) -> None:
        self.write_swift("One.swift", '''
            final class One {
                func testMentionsOnly() {
                    // throw XCTSkip("comment")
                    let text = "XCTSkip("
                }
            }
        ''')
        self.write_allowlist([])
        result, _, stderr = self.run_gate()
        self.assertEqual(result, 0, stderr)

    def test_real_repository_matches_committed_allowlist(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = module.main([])
        self.assertEqual(result, 0, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
