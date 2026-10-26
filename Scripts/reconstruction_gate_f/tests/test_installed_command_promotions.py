"""Bootstrap installed command closure; existing profile bytes remain frozen."""
import unittest
from dataclasses import replace

from Scripts.phase2 import run_installed_shell_smoke

from Scripts.reconstruction.install_release_to_applications import REQUIRED_ACCEPTANCE_GATES
from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile, CommandExecutionMode, command_templates, INSTALLED_CAPTURE_COMMANDS, installed_gate_output_slots
from Scripts.reconstruction_gate_f.command_compiler import _resolve_argv, CommandCompilationError, compile_command_plan
from Scripts.reconstruction_gate_f.prerequisite_dag import lane_c_command_authorities
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.tests import parsed_candidate
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs


class InstalledCommandPromotionTests(unittest.TestCase):
    def setUp(self):
        self.profile = CampaignProfile.BOOTSTRAP_VERIFIER
        self.templates = {t.command_id: t for t in command_templates(profile=self.profile)}

    def test_five_exact_promotions(self):
        old = {t.command_id: t for t in command_templates()}
        promoted = {k for k in old if old[k].execution_mode is CommandExecutionMode.VECTOR_ONLY
                    and self.templates.get(k) and self.templates[k].execution_mode is CommandExecutionMode.RUNNABLE}
        self.assertEqual(promoted - {'native.normal', 'native.asan', 'native.ubsan', 'native.golden'}, INSTALLED_CAPTURE_COMMANDS - {'install.release-to-applications'})
        self.assertEqual(self.templates['source.hosted-governance'].timeout_seconds, 1800)
        self.assertEqual(old['source.hosted-governance'].timeout_seconds, 300)

    def test_bootstrap_install_has_real_begin_bridge_and_immutable_outputs(self):
        template = self.templates['install.release-to-applications']
        self.assertEqual(template.argv[2], 'Scripts/reconstruction_gate_f/begin_installed_candidate.py')
        self.assertIn('--command-predecessor-observations-sha256', template.argv)
        self.assertEqual(template.generated_artifacts, (
            '@install_release_artifact_root@/GateFInstalledBegin.projection.json',
            '@install_release_artifact_root@/GateFInstalledBegin.source-equality.json'))
        original = next(t for t in command_templates() if t.command_id == template.command_id)
        self.assertEqual(original.argv[2], 'Scripts/reconstruction/install_release_to_applications.py')
        self.assertEqual(len(original.generated_artifacts), 3)

    def test_aggregate_complete_flags_and_outputs(self):
        t = self.templates['installed.emit-report']
        values = command_inputs(profile=self.profile)
        values['candidate_commit'] = '1' * 40
        argv = _resolve_argv(t, values)
        self.assertEqual(argv.count('--acceptance-gate-output'), 8)
        self.assertEqual(tuple(g for g, _ in installed_gate_output_slots()), REQUIRED_ACCEPTANCE_GATES)
        for gate, name in installed_gate_output_slots():
            self.assertIn(gate + '=' + values[name], argv)
            self.assertIn('@' + name + '@', t.generated_artifacts)
        for flag in ('qualification-run-id', 'qualification-run-nonce', 'installation-pending-state',
                     'full-surface-report', 'legacy-grid-report', 'cli-gui-operability-report',
                     'mcp-operability-report', 'native-xpc-execution-report'):
            self.assertEqual(argv.count('--' + flag), 1)
        self.assertEqual(len(t.generated_artifacts), 9)
        self.assertEqual(len(t.generated_logs), 1)

    def test_bootstrap_shell_selects_schema5_renderer_smoke(self):
        values = command_inputs(profile=self.profile)
        values['candidate_commit'] = '1' * 40
        template = self.templates['installed.shell-smoke']
        argv = _resolve_argv(template, values)
        arguments = run_installed_shell_smoke.parse_arguments(list(argv[3:]))
        self.assertTrue(arguments.single_launch,
                        'bootstrap shell must select schema-5 renderer reports, not the restart gate')
        self.assertEqual(arguments.expected_source_commit, values['candidate_commit'])
        self.assertEqual(str(arguments.output), values['installed_shell_smoke_report'])
        self.assertEqual(template.generated_artifacts,
                         ('@installed_legacy_grid_report@', '@installed_shell_smoke_report@'))
        self.assertEqual(values['installed_full_surface_report'], str(arguments.output))
        self.assertEqual(values['installed_legacy_grid_report'],
                         str(arguments.output.with_name(arguments.output.stem + '.legacy-grid' + arguments.output.suffix)))
        existing = next(t for t in command_templates() if t.command_id == template.command_id)
        original = run_installed_shell_smoke.parse_arguments(list(_resolve_argv(existing, values)[3:]))
        self.assertFalse(original.single_launch)

    def test_shell_aggregate_inputs_cannot_redirect_producer_outputs(self):
        candidate = parsed_candidate()
        for name in ('installed_full_surface_report', 'installed_legacy_grid_report'):
            values = command_inputs(profile=self.profile)
            values[name] += '-other-run'
            with self.subTest(name=name), self.assertRaisesRegex(CommandCompilationError, 'shell producer path'):
                compile_command_plan(candidate, compile_scenario_catalog(candidate), repository_root=ROOT,
                                     inputs=values, profile=self.profile)

    def test_embedded_gate_slots_are_closed(self):
        t = self.templates['installed.emit-report']
        values = command_inputs(profile=self.profile)
        values['candidate_commit'] = '1' * 40
        position = t.argv.index('--acceptance-gate-output') + 1
        for bad in ('alien=@installed_acceptance_cli_output@', 'cli=@installed_report@',
                    'prefix@installed_report@', 'cli=/arbitrary/path'):
            argv = list(t.argv)
            argv[position] = bad
            with self.subTest(bad=bad), self.assertRaises(CommandCompilationError):
                _resolve_argv(replace(t, argv=tuple(argv)), values)
        with self.assertRaises(CommandCompilationError):
            _resolve_argv(replace(t, argv=t.argv + t.argv[-2:]), values)
        with self.assertRaises(CommandCompilationError):
            _resolve_argv(replace(t, argv=t.argv[:-2]), values)

    def test_late_predecessors_are_exact_and_graph_compiles(self):
        expected = ('installed.accessibility-semantics', 'installed.emit-report', 'installed.shell-smoke',
                    'installed.source-equality', 'installed.task10-workflow', 'qualification.verify-bootstrap-fullsuite',
                    'xcode.focused.task10-projection', 'xcode.focused.task10-state-machine')
        key = 'evidence.t10c-current-source-adjudication'
        self.assertEqual(self.templates[key].prerequisite_ids, expected)
        self.assertEqual(next(t for t in lane_c_command_authorities(profile=self.profile) if t.command_id == key).prerequisite_ids, expected)
        candidate = parsed_candidate()
        plan = compile_command_plan(candidate, compile_scenario_catalog(candidate), repository_root=ROOT,
                                    inputs=command_inputs(profile=self.profile), profile=self.profile)
        self.assertEqual(next(c for c in plan.commands if c.command_id == key).prerequisite_ids, expected)


if __name__ == '__main__':
    unittest.main()
