"""Pure replay tests: passing fixtures are not live kernel observation proof."""

from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "reconstruction"))
import network_attribution as subject


def fixture():
    proof = {
        "proof_kind": subject.PROOF_KIND, "observation_id": 1, "pid": 10, "watch_token": 1,
        "registration": {"requested_monotonic_ns": 1, "completed_monotonic_ns": 2,
                         "receipt_ident": 10, "receipt_token": 1, "receipt_filter": -5,
                         "receipt_flags": subject.RECEIPT_FLAGS, "receipt_errno": 0},
        "initial_probe": {"begin_monotonic_ns": 3, "end_monotonic_ns": 4,
                          "executable_path": "/sbin/launchd"},
        "final_probe": {"begin_monotonic_ns": 23, "end_monotonic_ns": 24,
                        "executable_path": "/sbin/launchd"},
        "initial_drain_id": 1, "pre_final_drain_id": 3, "post_final_drain_id": 4,
    }
    drains = [{"drain_id": ident, "begin_monotonic_ns": begin,
               "end_monotonic_ns": end, "completed_to_empty": True, "events": []}
              for ident, begin, end in ((1, 5, 6), (2, 12, 13), (3, 21, 22), (4, 25, 26))]
    return [proof], drains


class NetworkAttributionTests(unittest.TestCase):
    def validate(self, proofs, drains, **kwargs):
        arguments = dict(observer_spawn_ns=10, observer_eof_ns=20,
                         queue_closed_ns=30, candidate_paths=["/Applications/MacScope.app/Contents/MacOS/MacScope"])
        arguments.update(kwargs)
        return subject.validate_foreign_proofs(proofs, drains, **arguments)

    def test_valid_path_only_proof_returns_immutable_pid_set(self):
        self.assertEqual(self.validate(*fixture()), frozenset({10}))

    def test_empty_proofs_never_invent_identities(self):
        _, drains = fixture()
        self.assertEqual(self.validate([], drains), frozenset())

    def test_strict_json_roundtrip(self):
        proofs, drains = fixture()
        decoded = subject.decode_ledger_json(json.dumps(dict(proofs=proofs, drains=drains)).encode())
        self.assertEqual(self.validate(**decoded), frozenset({10}))

    def test_invalid_json_and_closed_top_level(self):
        for raw in (b'', b'\xff', b'{"proofs":[],"proofs":[],"drains":[]}',
                    b'{"proofs":NaN,"drains":[]}', b'{"proofs":[],"drains":[],"extra":0}',
                    b'[]', b'[' * 2000 + b']' * 2000, 'not bytes'):
            with self.subTest(raw=str(raw)[:80]), self.assertRaises(subject.NetworkAttributionError):
                subject.decode_ledger_json(raw)

    def test_byte_limit(self):
        with patch.object(subject, "MAX_JSON_BYTES", 3), self.assertRaises(subject.NetworkAttributionError):
            subject.decode_ledger_json(b'{}  ')

    def test_no_optional_start_or_unknown_schema(self):
        for target in ("proof", "registration", "initial_probe", "final_probe", "drain"):
            proofs, drains = fixture()
            record = proofs[0] if target == "proof" else drains[0] if target == "drain" else proofs[0][target]
            record["start_time_unix_us"] = 1
            with self.subTest(target=target), self.assertRaises(subject.NetworkAttributionError):
                self.validate(proofs, drains)

    def test_receipt_fields_exact(self):
        for field, bad in (("receipt_ident", 11), ("receipt_token", 2), ("receipt_filter", -4),
                           ("receipt_flags", 0x65), ("receipt_flags", subject.RECEIPT_FLAGS | 8),
                           ("receipt_errno", 1), ("receipt_errno", False)):
            proofs, drains = fixture()
            proofs[0]["registration"][field] = bad
            with self.subTest(field=field, bad=bad), self.assertRaises(subject.NetworkAttributionError):
                self.validate(proofs, drains)

    def test_invalid_kind_and_numbers(self):
        for field, bad in (("proof_kind", "candidate"), ("pid", True), ("pid", 0),
                           ("watch_token", -1), ("observation_id", 1.0),
                           ("pid", 1 << 64), ("initial_drain_id", False)):
            proofs, drains = fixture()
            proofs[0][field] = bad
            with self.subTest(field=field), self.assertRaises(subject.NetworkAttributionError):
                self.validate(proofs, drains)

    def test_candidate_and_lexical_aliases_reject(self):
        for path in ("/Applications/MacScope.app/Contents/MacOS/MacScope", "/sbin/../sbin/launchd",
                     "//sbin/launchd", "/sbin//launchd", "/sbin/./launchd", "/sbin/launchd/",
                     "relative", "/", "/bad\x00path", "/bad\npath", "/bad\ud800", "/" + "x" * 4096):
            proofs, drains = fixture()
            proofs[0]["initial_probe"]["executable_path"] = path
            proofs[0]["final_probe"]["executable_path"] = path
            with self.subTest(path=repr(path)[:60]), self.assertRaises(subject.NetworkAttributionError):
                self.validate(proofs, drains)

    def test_changed_final_path(self):
        proofs, drains = fixture()
        proofs[0]["final_probe"]["executable_path"] = "/bin/other"
        with self.assertRaises(subject.NetworkAttributionError):
            self.validate(proofs, drains)

    def test_duplicate_pid_token_or_observation(self):
        for field in ("pid", "watch_token", "observation_id"):
            proofs, drains = fixture()
            other = deepcopy(proofs[0])
            other.update(pid=11, watch_token=2, observation_id=2)
            other[field] = proofs[0][field]
            other["registration"].update(receipt_ident=other["pid"], receipt_token=other["watch_token"])
            proofs.append(other)
            with self.subTest(field=field), self.assertRaises(subject.NetworkAttributionError):
                self.validate(proofs, drains)

    def test_multiple_independent_proofs(self):
        proofs, drains = fixture()
        other = deepcopy(proofs[0])
        other.update(pid=11, watch_token=2, observation_id=2)
        other["registration"].update(receipt_ident=11, receipt_token=2)
        proofs.append(other)
        self.assertEqual(self.validate(proofs, drains), frozenset({10, 11}))

    def test_every_drain_including_unreferenced_replayed(self):
        for index in range(4):
            for flag in (subject.NOTE_EXEC, subject.NOTE_EXIT):
                proofs, drains = fixture()
                drains[index]["events"] = [dict(watch_token=1, pid=10, filter=-5, flags=0x21, fflags=flag, data=0)]
                with self.subTest(index=index, flag=flag), self.assertRaises(subject.NetworkAttributionError):
                    self.validate(proofs, drains)

    def test_unrelated_transition_retained_without_poisoning_other_proof(self):
        proofs, drains = fixture()
        drains[1]["events"] = [dict(watch_token=2, pid=11, filter=-5, flags=0x8031,
                                    fflags=subject.NOTE_EXIT, data=0)]
        self.assertEqual(self.validate(proofs, drains), frozenset({10}))

    def test_actual_macos_event_preserves_receipt_bit_and_coalesced_transitions(self):
        proofs, drains = fixture()
        event = dict(watch_token=2, pid=11, filter=-5, flags=0x8075,
                     fflags=subject.NOTE_EXEC | subject.NOTE_EXIT, data=0)
        drains[1]["events"] = [event]
        self.assertEqual(self.validate(proofs, drains), frozenset({10}))
        event.update(watch_token=1, pid=10)
        with self.assertRaises(subject.NetworkAttributionError):
            self.validate(proofs, drains)

    def test_mismatched_token_cannot_hide_same_pid_transition(self):
        proofs, drains = fixture()
        drains[1]["events"] = [dict(watch_token=9, pid=10, filter=-5, flags=0x21,
                                    fflags=subject.NOTE_EXEC, data=0)]
        with self.assertRaises(subject.NetworkAttributionError):
            self.validate(proofs, drains)

    def test_unrelated_error_or_conflicting_event_identity_rejects_globally(self):
        for change in (dict(flags=0x4021, data=1), dict(flags=0x23),
                       dict(pid=12), dict(watch_token=3)):
            proofs, drains = fixture()
            event = dict(watch_token=2, pid=11, filter=-5, flags=0x21,
                         fflags=subject.NOTE_EXEC, data=0)
            drains[1]["events"] = [event]
            changed = dict(event, **change)
            drains[2]["events"] = [changed]
            with self.subTest(change=change), self.assertRaises(subject.NetworkAttributionError):
                self.validate(proofs, drains)

    def test_unknown_event_or_terminal_reject(self):
        for change in (dict(flags=0x100), dict(fflags=1), dict(filter=-4), dict(data=1),
                       dict(flags=0x8000, fflags=0), dict(flags=0x4010, fflags=0, data=1),
                       dict(watch_token=True), dict(extra=0)):
            proofs, drains = fixture()
            event = dict(watch_token=1, pid=10, filter=-5, flags=0x21, fflags=subject.NOTE_EXEC, data=0)
            event.update(change)
            drains[1]["events"] = [event]
            with self.subTest(change=change), self.assertRaises(subject.NetworkAttributionError):
                self.validate(proofs, drains)

    def test_registration_and_probe_order(self):
        changes = (("registration", "requested_monotonic_ns", 3),
                   ("registration", "completed_monotonic_ns", 4),
                   ("initial_probe", "begin_monotonic_ns", 5),
                   ("initial_probe", "end_monotonic_ns", 6),
                   ("final_probe", "begin_monotonic_ns", 21),
                   ("final_probe", "end_monotonic_ns", 26))
        for section, field, value in changes:
            proofs, drains = fixture()
            proofs[0][section][field] = value
            with self.subTest(section=section, field=field), self.assertRaises(subject.NetworkAttributionError):
                self.validate(proofs, drains)

    def test_missing_duplicate_or_reused_drain(self):
        for value in (2, 3, 99):
            proofs, drains = fixture()
            proofs[0]["initial_drain_id"] = value
            with self.subTest(value=value), self.assertRaises(subject.NetworkAttributionError):
                self.validate(proofs, drains)

    def test_drain_failures(self):
        for change in (dict(completed_to_empty=False), dict(completed_to_empty=1),
                       dict(drain_id=1), dict(begin_monotonic_ns=5),
                       dict(end_monotonic_ns=31), dict(events={})):
            proofs, drains = fixture()
            drains[1].update(change)
            with self.subTest(change=change), self.assertRaises(subject.NetworkAttributionError):
                self.validate(proofs, drains)

    def test_external_boundaries(self):
        for kwargs in (dict(observer_spawn_ns=6), dict(observer_eof_ns=22),
                       dict(queue_closed_ns=26), dict(observer_spawn_ns=True),
                       dict(observer_eof_ns=9), dict(candidate_paths=[]),
                       dict(candidate_paths=["/a/../b"]), dict(candidate_paths=["/a", "/a"])):
            with self.subTest(kwargs=kwargs), self.assertRaises(subject.NetworkAttributionError):
                self.validate(*fixture(), **kwargs)

    def test_inventory_limits_and_types(self):
        for constant in ("MAX_PROOFS", "MAX_DRAINS"):
            with patch.object(subject, constant, 0), self.assertRaises(subject.NetworkAttributionError):
                self.validate(*fixture())
        proofs, drains = fixture()
        for p, d in ((tuple(proofs), drains), (proofs, tuple(drains)), (proofs, [])):
            with self.assertRaises(subject.NetworkAttributionError):
                self.validate(p, d)
        drains[1]["events"] = [dict(watch_token=2, pid=11, filter=-5, flags=0x21,
                                    fflags=subject.NOTE_EXEC, data=0)]
        with patch.object(subject, "MAX_EVENTS", 0), self.assertRaises(subject.NetworkAttributionError):
            self.validate(proofs, drains)


if __name__ == "__main__":
    unittest.main()
