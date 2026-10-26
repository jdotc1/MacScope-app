"""Parser-engine staging timestamps; synthetic components, no builds or cache."""
import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    'build_parser_engines', Path(__file__).resolve().parents[1] / 'dependencies/build_parser_engines.py')
engines = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engines)

OLD = 1_000_000_000  # 2001: an engine built long before the current incremental products


def write_component(root, text):
    (root / 'include').mkdir(parents=True)
    header = root / 'include/MacScopeParserEngines.h'
    header.write_text(text)
    for path in (header, root / 'include', root):
        os.utime(path, (OLD, OLD))
        path.chmod(0o555 if path.is_dir() else 0o444)
    return header


class ParserEngineStageTimesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        for path in self.root.rglob('*'):
            if not path.is_symlink():
                path.chmod(0o755 if path.is_dir() else 0o644)
        self.temp.cleanup()

    def test_refresh_gives_read_only_staged_files_the_current_time(self):
        header = write_component(self.root / 'component', 'char *f(void);')
        before = time.time() - 1
        engines.refresh_staged_times(self.root / 'component')
        self.assertGreater(header.stat().st_mtime, before)
        self.assertEqual(header.stat().st_mode & 0o222, 0, 'still read-only')

    def test_stage_refreshes_only_newly_materialized_components(self):
        destination = self.root / 'MacScopeParserEngines'
        cache = self.root / 'cache'
        cache.mkdir()
        unchanged = 'parser-engine-pe-parse'
        changed = [name for name in engines.ORDER if name != unchanged]
        keys = {name: ('new-' if name in changed else 'same-') + name for name in engines.ORDER}
        # A previous build staged every component; one of them is unchanged now.
        destination.mkdir()
        kept = write_component(destination / unchanged, 'unchanged')
        (destination / engines.STAMP_NAME).write_bytes(engines.canonical(
            {'schema': engines.LAYOUT, 'keys': {unchanged: keys[unchanged]}, 'fingerprint': 'old',
             'cache_root': str(cache)}))

        def materialize(*arguments):
            component = arguments[arguments.index('--component') + 1]
            incoming = Path(arguments[arguments.index('--destination') + 1])
            write_component(incoming, 'char *macscope_gomacho_go_functions(void);' + component)

        before = time.time() - 1
        with mock.patch.object(engines, 'Toolchain'), \
                mock.patch.object(engines, 'fingerprint', return_value='new'), \
                mock.patch.object(engines, 'component_key', side_effect=lambda c, t, k: (keys[c], {})), \
                mock.patch.object(engines, 'ensure_entry', return_value=cache / 'entry'), \
                mock.patch.object(engines, 'cache_tool', side_effect=materialize):
            engines.stage(destination, cache, {})
        for name in changed:
            header = destination / name / 'include/MacScopeParserEngines.h'
            self.assertGreater(header.stat().st_mtime, before, name)
        self.assertEqual(kept.stat().st_mtime, OLD, 'unchanged component keeps its time')


if __name__ == '__main__':
    unittest.main()
