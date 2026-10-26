"""Behavioral guards for scoring layout literals in the design ratchet."""
import unittest

from Scripts.design import style_audit


class DesignStyleAuditTests(unittest.TestCase):
    def test_zero_collapse_is_not_styling_debt_but_nonzero_dimensions_are(self):
        cases = [
            (".frame(width: 0)", False),
            (".frame(maxWidth: .infinity)", False),
            (".frame(minWidth: shown ? layout.minimum : 0, "
             "idealWidth: shown ? layout.ideal : 0, "
             "maxWidth: shown ? layout.maximum : 0, maxHeight: .infinity)", False),
            (".frame(maxWidth: 280, alignment: .leading)", True),
            (".frame(width: 0, height: 28)", True),
            (".frame(minWidth: shown ? layout.minimum : 12)", True),
        ]
        for source, expected in cases:
            with self.subTest(source=source):
                hits = list(style_audit.detect_frames(style_audit.clean_source(source)))
                self.assertEqual(len(hits), 1)
                _, kind, value = hits[0]
                self.assertEqual(style_audit.is_hardcoded("frame", kind, value), expected)
