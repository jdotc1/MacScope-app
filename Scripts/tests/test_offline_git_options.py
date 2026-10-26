"""Bounded Git global-option detector regressions."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dependencies"))
from validate_offline_build_surface import (
    NETWORK_COMMAND_PATTERNS, NORMAL_ENTRYPOINTS, EXPLICIT_QUALIFICATION_ENTRYPOINTS, _matching_labels,
)


class OfflineGitOptionsTests(unittest.TestCase):
    def assertNetwork(self, text):
        self.assertIn("git network operation", _matching_labels(text, NETWORK_COMMAND_PATTERNS), text)

    def assertLocal(self, text):
        self.assertNotIn("git network operation", _matching_labels(text, NETWORK_COMMAND_PATTERNS), text)

    def test_separated_C_network_verbs(self):
        for verb in ("clone URL", "fetch origin", "pull origin", "submodule add URL", "submodule update"):
            with self.subTest(verb=verb):
                self.assertNetwork("git -C repo " + verb)

    def test_attached_C_network_verbs(self):
        for verb in ("clone URL", "fetch origin", "pull", "submodule add URL", "submodule update"):
            with self.subTest(verb=verb):
                self.assertNetwork("git -Crepo " + verb)

    def test_separated_c_network_verbs(self):
        for verb in ("clone URL", "fetch", "pull", "submodule add URL", "submodule update"):
            with self.subTest(verb=verb):
                self.assertNetwork("git -c core.quotePath=false " + verb)

    def test_attached_c_network_verbs(self):
        for verb in ("clone URL", "fetch", "pull", "submodule add URL", "submodule update"):
            with self.subTest(verb=verb):
                self.assertNetwork("git -ccore.quotePath=false " + verb)

    def test_git_dir_forms(self):
        for option in ("--git-dir repo.git", "--git-dir=repo.git", "--git-dir 'repo space.git'"):
            with self.subTest(option=option):
                self.assertNetwork("git " + option + " fetch origin")
                self.assertLocal("git " + option + " status")

    def test_work_tree_forms(self):
        for option in ("--work-tree repo", "--work-tree=repo", '--work-tree "repo space"'):
            with self.subTest(option=option):
                self.assertNetwork("git " + option + " pull origin")
                self.assertLocal("git " + option + " diff")

    def test_repeated_mixed_global_options(self):
        prefix = "git -C repo -ccore.quotePath=false --git-dir=repo.git --work-tree tree "
        self.assertNetwork(prefix + "fetch origin")
        self.assertLocal(prefix + "diff --stat")

    def test_literal_quoted_paths_and_git_command(self):
        for command in ('"git"', "'/usr/bin/git'", '"/bin/git"'):
            with self.subTest(command=command):
                self.assertNetwork(command + " -C 'repo space' fetch origin")
                self.assertLocal(command + ' -C "repo space" status')

    def test_command_boundaries(self):
        for prefix in ("", "true; ", "true && ", "false || ", "producer | ", "true\n"):
            with self.subTest(prefix=prefix):
                self.assertNetwork(prefix + "git -C repo fetch origin")
        self.assertNetwork('ROOT="$(git -C repo fetch origin)"')
        self.assertLocal('ROOT="$(git -C repo rev-parse HEAD)"')
        self.assertLocal("# git -C repo fetch origin\ngit -C repo status")
        # More nested contexts than the depth/pending budget must never recurse.
        unrelated = '"$(' * 1000 + "plain text" + ')"' * 1000
        prefixed = '"$(' * 1000 + "git -C repo fetch origin" + ')"' * 1000
        self.assertLocal(unrelated)
        self.assertNetwork(prefixed)
        self.assertLocal("# " + prefixed)
        # Exceed the aggregate text budget without a Git option prefix.
        self.assertLocal("x" * (8 * 1024 * 1024 + 1))

    def test_local_status_and_diff_with_supported_options(self):
        for option in ("-C repo", "-Crepo", "-c core.quotePath=false", "-ccore.quotePath=false",
                       "--git-dir repo.git", "--git-dir=repo.git", "--work-tree repo", "--work-tree=repo"):
            for verb in ("status", "diff"):
                with self.subTest(option=option, verb=verb):
                    self.assertLocal("git " + option + " " + verb)
        self.assertLocal("echo git rev-parse HEAD")
        self.assertLocal("git rev-parse HEAD")
        self.assertLocal("git -C repo custom-command")

    def test_unknown_global_option_refuses(self):
        for prefix in ("--unknown", "--", "--unknown-pager", "-z", "-C repo --unknown"):
            with self.subTest(prefix=prefix):
                self.assertNetwork("git " + prefix + " status")

    def test_missing_or_empty_option_value_refuses(self):
        for text in ("git -C", "git -c", "git --git-dir", "git --work-tree",
                     "git -C '' status", "git --git-dir= status", "git --work-tree= diff",
                     "git -c '=value' status", "git -c key status", "git -C ; git status"):
            with self.subTest(text=text):
                self.assertNetwork(text)

    def test_variable_or_substitution_prefix_refuses(self):
        for prefix in ('$options', '"$options"', '-C "${repo:-fallback}"', '-C "$(pwd)"', '-C `pwd`',
                       "-C '$repo'", "-C repo $options"):
            with self.subTest(prefix=prefix):
                self.assertNetwork("git " + prefix + " status")

    def test_unclosed_or_concatenated_quote_refuses(self):
        for text in ("git -C 'repo", "git -C re'po' status", "git '-C' repo status",
                     'git -Cre"po space" status', "git -C repo \\\nstatus"):
            with self.subTest(text=text):
                self.assertNetwork(text)

    def test_wrapped_or_unsupported_prefixed_git_context_refuses(self):
        for prefix in ("command ", "env X=1 ", "sudo ", "echo "):
            with self.subTest(prefix=prefix):
                self.assertNetwork(prefix + "git -C repo status")
        self.assertLocal("echo git status")
        self.assertLocal("command git rev-parse HEAD")

    def test_alias_and_include_configuration_refuses(self):
        for configuration in ("alias.download=fetch", "include.path=config", "includeIf.test.path=config"):
            with self.subTest(configuration=configuration):
                self.assertNetwork("git -c " + configuration + " status")
                self.assertNetwork("git -c" + configuration + " diff")

    def test_legacy_git_network_matches_preserved(self):
        for text in ("git clone URL", "git fetch origin", "git pull", "git submodule add URL",
                     "git submodule update", "/usr/bin/git fetch origin", "echo git fetch origin"):
            with self.subTest(text=text):
                self.assertNetwork(text)

    def test_qualifier_quoted_parameter_path_local_commands(self):
        # Exact command expressions from qualify_local_private_build.sh:1046,
        # 1051–1053. Source fixtures only; none of these commands is executed.
        commands = (
            'PREPARATION_SOURCE_BRANCH="$(/usr/bin/git -C "${SOURCE_ROOT}" branch --show-current 2>/dev/null || true)"',
            '"$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)"',
            '"$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse HEAD 2>/dev/null || true)"',
            '"$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse \'HEAD^{tree}\' 2>/dev/null || true)"',
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertLocal(command)
        for option in ("-C", "--git-dir", "--work-tree"):
            for parameter in ('"$SOURCE_ROOT"', '"${SOURCE_ROOT}"'):
                for verb in ("branch --show-current", "rev-parse HEAD", "status", "diff"):
                    with self.subTest(option=option, parameter=parameter, verb=verb):
                        self.assertLocal("/usr/bin/git " + option + " " + parameter + " " + verb)
                for verb in ("clone URL", "fetch origin", "pull", "submodule update", "custom-command", '"$verb"'):
                    with self.subTest(option=option, parameter=parameter, verb=verb):
                        self.assertNetwork("git " + option + " " + parameter + " " + verb)
        for path in ("'$SOURCE_ROOT'", "'${SOURCE_ROOT}'", '"${SOURCE_ROOT:-fallback}"',
                     '"$(pwd)"', '"`pwd`"', '"$SOURCE_ROOT"suffix', '"${SOURCE_ROOT:-suffix}"',
                     '"$SOURCE_ROOT\\x"'):
            with self.subTest(path=path):
                self.assertNetwork("git -C " + path + " rev-parse HEAD")
        for command in ('git "$options" rev-parse HEAD',
                        'git -c "$config" -C "${SOURCE_ROOT}" branch',
                        'git -c alias.download=fetch -C "${SOURCE_ROOT}" branch',
                        'git -c include.path=config -C "${SOURCE_ROOT}" rev-parse HEAD'):
            with self.subTest(command=command):
                self.assertNetwork(command)

    def test_full_qualifier_local_git_queries_ignore_unrelated_substitutions(self):
        # Read the actual caller as source data; never execute or bootstrap it.
        qualifier = Path(__file__).resolve().parents[2] / "Scripts" / "qualify_local_private_build.sh"
        source = qualifier.read_text(encoding="utf-8")
        self.assertLocal(source)
        self.assertNetwork(source + '\n/usr/bin/git -C "${SOURCE_ROOT}" fetch origin\n')
        # More unrelated quoted substitutions than the old whole-file queue.
        noise = 'VALUE="$(/usr/bin/printf value)"\n' * 96
        local = 'PREPARATION_SOURCE_BRANCH="$(/usr/bin/git -C "${SOURCE_ROOT}" branch --show-current 2>/dev/null || true)"\n'
        self.assertLocal(noise + local)
        self.assertNetwork(noise + '/usr/bin/git -C "${SOURCE_ROOT}" pull origin\n')
        self.assertNetwork(noise + 'command /usr/bin/git -C "${SOURCE_ROOT}" branch\n')
        self.assertLocal(noise + '# /usr/bin/git -C "${SOURCE_ROOT}" fetch origin\n')

    def test_local_git_producer_boundaries_and_path_data(self):
        commands = (
            'GIT_INDEX_FILE="${index}" /usr/bin/git \\\n    --git-dir="${scratch}/git" --work-tree="${VENDORED_SOURCE}" add -A',
            'observed="$(GIT_INDEX_FILE="${index}" /usr/bin/git --git-dir="${scratch}/git" write-tree)"',
            '/usr/bin/git -C "${STAGING}" init --quiet',
            '/usr/bin/git -C "${STAGING}" config user.name "MacScope Build"',
            '/usr/bin/git -C "${STAGING}" config user.email "build@invalid"',
            '/usr/bin/git -C "${STAGING}" add -A',
            '[[ "$(/usr/bin/git -C "${STAGING}" write-tree)" == "${EXPECTED_TREE}" ]]',
            '/usr/bin/git -C "${STAGING}" commit --quiet -m "MacScope vendored Ghostty surface"',
            'if ! git -C "$WT" diff --quiet; then true; fi',
            'git -C "$WT" --no-pager diff --stat HEAD',
            'git -C "$ROOT/ThirdParty/Lumen" rev-parse HEAD',
            'git -C"repo space" status',
            'print(f"next: git -C {path} switch <branch>")',
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertLocal(command)
        for verb in ("clone URL", "fetch origin", "pull", "submodule update"):
            with self.subTest(verb=verb):
                self.assertNetwork('GIT_INDEX_FILE="${index}" /usr/bin/git --git-dir="${scratch}/git" ' + verb)
                self.assertNetwork('/usr/bin/git \\\n  --work-tree="${VENDORED_SOURCE}" ' + verb)
                self.assertNetwork('print("git -C repo ' + verb + '")')
        for command in (
            'GIT_INDEX_FILE="$(network_command)" git -C "$ROOT" status',
            'git --git-dir="$(pwd)/git" status',
            'git --work-tree="${ROOT:-fallback}" status',
            'git -C "$ROOT" "$verb"',
            'git -c "$config" -C "$ROOT" status',
            'git -C "$ROOT" --unknown status',
        ):
            with self.subTest(command=command):
                self.assertNetwork(command)

    def test_declared_ordinary_surface_git_forms_and_network_mutations(self):
        # Bounded current source inputs, not executable producers or exemptions.
        # Normal/qualification roles and all ordinary producer inputs are those
        # already declared by the validator; remaining entries are the ordinary
        # helpers whose literal Git forms were source-reviewed for this repair.
        root = Path(__file__).resolve().parents[2]
        paths = NORMAL_ENTRYPOINTS + EXPLICIT_QUALIFICATION_ENTRYPOINTS + (
            "Scripts/build_ghostty_vt.sh",
            "Scripts/dependencies/build_vendored_ghostty_surface.sh",
            "Scripts/dependencies/build_ghostty_surface.sh",
            "Scripts/dependencies/build_vendored_sleigh_native_source.sh",
            "Scripts/build_unsigned_development.sh",
            "Scripts/dev_loop.sh",
            "Scripts/station.sh",
            "Scripts/native-decompiler-xpc/run_live_xpc_tests.sh",
            "Scripts/design/run_lumen_tool.sh",
            "script/build_and_run.sh",
        )
        for relative in paths:
            with self.subTest(source=relative):
                source = (root / relative).read_text(encoding="utf-8")
                self.assertLocal(source)
                self.assertNetwork(source + '\n/usr/bin/git -C "${SOURCE_ROOT}" fetch origin\n')
