"""The qualifier's generated-project allowlist tracks the schemes project.yml declares (#378 → #386)."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts/qualification"))
import restore_build_source  # noqa: E402

CHECK = ROOT / "Scripts/qualification/check_generated_project.py"


def declared_schemes() -> set[str]:
    text = (ROOT / "MacScope/project.yml").read_text(encoding="utf-8")
    section = re.search(r"(?ms)^schemes:\n(.*?)(?=^\S|\Z)", text).group(1)
    return set(re.findall(r"(?m)^  ([A-Za-z0-9_][A-Za-z0-9_-]*):\s*$", section))


class GeneratedProjectGuardTests(unittest.TestCase):
    def test_allowlisted_schemes_equal_the_declared_schemes(self) -> None:
        allowlisted = {Path(path).stem for path in restore_build_source.GENERATED_PROJECT_FILES
                       if path.startswith("xcshareddata/xcschemes/")}
        self.assertEqual(allowlisted, declared_schemes())

    def fixture(self, root: Path, extra: str | None = None) -> Path:
        project = root / "MacScope.xcodeproj"
        for directory in restore_build_source.GENERATED_PROJECT_DIRECTORIES:
            (project / directory).mkdir(parents=True, exist_ok=True)
        for file in restore_build_source.GENERATED_PROJECT_FILES:
            (project / file).write_text("x", encoding="utf-8")
        if extra:
            (project / extra).write_text("x", encoding="utf-8")
        return project

    def run_check(self, project: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, "-B", str(CHECK), str(project)], capture_output=True, text=True)

    def test_check_accepts_the_allowlist_and_names_an_unexpected_scheme(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(self.run_check(self.fixture(Path(directory))).returncode, 0)
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_check(self.fixture(Path(directory), "xcshareddata/xcschemes/NewBundle.xcscheme"))
            self.assertEqual(result.returncode, 4, result.stderr)
            self.assertIn("xcshareddata/xcschemes/NewBundle.xcscheme", result.stderr)

    def test_dev_loop_runs_the_check_after_project_generation(self) -> None:
        script = (ROOT / "Scripts/dev_loop.sh").read_text(encoding="utf-8")
        self.assertLess(script.index('build_and_run.sh" --prepare'), script.index("check_generated_project.py\" \"${XCODEPROJ}\""))
        self.assertLess(script.index("check_generated_project.py\" \"${XCODEPROJ}\""), script.index("build-for-testing ||"))


if __name__ == "__main__":
    unittest.main()
