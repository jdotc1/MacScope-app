import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('nonwindow_core_tests', Path(__file__).parents[1] / 'qualification/nonwindow_core_tests.py')
selection_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(selection_module)


class NonwindowCoreTestsSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tests = self.root / 'MacScope/Tests/CoreTests'
        self.tests.mkdir(parents=True)
        for name in selection_module.WINDOW_FILES:
            (self.tests / name).write_text('final class ' + Path(name).stem + ': XCTestCase {}')

    def testExcludesEverySuiteInWindowFileAndReportsUncovered(self):
        with (self.tests / 'HexEditModelTests.swift').open('a') as stream:
            stream.write('\nfinal class HexTextViewInteractionTests: XCTestCase { let window = NSWindow() }')
        receipt = selection_module.selection(self.root)
        self.assertIn('CoreTests/HexTextViewInteractionTests', receipt['excluded_suites'])
        self.assertEqual(receipt['coverage'], 'partial-nonwindow')
        self.assertIn('uncovered', receipt['window_test_status'])

    def testUnreviewedWindowConstructorOrPresentationFailsClosed(self):
        for marker in ('NSWindow()', 'NSPanel()', 'window.orderFront(nil)', 'class Child: NSWindow {}'):
            with self.subTest(marker=marker):
                (self.tests / 'NewTests.swift').write_text(marker)
                with self.assertRaisesRegex(ValueError, 'unreviewed window-capable'):
                    selection_module.selection(self.root)

    def testMissingReviewedFileDoesNotSilentlyClaimCompleteInventory(self):
        (self.tests / 'DSThemeTests.swift').unlink()
        with self.assertRaisesRegex(ValueError, 'inventory changed'):
            selection_module.selection(self.root)

    def testNonwindowSuiteRemainsSelected(self):
        (self.tests / 'PureTests.swift').write_text('final class PureTests: XCTestCase {}')
        self.assertNotIn('CoreTests/PureTests', selection_module.selection(self.root)['excluded_suites'])


if __name__ == '__main__':
    unittest.main()
