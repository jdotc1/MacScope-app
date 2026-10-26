"""Limited precision certificate regressions. Source additions only; not executed."""
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dependencies'))
from validate_offline_build_surface import _referenced_acquisition_paths, _inert_literal_output_text


class LiteralOutputCertificateTests(unittest.TestCase):
    TOKENS = {'station.sh': 'Scripts/station.sh', 'Scripts/station.sh': 'Scripts/station.sh'}

    def references(self, body, relative='Scripts/example.sh'):
        return _referenced_acquisition_paths('#!/bin/bash\n' + body, self.TOKENS, relative)

    def test_exact_absolute_printf_literal_hint_is_inert(self):
        self.assertEqual(self.references('/usr/bin/printf "%s\\n" "Run Scripts/station.sh sync manually"\n'), set())

    def test_exact_absolute_echo_literal_hint_is_inert(self):
        self.assertEqual(self.references("/bin/echo 'Run station.sh sync manually'\n"), set())

    def test_actual_station_sync_still_detected_5380bc50b(self):
        self.assertEqual(self.references('station.sh sync\n'), {'Scripts/station.sh'})

    def test_quoted_actual_station_command_stays_detected(self):
        self.assertEqual(self.references('"${SCRIPT_DIR}/station.sh" sync\n'), {'Scripts/station.sh'})

    def test_hint_does_not_hide_second_actual_call(self):
        self.assertEqual(self.references("/bin/echo 'station.sh sync'; station.sh sync\n"), {'Scripts/station.sh'})

    def test_bare_builtin_is_not_assumed_unshadowed(self):
        for body in ["echo 'station.sh sync'", "printf '%s' 'station.sh sync'"]:
            with self.subTest(body=body):
                self.assertEqual(self.references(body), {'Scripts/station.sh'})

    def test_basename_is_not_output_identity(self):
        self.assertEqual(self.references("/tmp/echo 'station.sh sync'"), {'Scripts/station.sh'})

    def test_substitution_and_variable_data_remain_conservative(self):
        for body in ['/bin/echo "$(station.sh sync)"', 'hint="station.sh sync"; /bin/echo "$hint"']:
            with self.subTest(body=body):
                self.assertEqual(self.references(body), {'Scripts/station.sh'})

    def test_single_quoted_substitution_bytes_are_literal(self):
        self.assertEqual(self.references("/bin/echo '$(station.sh sync)'"), set())

    def test_heredoc_and_malformed_quote_leave_source_unchanged(self):
        for body in ["cat <<'EOF'\n/bin/echo 'station.sh sync'\nEOF", "/bin/echo 'station.sh sync"]:
            text = '#!/bin/bash\n' + body
            with self.subTest(body=body):
                self.assertEqual(_inert_literal_output_text('Scripts/example.sh', text), text)

    def test_shadowing_and_source_context_leave_source_unchanged(self):
        for body in ["alias echo=sh; /bin/echo 'station.sh sync'", "X=1 source helper.sh; /bin/echo 'station.sh sync'", "printf() { station.sh sync; }; /bin/echo 'station.sh sync'"]:
            text = '#!/bin/bash\n' + body
            with self.subTest(body=body):
                self.assertEqual(_inert_literal_output_text('Scripts/example.sh', text), text)

    def test_printf_nonoutput_mutation_formats_not_certified(self):
        for body in ["/usr/bin/printf -v cmd '%s' 'station.sh sync'", "/usr/bin/printf '%n' 'station.sh sync'"]:
            with self.subTest(body=body):
                self.assertEqual(self.references(body), {'Scripts/station.sh'})

    def test_unsupported_existing_script_forms_preserve_baseline(self):
        for body in ['SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n/bin/echo "station.sh sync"', 'if true; then /bin/echo "station.sh sync"; fi', '/bin/echo "station.sh sync" >&2 || true']:
            text = '#!/bin/bash\n' + body
            with self.subTest(body=body):
                self.assertEqual(_inert_literal_output_text('Scripts/example.sh', text), text)

    def test_python_module_and_interpreter_arguments_stay_conservative(self):
        self.assertEqual(_referenced_acquisition_paths('print("station.sh sync")', self.TOKENS, 'Scripts/example.py'), {'Scripts/station.sh'})
        self.assertEqual(self.references('python3 station.sh sync'), {'Scripts/station.sh'})

    def test_comments_are_not_erased(self):
        self.assertEqual(self.references("# station.sh sync\n/bin/echo 'harmless'"), {'Scripts/station.sh'})

    def test_no_source_filename_exemption_added(self):
        self.assertEqual(self.references('station.sh sync', 'Scripts/dependencies/first_party_components.sh'), {'Scripts/station.sh'})

    def test_carriage_return_cannot_change_executable_identity(self):
        text = "#!/bin/bash\n/bin/echo\r 'station.sh sync'"
        self.assertEqual(_inert_literal_output_text('Scripts/example.sh', text), text)

    def test_exact_historical_5380_call_and_context_preserve_refusal(self):
        # 5380bc50bd6959b83ade8b5d3a6d9c2c773557bb:
        # Scripts/build_unsigned_development.sh:1,5,32 (noncontiguous excerpt).
        text = ('#!/usr/bin/env bash\n'
                'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"\n'
                '"$ROOT/Scripts/station.sh" sync "$ROOT"\n')
        relative = 'Scripts/build_unsigned_development.sh'
        self.assertEqual(_inert_literal_output_text(relative, text), text)
        self.assertEqual(_referenced_acquisition_paths(text, self.TOKENS, relative), {'Scripts/station.sh'})
