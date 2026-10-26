import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import macscope  # noqa: E402


class RecordingClient:
    def __init__(self):
        self.calls = []

    def call(self, name, arguments):
        # Exercise the actual JSON encoding boundary, not just a dict comparison.
        wire = json.loads(json.dumps({"name": name, "arguments": arguments}))
        self.calls.append(wire)
        return {"address": "0x1000", "value": "0xFF"}


class ExplicitNullTests(unittest.TestCase):
    def setUp(self):
        self.doc = object.__new__(macscope.Document)
        self.doc._client = RecordingClient()

    def arguments(self):
        return self.doc._client.calls[-1]["arguments"]

    def test_script_retains_explicit_null_clear(self):
        self.doc.run_script([{"command": "set-signature", "arguments": {
            "address": "0x1000", "args": None, "returnType": None
        }}], preserve_nulls=True)
        self.assertEqual(self.arguments(), {
            "address": "0x1000", "args": None, "returnType": None
        })

    def test_batch_default_preserves_none_omission(self):
        self.doc.run_script([{"command": "functions", "arguments": {"limit": None}}])
        self.assertEqual(self.arguments(), {})

    def test_batch_explicit_sentinel_works_without_flag(self):
        self.doc.run_script([{"command": "set-signature", "arguments": {
            "address": "0x1000", "args": macscope.JSON_NULL
        }}])
        self.assertEqual(self.arguments(), {"address": "0x1000", "args": None})

    def test_generic_explicit_null_clear(self):
        self.doc.command("set-signature", address="0x1000", args=macscope.JSON_NULL)
        self.assertIsNone(self.arguments()["args"])

    def test_optional_none_still_means_omit(self):
        self.doc.functions()
        self.assertEqual(self.arguments(), {})
        self.doc.command("set-signature", address="0x1000", args=None)
        self.assertEqual(self.arguments(), {"address": "0x1000"})

    def test_empty_list_is_distinct_from_null_and_omission(self):
        self.doc.command("set-signature", address="0x1000", args=[])
        self.assertEqual(self.arguments()["args"], [])

    def test_false_zero_and_empty_text_are_retained(self):
        self.doc.command("test", flag=False, count=0, label="")
        self.assertEqual(self.arguments(), {"flag": False, "count": 0, "label": ""})

    def test_batch_missing_or_null_argument_object(self):
        self.doc.run_script([{"command": "info"}, {"command": "info", "arguments": None}])
        self.assertEqual([c["arguments"] for c in self.doc._client.calls], [{}, {}])

    def test_batch_rejects_nonobject_arguments(self):
        with self.assertRaises(TypeError):
            self.doc.run_script([{"command": "info", "arguments": []}])

    def test_result_coercion_remains_address_specific(self):
        result = self.doc.info()
        self.assertEqual(result.address, 0x1000)
        self.assertEqual(result.value, "0xFF")


if __name__ == "__main__":
    unittest.main()
