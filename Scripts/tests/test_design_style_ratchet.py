"""Governance: hard-coded styling outside MacScope/DesignSystem must not grow.

Runs Scripts/design/style_ratchet.py (pure Python, host independent) against the committed
baseline. To accept a burn-down, run `python3 Scripts/design/style_ratchet.py --update` and
commit the lowered Scripts/design/style_baseline.json.

The 2026-10-05 review accepts only the shipped feature additions missing from the
2026-10-03 ledger: patched-byte highlight (a0672d28d, hue plus alpha: two color
hits), the watch expression's existing 240-point field budget (d17a1f5b0, one
frame), the native token-detail sheet's minimum/ideal size (2178b50d1, one frame),
and invalid reconstruction focus feedback (72ed3862f, one color). The two colors
remain tokenization debt, not detector false positives or appearance defects.
The 2026-10-11 REA acceptance retains five existing column/window/text-field
geometry bounds, one 18-point padding and eight existing spacing literals in
REAWorkbenchView; semantic status colors and 12/16-point
padding use existing design tokens. No additional geometry debt is allowed. The same review retains VersionCompareSheet
existing five bounds: 640/820/440/600 dialog geometry, two 240-point search/image
controls, 7-point status glyph and 76-point aligned status column.
No product styling is changed just to reconcile this ledger. All unrelated
ceilings stay unchanged, and additional debt in these categories still fails.
"""
from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RATCHET = REPO / "Scripts" / "design" / "style_ratchet.py"


class DesignStyleRatchetTests(unittest.TestCase):
    def test_hard_coded_styling_does_not_grow(self) -> None:
        result = subprocess.run(
            [sys.executable, str(RATCHET)], cwd=REPO, capture_output=True, text=True, timeout=600
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_reviewed_budget_does_not_allow_additional_or_new_file_debt(self) -> None:
        import json
        import shutil
        import tempfile

        # Run the real checker and audit in an isolated tree, not mocked hit counts.
        # Ignoring an approved file/category ceiling or allowing debt in a new file
        # would make a negative case pass and fail this regression.
        with tempfile.TemporaryDirectory(dir=REPO.parent) as tmp:
            root = Path(tmp)
            design = root / "Scripts" / "design"
            design.mkdir(parents=True)
            for name in ("style_ratchet.py", "style_audit.py"):
                shutil.copyfile(REPO / "Scripts" / "design" / name, design / name)
            (design / "style_baseline.json").write_text(json.dumps({
                "Features/Reviewed.swift": {"color": 1, "frame": 1},
            }))
            features = root / "MacScope" / "Features"
            features.mkdir(parents=True)
            reviewed = features / "Reviewed.swift"
            accepted = 'Text("accepted").foregroundStyle(.red).frame(maxWidth: 240)\n'

            def check() -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [sys.executable, str(design / "style_ratchet.py")],
                    cwd=root, capture_output=True, text=True, timeout=120,
                )

            reviewed.write_text(accepted)
            result = check()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for added, diagnostic in (
                ('Text("new color").foregroundStyle(.blue)\n', "color 1 -> 2"),
                ('Text("new frame").frame(maxWidth: 360)\n', "frame 1 -> 2"),
            ):
                with self.subTest(diagnostic=diagnostic):
                    reviewed.write_text(accepted + added)
                    result = check()
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(diagnostic, result.stdout)

            reviewed.write_text(accepted)
            (features / "Unreviewed.swift").write_text(
                'Text("new file").foregroundStyle(.red)\n'
            )
            result = check()
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("Features/Unreviewed.swift: color 0 -> 1", result.stdout)

    def test_ds_allow_requires_a_reason_and_stays_local(self) -> None:
        import json
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Features").mkdir()
            (root / "Features" / "Lines.swift").write_text(
                "import SwiftUI\n"
                "struct A: View { var body: some View { VStack {\n"
                "    Text(\"a\").foregroundStyle(.red) // ds-allow: demo reason\n"
                "    Text(\"b\").foregroundStyle(.red) // ds-allow:\n"
                "    Text(\"c\").foregroundStyle(.red)\n"
                "} } }\n"
            )
            (root / "Features" / "Whole.swift").write_text(
                "import SwiftUI\n// ds-allow-file: fixed print palette\n"
                "struct B: View { var body: some View { Text(\"d\").foregroundStyle(.red) } }\n"
            )
            (root / "Features" / "Bare.swift").write_text(
                "import SwiftUI\n// ds-allow-file:\n"
                "struct C: View { var body: some View { Text(\"e\").foregroundStyle(.red) } }\n"
            )
            out = root / "audit.json"
            subprocess.run([sys.executable, str(REPO / "Scripts" / "design" / "style_audit.py"), str(root), "--json", str(out)],
                           check=True, capture_output=True, timeout=120)
            hits = [h for h in json.loads(out.read_text())["hits"] if h["cat"] == "color"]
            by_line = {(h["file"], h["line"]): h for h in hits}
            self.assertFalse(by_line[("Features/Lines.swift", 3)]["hard"], "reasoned ds-allow exempts its line")
            self.assertTrue(by_line[("Features/Lines.swift", 4)]["hard"], "ds-allow without a reason does not count")
            self.assertTrue(by_line[("Features/Lines.swift", 5)]["hard"], "exemption does not leak to other lines")
            self.assertFalse(by_line[("Features/Whole.swift", 3)]["hard"], "ds-allow-file exempts its file")
            self.assertTrue(by_line[("Features/Bare.swift", 3)]["hard"],
                            "a reasonless ds-allow-file does not borrow the next line as its reason")

    def test_baseline_is_committed(self) -> None:
        self.assertTrue((REPO / "Scripts" / "design" / "style_baseline.json").is_file())


if __name__ == "__main__":
    unittest.main()
