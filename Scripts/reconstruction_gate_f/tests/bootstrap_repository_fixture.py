"""Physical source fixtures for compiler checks, never runnable verifier proof."""
from pathlib import Path
import os
import shutil
import tempfile

from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile, command_templates
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs
from Scripts.lib.work_root import existing_work_root, work_root as macscope_work_root


def bootstrap_repository(test):
    local_root = existing_work_root()
    # Local task storage policy; retain ordinary portable-CI tempfile fallback.
    temp_root = os.environ.get("MACSCOPE_TEST_TEMP_ROOT") or (str(local_root) if local_root else None)
    temporary = tempfile.TemporaryDirectory(prefix="gatef-profile-source-",
                                            dir=temp_root)
    test.addCleanup(temporary.cleanup)
    root = Path(temporary.name).resolve(strict=True)
    paths = {"Scripts/reconstruction_gate_f/command_execution.py"}
    for template in (*command_templates(), *command_templates(profile=CampaignProfile.BOOTSTRAP_VERIFIER)):
        for token in template.argv:
            if token.startswith(("Scripts/", "./Scripts/")):
                paths.add(token.removeprefix("./"))
        if "--only-testing" in template.argv:
            selector = template.argv[template.argv.index("--only-testing") + 1]
            paths.add("MacScope/Tests/CoreTests/" + selector.split("/")[1] + ".swift")
    for relative in sorted(paths):
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, target)
    module = root / "Scripts/reconstruction_gate_f/bootstrap_verifier.py"
    module.write_text("# Synthetic static-compiler existence fixture. Never executed.\n")
    inputs = command_inputs(profile=CampaignProfile.BOOTSTRAP_VERIFIER, repository_root=root)
    return root, inputs
