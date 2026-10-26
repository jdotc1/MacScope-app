"""Regression checks for native project parsing and provenance phase authority."""
import copy
import tempfile
import unittest
from pathlib import Path

from Scripts import check_local_signing_policy as guard
from Scripts.xcode_project_json import loads_project, read_project, MAX_PROJECT_BYTES


def project_fixture():
    app_phase = {
        'kind': 'script', 'name': guard.RELEASE_PROVENANCE_PHASE_NAME,
        'run-on-every-build': True,
        'input-paths': [*guard.RELEASE_PROVENANCE_NATIVE_DECOMPILER_INPUTS,
                        *guard.RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS,
                        guard.RELEASE_PROVENANCE_ANALYSIS_WORKER_INPUT,
                        guard.RELEASE_PROVENANCE_MACHOKIT_INPUT],
        'output-paths': [guard.RELEASE_PROVENANCE_OUTPUT],
        'script': [
            *[line.strip() for line in guard.RELEASE_PROVENANCE_GUARD_LINES],
            'generate_release_build_provenance.py --project-file-path "$PROJECT_FILE_PATH" --configuration "$CONFIGURATION"',
            '--developer-dir "$DEVELOPER_DIR"',
            '--swift-executable "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"',
            '--native-decompiler-golden-result "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerBridgeGolden.json"',
            '--machokit-materialization-root "$MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT"',
            '--analysis-worker-executable "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService"',
            '--ghostty-surface-manifest "$MACSCOPE_GHOSTTY_SURFACE_MANIFEST"',
            '--ghostty-surface-staged-root "$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT"',
        ],
    }
    test_phase = {
        'kind': 'script', 'name': guard.CORETESTS_PROVENANCE_COPY_PHASE_NAME,
        'run-on-every-build': False,
        'input-paths': [guard.CORETESTS_PROVENANCE_SOURCE],
        'output-paths': [guard.CORETESTS_PROVENANCE_DESTINATION],
        'script': ['set -eu', *[line.strip() for line in guard.RELEASE_PROVENANCE_GUARD_LINES],
                   '$BUILT_PRODUCTS_DIR/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json',
                   '/bin/cp -p', '/usr/bin/cmp -s', '/usr/bin/stat -f', '[ -L'],
    }
    return {'targets': [
        {'name': 'MacScopeApp', 'product-type': 'application', 'build-phases': [
            {'kind': 'copy', 'relative-path': '$(CONTENTS_FOLDER_PATH)/XPCServices'}, app_phase]},
        {'name': 'CoreTests', 'product-type': 'bundle.unit-test', 'dependencies': ['MacScopeApp'], 'build-phases': [test_phase]},
    ]}


class ProjectJSONTests(unittest.TestCase):
    def test_trailing_commas_preserve_string_contents(self):
        self.assertEqual(loads_project('{"a": ["x,]", "quote\\\" ,}",],}'),
                         {'a': ['x,]', 'quote" ,}']})

    def test_rejects_invalid_json_and_duplicate_keys(self):
        for value in ('{"a":1,"a":2}', '{"a":NaN}', '[1,]', '{"a":1,,}', '{/*x*/}', '{"a":[,]}'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                loads_project(value)

    def test_bounded_file_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'project.xcproj'
            with path.open('wb') as stream:
                stream.truncate(MAX_PROJECT_BYTES + 1)
            with self.assertRaises(ValueError):
                read_project(path)

    def test_valid_phases(self):
        self.assertEqual(guard.validate_json_provenance_phases(project_fixture()), [])

    def test_coretests_dependency_graph_allows_omitted_false_but_not_always_run(self):
        project = project_fixture()
        phase = project['targets'][1]['build-phases'][0]
        del phase['run-on-every-build']
        self.assertEqual(guard.validate_json_provenance_phases(project), [])
        for value in (True, None, 0, 'false'):
            with self.subTest(value=value):
                phase['run-on-every-build'] = value
                self.assertTrue(guard.validate_json_provenance_phases(project))

    def test_exact_app_input_output_and_ghostty_cli_authority(self):
        mutations = [
            lambda p: p['input-paths'].remove(guard.RELEASE_PROVENANCE_GHOSTTY_SURFACE_INPUTS[0]),
            lambda p: p['input-paths'].reverse(),
            lambda p: p['input-paths'].append('extra'),
            lambda p: p['input-paths'].append(p['input-paths'][0]),
            lambda p: p['output-paths'].append('extra'),
            lambda p: p['output-paths'].append(guard.RELEASE_PROVENANCE_OUTPUT),
            lambda p: p['script'].pop(-2),
            lambda p: p['script'].pop(-1),
            lambda p: p['script'].extend(p['script'][-2:]),
            lambda p: p['script'].append('--ghostty-surface-unknown x'),
            lambda p: p['script'].__setitem__(slice(-2, None), p['script'][-2:][::-1]),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                project = project_fixture()
                mutate(project['targets'][0]['build-phases'][-1])
                self.assertTrue(guard.validate_json_provenance_phases(project))

    def test_coretests_release_only_guard_is_required(self):
        project = project_fixture()
        project['targets'][1]['build-phases'][0]['script'].pop(0)
        self.assertTrue(guard.validate_json_provenance_phases(project))

    def test_string_scripts_preserve_the_same_authority(self):
        project = project_fixture()
        for target in project['targets']:
            phase = target['build-phases'][-1]
            phase['script'] = '\n'.join(phase['script'])
        self.assertEqual(guard.validate_json_provenance_phases(project), [])

    def test_each_authority_constraint_fails_closed(self):
        mutations = [
            lambda p: p['targets'][0].update({'product-type': 'aggregate'}),
            lambda p: p['targets'][0]['build-phases'].reverse(),
            lambda p: p['targets'][0]['build-phases'].pop(0),
            lambda p: p['targets'][0]['build-phases'][-1].update({'run-on-every-build': False}),
            lambda p: p['targets'][0]['build-phases'][-1]['input-paths'].pop(),
            lambda p: p['targets'][0]['build-phases'][-1]['output-paths'].clear(),
            lambda p: p['targets'][0]['build-phases'][-1]['script'].pop(),
            lambda p: p['targets'][1]['dependencies'].clear(),
            lambda p: p['targets'][1]['build-phases'][0]['script'].pop(),
            lambda p: p['targets'][1]['build-phases'][0]['input-paths'].append('extra'),
            lambda p: p['targets'].append(copy.deepcopy(p['targets'][0])),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                project = project_fixture()
                mutation(project)
                self.assertTrue(guard.validate_json_provenance_phases(project))

    def test_both_formats_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            for name in ('project.xcproj', 'project.pbxproj'):
                (project / name).write_text('{}')
            self.assertIn('both', guard.validate_generated_project_provenance_phase(project)[0])

    def test_legacy_only_project_is_not_an_accepted_generated_project(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            (project / 'project.pbxproj').write_text('{}')
            self.assertIn('authoritative JSON', guard.validate_generated_project_provenance_phase(project)[0])


if __name__ == '__main__':
    unittest.main()
