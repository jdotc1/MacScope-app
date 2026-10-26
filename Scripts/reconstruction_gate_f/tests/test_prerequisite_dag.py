from __future__ import annotations

import unittest
from dataclasses import replace

from Scripts.reconstruction_gate_f.command_catalog import COMMAND_PREREQUISITES
from Scripts.reconstruction_gate_f.prerequisite_dag import (
    DEFAULT_PREREQUISITE_SPECS,
    LANE_C_COMMAND_AUTHORITIES,
    LANE_C_COMMAND_AUTHORITIES_BY_ID,
    LANE_C_COMMAND_AUTHORITY_SHA256,
    LANE_C_COMMAND_GROUP_IDS,
    LANE_C_COMMAND_PREREQUISITES,
    LANE_C_SCENARIO_BINDINGS,
    LANE_C_SCENARIO_BINDING_SHA256,
    LaneCScenarioPlanAuthority,
    PrerequisiteNodeSpec,
    PrerequisiteStage,
    compile_prerequisite_dag,
    lane_c_command_records,
    prerequisite_identity_sha256,
    validate_lane_c_command_catalog,
    validate_lane_c_command_plan,
)
from Scripts.reconstruction_gate_f.schema import (
    CandidateIdentity,
    CandidateSubjectKind,
    EvidenceLayer,
    candidate_identity_sha256,
    parse_candidate_identity,
)
from Scripts.reconstruction_gate_f.source_contract import (
    PrerequisiteAuthority,
    PrerequisiteStatus,
    SourceContract,
    make_source_contract,
    parse_source_contract,
    source_contract_candidate_sha256,
    source_contract_sha256,
    source_contract_to_mapping,
)
from Scripts.reconstruction_gate_f.tests import candidate_mapping, git_object, sha


SEMANTIC_PREREQUISITE_IDS = (
    "task-6-remediation",
    "task-8",
    "task-9",
    "t10a",
    "t10c",
    "task-10",
)


def candidate_for_subject(subject_kind: CandidateSubjectKind) -> CandidateIdentity:
    mapping = candidate_mapping(subject_kind)
    mapping["source"]["semantic_prerequisites"] = [
        {
            "prerequisite_id": prerequisite_id,
            "commit": git_object(f"{index + 1:x}"[-1]),
            "tree": git_object(f"{index + 7:x}"[-1]),
            "evidence_sha256": sha(f"{index + 9:x}"[-1]),
        }
        for index, prerequisite_id in enumerate(SEMANTIC_PREREQUISITE_IDS)
    ]
    if subject_kind is CandidateSubjectKind.POST_MERGE:
        mapping["accepted_postmerge_tree"] = mapping["prospective_merge_tree"]
    candidate, issues = parse_candidate_identity(mapping)
    if issues or candidate is None:
        raise AssertionError(issues)
    return candidate


def contract_for_specs(
    specs: tuple[PrerequisiteNodeSpec, ...] = DEFAULT_PREREQUISITE_SPECS,
    *,
    subject_kind: CandidateSubjectKind = CandidateSubjectKind.POST_MERGE,
    status_by_id: dict[str, PrerequisiteStatus] | None = None,
) -> SourceContract:
    status_by_id = status_by_id or {}
    candidate = candidate_for_subject(subject_kind)
    prospective_candidate = (
        candidate_for_subject(CandidateSubjectKind.PROSPECTIVE_MERGE)
        if subject_kind is CandidateSubjectKind.POST_MERGE
        else None
    )
    compiler_identity_sha256 = sha("e")
    identity_basis = SourceContract(
        schema_version=1,
        candidate=candidate,
        prospective_candidate=prospective_candidate,
        compiler_identity_sha256=compiler_identity_sha256,
        subjects=(),
    )
    subjects: list[PrerequisiteAuthority] = []
    for index, spec in enumerate(specs):
        status = status_by_id.get(spec.node_id, PrerequisiteStatus.ACCEPTED)
        claims_identity = status in {
                PrerequisiteStatus.RUNNING,
                PrerequisiteStatus.FAILED,
                PrerequisiteStatus.INVALID,
                PrerequisiteStatus.ACCEPTED,
        }
        identity_basis = replace(identity_basis, subjects=tuple(subjects))
        identity = (
            prerequisite_identity_sha256(identity_basis, spec) or sha("0")
            if claims_identity
            else None
        )
        receipt = sha(f"{index + 1:x}"[-1]) if status in {
            PrerequisiteStatus.FAILED,
            PrerequisiteStatus.INVALID,
            PrerequisiteStatus.ACCEPTED,
        } else None
        reason = (
            "unavailable-authority"
            if status is PrerequisiteStatus.UNAVAILABLE
            else "terminal-rejection"
            if status in {PrerequisiteStatus.FAILED, PrerequisiteStatus.INVALID}
            else None
        )
        subjects.append(
            PrerequisiteAuthority(
                subject_id=spec.node_id,
                owner_id=spec.owner_id,
                status=status,
                identity_sha256=identity,
                receipt_sha256=receipt,
                reason_code=reason,
            )
        )
    contract, issues = make_source_contract(
        candidate,
        prospective_candidate=prospective_candidate,
        compiler_identity_sha256=compiler_identity_sha256,
        subjects=subjects,
    )
    if issues or contract is None:
        raise AssertionError(issues)
    return contract


class PrerequisiteDAGTests(unittest.TestCase):
    def test_native_graph_has_no_release_cycle_and_bootstrap_is_not_native_pass(self):
        from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile, command_templates, CommandExecutionMode
        templates = {item.command_id: item for item in command_templates(profile=CampaignProfile.BOOTSTRAP_VERIFIER)}
        expected = {"native.normal": ("source.hosted-governance",),
            "native.asan": ("native.normal",), "native.ubsan": ("native.normal",),
            "native.golden": ("native.asan", "native.normal", "native.ubsan")}
        for command, predecessors in expected.items():
            self.assertEqual(templates[command].prerequisite_ids, predecessors)
            self.assertEqual(templates[command].execution_mode, CommandExecutionMode.RUNNABLE)
            self.assertTrue(all("release" not in key and "bootstrap" not in key for key in predecessors))
        self.assertIn("native.golden", templates["qualification.verify-bootstrap-products"].prerequisite_ids)
        self.assertIn("qualification.verify-bootstrap-fullsuite", templates["signed-xpc.supervision"].prerequisite_ids)
        visited, active = set(), set()
        def visit(command):
            self.assertNotIn(command, active, "command graph has a cycle")
            if command in visited or command not in templates:
                return
            active.add(command)
            for predecessor in templates[command].prerequisite_ids:
                visit(predecessor)
            active.remove(command)
            visited.add(command)
        for command in templates:
            visit(command)

    def test_verifier_profile_preserves_lane_c_authority(self):
        from Scripts.reconstruction_gate_f import command_catalog
        profile_type = getattr(command_catalog, "CampaignProfile", None)
        self.assertIsNotNone(profile_type, "ordinary verifier profile is missing")
        profile = profile_type.BOOTSTRAP_VERIFIER
        digest = sha("1")
        old = lane_c_command_records(digest)
        new = lane_c_command_records(digest, profile=profile)
        substitutions = {"xcode.full-coretests": "qualification.verify-bootstrap-fullsuite",
                         "release.build": "qualification.verify-bootstrap-products"}
        expected = tuple(sorted((replace(record,
            command_id=substitutions.get(record.command_id, record.command_id),
            prerequisite_ids=tuple(sorted(substitutions.get(value, value) for value in record.prerequisite_ids + (
                ("installed.task10-workflow", "installed.accessibility-semantics", "installed.source-equality", "installed.shell-smoke", "installed.emit-report")
                if record.command_id == "evidence.t10c-current-source-adjudication" else ()))))
            for record in old), key=lambda item: item.command_id))
        self.assertEqual(new, expected)
        self.assertEqual(validate_lane_c_command_catalog(new,
            expected_candidate_identity_sha256=digest, profile=profile)[1], ())
        self.assertTrue(validate_lane_c_command_catalog(new, expected_candidate_identity_sha256=digest)[1])
        self.assertTrue(validate_lane_c_command_catalog(old,
            expected_candidate_identity_sha256=digest, profile=profile)[1])

    def test_frozen_lane_c_command_authority_is_exact(self) -> None:
        self.assertEqual(len(LANE_C_COMMAND_AUTHORITIES), 46)
        self.assertEqual(len(LANE_C_COMMAND_AUTHORITIES_BY_ID), 46)
        self.assertEqual(len(LANE_C_COMMAND_GROUP_IDS), 25)
        self.assertEqual(
            {
                group
                for authority in LANE_C_COMMAND_AUTHORITIES
                for group in authority.command_groups
            },
            set(LANE_C_COMMAND_GROUP_IDS),
        )
        self.assertEqual(
            tuple(authority.command_id for authority in LANE_C_COMMAND_AUTHORITIES),
            tuple(
                sorted(
                    authority.command_id
                    for authority in LANE_C_COMMAND_AUTHORITIES
                )
            ),
        )
        self.assertEqual(
            LANE_C_COMMAND_AUTHORITY_SHA256,
            "781f5c9413722f5bd7ec79b7ac060bc5ba8dc3466eb04090c72d3073cd23aa98",
        )
        projected, issues = validate_lane_c_command_catalog(
            LANE_C_COMMAND_AUTHORITIES
        )
        self.assertEqual(issues, ())
        self.assertIsNotNone(projected)
        assert projected is not None
        self.assertEqual(dict(projected), dict(LANE_C_COMMAND_AUTHORITIES_BY_ID))
        self.assertEqual(len(LANE_C_SCENARIO_BINDINGS), 209)
        self.assertEqual(
            LANE_C_SCENARIO_BINDING_SHA256,
            "7a81f59b3c8b32f6553d59a4e87929376a0eee882a0117e9a4835d7537f67a36",
        )

    def test_lane_c_command_scenarios_and_candidate_plan_are_exact(self) -> None:
        candidate = candidate_for_subject(CandidateSubjectKind.POST_MERGE)
        candidate_digest = candidate_identity_sha256(candidate)
        plan = LaneCScenarioPlanAuthority(
            candidate_identity_sha256=candidate_digest,
            scenario_catalog_sha256=sha("a"),
            commands=lane_c_command_records(candidate_digest),
            scenario_bindings=LANE_C_SCENARIO_BINDINGS,
        )
        projected, issues = validate_lane_c_command_plan(
            plan,
            expected_candidate_identity_sha256=candidate_digest,
        )
        self.assertEqual(issues, ())
        self.assertEqual(projected, plan)
        self.assertEqual(
            LANE_C_COMMAND_PREREQUISITES["review.independent"],
            (
                "review.independent.ai-protocol-signed-xpc",
                "review.independent.corpus-package-persistence",
                "review.independent.evidence-retrieval-scheduling",
                "review.independent.scope-installed-ui-governance",
            ),
        )
        self.assertEqual(
            LANE_C_COMMAND_PREREQUISITES[
                "review.independent.ai-protocol-signed-xpc"
            ][0],
            "evidence.t10c-current-source-adjudication",
        )
        self.assertEqual(
            LANE_C_COMMAND_PREREQUISITES["merge.prospective-tree"],
            ("review.independent",),
        )
        self.assertEqual(
            COMMAND_PREREQUISITES["installed.accessibility-semantics"],
            ("installed.task10-workflow",),
        )
        self.assertEqual(
            LANE_C_COMMAND_PREREQUISITES["installed.accessibility-semantics"],
            ("installed.task10-workflow",),
        )
        self.assertEqual(
            LANE_C_COMMAND_PREREQUISITES["postmerge.exact-tree-proof"],
            ("merge.prospective-tree",),
        )

        drifted_command = replace(
            LANE_C_COMMAND_AUTHORITIES[0],
            scenario_ids=LANE_C_COMMAND_AUTHORITIES[0].scenario_ids[:-1],
        )
        _, issues = validate_lane_c_command_catalog(
            (drifted_command, *LANE_C_COMMAND_AUTHORITIES[1:])
        )
        self.assertIn(
            "lane-c-command-catalog-mismatch",
            {issue.code for issue in issues},
        )

        _, issues = validate_lane_c_command_plan(
            replace(plan, scenario_bindings=tuple(reversed(plan.scenario_bindings))),
            expected_candidate_identity_sha256=candidate_digest,
        )
        self.assertIn(
            "lane-c-scenario-plan-mismatch",
            {issue.code for issue in issues},
        )
        _, issues = validate_lane_c_command_plan(
            replace(plan, commands=tuple(reversed(plan.commands))),
            expected_candidate_identity_sha256=candidate_digest,
        )
        self.assertIn(
            "lane-c-command-order",
            {issue.code for issue in issues},
        )
        review_index = next(
            index
            for index, command in enumerate(plan.commands)
            if command.command_id == "review.independent"
        )
        review = plan.commands[review_index]
        for label, prerequisite_ids, expected_issue in (
            (
                "deletion",
                review.prerequisite_ids[1:],
                "lane-c-command-catalog-mismatch",
            ),
            (
                "reversal",
                tuple(reversed(review.prerequisite_ids)),
                "command-catalog-entry-shape",
            ),
            (
                "cycle",
                ("postmerge.exact-tree-proof",),
                "lane-c-command-catalog-mismatch",
            ),
        ):
            with self.subTest(f"command-prerequisite-{label}"):
                mutated_review = replace(
                    review,
                    prerequisite_ids=prerequisite_ids,
                )
                commands = list(plan.commands)
                commands[review_index] = mutated_review
                _, issues = validate_lane_c_command_plan(
                    replace(plan, commands=tuple(commands)),
                    expected_candidate_identity_sha256=candidate_digest,
                )
                self.assertIn(
                    expected_issue,
                    {issue.code for issue in issues},
                )
        _, issues = validate_lane_c_command_plan(
            replace(plan, candidate_identity_sha256=sha("b")),
            expected_candidate_identity_sha256=candidate_digest,
        )
        self.assertIn(
            "scenario-plan-candidate-mismatch",
            {issue.code for issue in issues},
        )

    def test_every_default_node_has_an_exact_group_and_layer_command(self) -> None:
        for spec in DEFAULT_PREREQUISITE_SPECS:
            eligible = tuple(
                authority
                for authority in LANE_C_COMMAND_AUTHORITIES
                if authority.evidence_layer in spec.required_evidence_layers
                and bool(
                    set(authority.command_groups) & set(spec.command_group_ids)
                )
            )
            with self.subTest(spec.node_id):
                self.assertTrue(
                    eligible,
                    msg=(
                        f"{spec.node_id} has no Lane C command with both an "
                        "owned command group and an exact required layer"
                    ),
                )
                for authority in eligible:
                    self.assertIn(
                        authority.evidence_layer,
                        spec.required_evidence_layers,
                    )
                    self.assertTrue(
                        set(authority.command_groups)
                        & set(spec.command_group_ids)
                    )

    def test_early_t10c_adjudication_is_not_late_independent_review(self) -> None:
        by_id = {spec.node_id: spec for spec in DEFAULT_PREREQUISITE_SPECS}
        early = by_id["t10c-current-source-adjudicated"]
        self.assertEqual(
            early.required_evidence_layers,
            (EvidenceLayer.XCODE_FOCUSED,),
        )
        self.assertEqual(early.command_group_ids, ("reconstruction-task10",))

        early_command_ids = {
            authority.command_id
            for authority in LANE_C_COMMAND_AUTHORITIES
            if authority.evidence_layer in early.required_evidence_layers
            and set(authority.command_groups) & set(early.command_group_ids)
        }
        self.assertEqual(
            early_command_ids,
            {
                "xcode.focused.task10-projection",
                "xcode.focused.task10-state-machine",
            },
        )

        late_t10c = LANE_C_COMMAND_AUTHORITIES_BY_ID[
            "evidence.t10c-current-source-adjudication"
        ]
        self.assertEqual(
            late_t10c.evidence_layer,
            EvidenceLayer.INDEPENDENT_REVIEW,
        )
        self.assertEqual(
            late_t10c.command_groups,
            ("reconstruction-task10",),
        )
        self.assertNotIn(late_t10c.command_id, early_command_ids)

        final_review = by_id["independent-review-remediated"]
        self.assertEqual(
            final_review.required_evidence_layers,
            (EvidenceLayer.INDEPENDENT_REVIEW,),
        )
        self.assertEqual(final_review.command_group_ids, ("merge-qualification",))
        final_command = LANE_C_COMMAND_AUTHORITIES_BY_ID["review.independent"]
        self.assertEqual(
            final_command.evidence_layer,
            EvidenceLayer.INDEPENDENT_REVIEW,
        )
        self.assertEqual(final_command.command_groups, ("merge-qualification",))

    def test_default_graph_freezes_every_required_nonaggregate_subject(self) -> None:
        required = {
            "task6-remediation-accepted",
            "task8-evidence-integrated",
            "task9-regression-ready",
            "t10a-archive-verified",
            "t10c-current-source-adjudicated",
            "task10-rebased-corrected-task6",
            "task10-final-composition",
            "gatef-compiler-identity",
            "exact-head-focused-tests",
            "exact-head-full-tests",
            "independent-review-remediated",
            "prospective-merge-qualified",
            "merge-authorized",
            "accepted-merge",
            "postmerge-proof",
            "increment2-stop-boundary",
        }
        self.assertEqual({spec.node_id for spec in DEFAULT_PREREQUISITE_SPECS}, required)
        self.assertGreaterEqual(len(DEFAULT_PREREQUISITE_SPECS), 14)
        for spec in DEFAULT_PREREQUISITE_SPECS:
            with self.subTest(spec.node_id):
                self.assertEqual(spec.schema_version, 1)
                self.assertTrue(spec.source_authority)
                self.assertTrue(spec.required_identity_paths)
                self.assertTrue(spec.required_evidence_layers)
                self.assertEqual(spec.allowed_skip_ids, ())
                self.assertTrue(spec.command_group_ids)
                self.assertTrue(spec.receipt_output_ids)
                self.assertTrue(spec.artifact_output_ids)
                self.assertTrue(spec.invalidation_rules)
        stop = next(
            spec
            for spec in DEFAULT_PREREQUISITE_SPECS
            if spec.node_id == "increment2-stop-boundary"
        )
        self.assertEqual(stop.stage, PrerequisiteStage.POSTMERGE)
        self.assertEqual(stop.stop_condition, "stop-before-reconstruction-increment-2")

    def test_compiles_deterministically_from_supplied_candidate_contract(self) -> None:
        contract = contract_for_specs()
        first, issues = compile_prerequisite_dag(contract)
        self.assertEqual(issues, ())
        self.assertIsNotNone(first)
        second, issues = compile_prerequisite_dag(
            contract,
            tuple(reversed(DEFAULT_PREREQUISITE_SPECS)),
        )
        self.assertEqual(issues, ())
        self.assertIsNotNone(second)
        assert first is not None and second is not None
        self.assertEqual(first.topological_order, second.topological_order)
        self.assertEqual(
            tuple(node.spec.node_id for node in first.nodes),
            tuple(node.spec.node_id for node in second.nodes),
        )
        self.assertEqual(
            source_contract_candidate_sha256(contract),
            candidate_identity_sha256(contract.candidate),
        )
        self.assertEqual(first.source_contract_sha256, source_contract_sha256(contract))

    def test_subject_order_does_not_change_source_contract_or_dag_identity(self) -> None:
        contract = contract_for_specs()
        reversed_contract = replace(
            contract,
            subjects=tuple(reversed(contract.subjects)),
        )
        self.assertEqual(
            source_contract_sha256(contract),
            source_contract_sha256(reversed_contract),
        )

        first, first_issues = compile_prerequisite_dag(contract)
        second, second_issues = compile_prerequisite_dag(reversed_contract)
        self.assertEqual(first_issues, ())
        self.assertEqual(second_issues, ())
        self.assertIsNotNone(first)
        self.assertIsNotNone(second)
        assert first is not None and second is not None
        self.assertEqual(first, second)

    def test_malformed_direct_source_contract_subject_is_issue_not_exception(self) -> None:
        contract = contract_for_specs()
        malformed = replace(
            contract,
            subjects=([], *contract.subjects[1:]),
        )
        first, first_issues = compile_prerequisite_dag(malformed)
        second, second_issues = compile_prerequisite_dag(malformed)
        self.assertIsNone(first)
        self.assertIsNone(second)
        self.assertEqual(first_issues, second_issues)
        self.assertIn("record-type", {issue.code for issue in first_issues})

        cyclic_subjects: list[object] = []
        cyclic_subjects.append(cyclic_subjects)
        cyclic = replace(contract, subjects=cyclic_subjects)
        compiled, issues = compile_prerequisite_dag(cyclic)
        self.assertIsNone(compiled)
        self.assertIn(
            "source-contract-canonicalization",
            {issue.code for issue in issues},
        )

        cyclic_helper_subjects: list[object] = []
        cyclic_helper_subjects.append(cyclic_helper_subjects)
        built, helper_issues = make_source_contract(
            contract.candidate,
            compiler_identity_sha256=contract.compiler_identity_sha256,
            subjects=cyclic_helper_subjects,
        )
        self.assertIsNone(built)
        self.assertIn(
            "source-contract-subject-type",
            {issue.code for issue in helper_issues},
        )

    def test_malformed_node_collection_fails_closed_before_graph_hashing(self) -> None:
        cases = (
            ("prerequisites", ([],), "prerequisite-node-field-shape"),
            ("required_identity_paths", (1,), "stable-id"),
            ("command_group_ids", (1,), "stable-id"),
        )
        for field_name, malformed_value, expected in cases:
            with self.subTest(field_name):
                malformed = (
                    replace(
                        DEFAULT_PREREQUISITE_SPECS[0],
                        **{field_name: malformed_value},
                    ),
                    *DEFAULT_PREREQUISITE_SPECS[1:],
                )
                dag, issues = compile_prerequisite_dag(
                    contract_for_specs(),
                    malformed,
                )
                self.assertIsNone(dag)
                self.assertIn(expected, {issue.code for issue in issues})

        recursive_scalar: list[object] = []
        recursive_scalar.append(recursive_scalar)
        for field_name in ("schema_version", "source_authority"):
            for value_kind, malformed_scalar in (
                ("recursive", recursive_scalar),
                ("opaque", object()),
            ):
                with self.subTest(f"{value_kind}-{field_name}"):
                    malformed = (
                        replace(
                            DEFAULT_PREREQUISITE_SPECS[0],
                            **{field_name: malformed_scalar},
                        ),
                        *DEFAULT_PREREQUISITE_SPECS[1:],
                    )
                    first, first_issues = compile_prerequisite_dag(
                        contract_for_specs(),
                        malformed,
                    )
                    second, second_issues = compile_prerequisite_dag(
                        contract_for_specs(),
                        malformed,
                    )
                    self.assertIsNone(first)
                    self.assertIsNone(second)
                    self.assertEqual(first_issues, second_issues)
                    self.assertIn(
                        "prerequisite-node-scalar-shape",
                        {issue.code for issue in first_issues},
                    )

    def test_task10_and_terminal_spine_edges_are_explicit(self) -> None:
        by_id = {spec.node_id: spec for spec in DEFAULT_PREREQUISITE_SPECS}
        self.assertIn(
            "task6-remediation-accepted",
            by_id["task10-rebased-corrected-task6"].prerequisites,
        )
        self.assertEqual(
            set(by_id["task10-final-composition"].prerequisites),
            {
                "task8-evidence-integrated",
                "task9-regression-ready",
                "t10c-current-source-adjudicated",
                "task10-rebased-corrected-task6",
            },
        )
        spine = (
            ("exact-head-full-tests", "independent-review-remediated"),
            ("independent-review-remediated", "prospective-merge-qualified"),
            ("prospective-merge-qualified", "merge-authorized"),
            ("merge-authorized", "accepted-merge"),
            ("accepted-merge", "postmerge-proof"),
            ("postmerge-proof", "increment2-stop-boundary"),
        )
        for prerequisite, dependent in spine:
            with self.subTest(dependent):
                self.assertIn(prerequisite, by_id[dependent].prerequisites)

    def test_semantic_evidence_axes_are_explicit_for_task8_t10a_and_t10c(self) -> None:
        by_id = {spec.node_id: spec for spec in DEFAULT_PREREQUISITE_SPECS}
        expected = {
            "task8-evidence-integrated": "semantic-prerequisite.task-8.evidence_sha256",
            "t10a-archive-verified": "semantic-prerequisite.t10a.evidence_sha256",
            "t10c-current-source-adjudicated": "semantic-prerequisite.t10c.evidence_sha256",
        }
        for node_id, identity_path in expected.items():
            with self.subTest(node_id):
                self.assertIn(identity_path, by_id[node_id].required_identity_paths)

    def test_source_contract_is_closed_and_rejects_false_authority(self) -> None:
        contract = contract_for_specs()
        mutations = []

        missing_receipt = source_contract_to_mapping(contract)
        missing_receipt["subjects"][0]["receipt_sha256"] = None
        mutations.append((missing_receipt, "accepted-authority-incomplete"))

        unavailable_with_identity = source_contract_to_mapping(contract)
        unavailable_with_identity["subjects"][0]["status"] = "unavailable"
        unavailable_with_identity["subjects"][0]["reason_code"] = "executor-unavailable"
        mutations.append((unavailable_with_identity, "unavailable-authority-contradiction"))

        dirty = source_contract_to_mapping(contract)
        dirty["candidate_identity"]["source"]["dirty"] = True
        mutations.append((dirty, "candidate-dirty"))

        unknown = source_contract_to_mapping(contract)
        unknown["moving_branch_success"] = True
        mutations.append((unknown, "unknown-field"))

        for value, expected in mutations:
            with self.subTest(expected):
                parsed, issues = parse_source_contract(value)
                self.assertIsNone(parsed)
                self.assertIn(expected, {issue.code for issue in issues})

    def test_rejects_cycle(self) -> None:
        cycle_target = "task10-rebased-corrected-task6"
        mutated = (
            replace(DEFAULT_PREREQUISITE_SPECS[0], prerequisites=(cycle_target,)),
            *DEFAULT_PREREQUISITE_SPECS[1:],
        )
        contract = contract_for_specs(mutated)
        dag, issues = compile_prerequisite_dag(contract, mutated)
        self.assertIsNone(dag)
        self.assertIn("prerequisite-cycle", {issue.code for issue in issues})

    def test_rejects_missing_mandatory_subject_or_edge(self) -> None:
        missing_node = DEFAULT_PREREQUISITE_SPECS[1:]
        contract = contract_for_specs(missing_node)
        dag, issues = compile_prerequisite_dag(contract, missing_node)
        self.assertIsNone(dag)
        self.assertIn(
            "missing-mandatory-prerequisite",
            {issue.code for issue in issues},
        )

        composition_index = next(
            index
            for index, spec in enumerate(DEFAULT_PREREQUISITE_SPECS)
            if spec.node_id == "task10-final-composition"
        )
        composition = DEFAULT_PREREQUISITE_SPECS[composition_index]
        mutated = list(DEFAULT_PREREQUISITE_SPECS)
        mutated[composition_index] = replace(
            composition,
            prerequisites=tuple(
                prerequisite
                for prerequisite in composition.prerequisites
                if prerequisite != "task8-evidence-integrated"
            ),
        )
        mutated_tuple = tuple(mutated)
        contract = contract_for_specs(mutated_tuple)
        dag, issues = compile_prerequisite_dag(contract, mutated_tuple)
        self.assertIsNone(dag)
        self.assertIn(
            "missing-mandatory-prerequisite-edge",
            {issue.code for issue in issues},
        )

    def test_rejects_semantic_weakening_of_a_mandatory_node(self) -> None:
        task8_index = next(
            index
            for index, spec in enumerate(DEFAULT_PREREQUISITE_SPECS)
            if spec.node_id == "task8-evidence-integrated"
        )
        task8 = DEFAULT_PREREQUISITE_SPECS[task8_index]
        mutated = list(DEFAULT_PREREQUISITE_SPECS)
        mutated[task8_index] = replace(
            task8,
            required_identity_paths=("candidate.identity_sha256",),
            required_evidence_layers=(EvidenceLayer.SOURCE_GOVERNANCE,),
        )
        mutated_tuple = tuple(mutated)
        contract = contract_for_specs(mutated_tuple)
        dag, issues = compile_prerequisite_dag(contract, mutated_tuple)
        self.assertIsNone(dag)
        self.assertIn(
            "mandatory-prerequisite-contract-drift",
            {issue.code for issue in issues},
        )

    def test_rejects_unknown_edge(self) -> None:
        mutated = (
            replace(
                DEFAULT_PREREQUISITE_SPECS[0],
                prerequisites=("not-a-real-prerequisite",),
            ),
            *DEFAULT_PREREQUISITE_SPECS[1:],
        )
        contract = contract_for_specs(mutated)
        dag, issues = compile_prerequisite_dag(contract, mutated)
        self.assertIsNone(dag)
        self.assertIn("unknown-prerequisite-edge", {issue.code for issue in issues})

    def test_rejects_dependency_on_a_later_qualification_stage(self) -> None:
        mutated = (
            *DEFAULT_PREREQUISITE_SPECS[:-1],
            replace(
                DEFAULT_PREREQUISITE_SPECS[-1],
                stage=PrerequisiteStage.PREMERGE,
            ),
        )
        contract = contract_for_specs(mutated)
        dag, issues = compile_prerequisite_dag(contract, mutated)
        self.assertIsNone(dag)
        self.assertIn("prerequisite-stage-order", {issue.code for issue in issues})

    def test_rejects_unknown_required_identity_path_before_it_can_be_claimed(self) -> None:
        first = DEFAULT_PREREQUISITE_SPECS[0]
        mutated = (
            replace(
                first,
                required_identity_paths=(
                    *first.required_identity_paths,
                    "source.not-a-real-identity",
                ),
            ),
            *DEFAULT_PREREQUISITE_SPECS[1:],
        )
        status_by_id = {
            spec.node_id: PrerequisiteStatus.NOT_RUN
            for spec in mutated
        }
        contract = contract_for_specs(mutated, status_by_id=status_by_id)
        dag, issues = compile_prerequisite_dag(contract, mutated)
        self.assertIsNone(dag)
        self.assertIn("unknown-required-identity", {issue.code for issue in issues})

    def test_rejects_duplicate_node_ownership(self) -> None:
        owner = DEFAULT_PREREQUISITE_SPECS[0].owner_id
        mutated = (
            DEFAULT_PREREQUISITE_SPECS[0],
            replace(DEFAULT_PREREQUISITE_SPECS[1], owner_id=owner),
            *DEFAULT_PREREQUISITE_SPECS[2:],
        )
        contract = contract_for_specs()
        dag, issues = compile_prerequisite_dag(contract, mutated)
        self.assertIsNone(dag)
        self.assertIn("duplicate-ownership", {issue.code for issue in issues})

    def test_rejects_accepted_node_above_unaccepted_dependency(self) -> None:
        status_by_id = {
            spec.node_id: PrerequisiteStatus.ACCEPTED
            for spec in DEFAULT_PREREQUISITE_SPECS
        }
        status_by_id["task6-remediation-accepted"] = PrerequisiteStatus.NOT_RUN
        contract = contract_for_specs(status_by_id=status_by_id)
        dag, issues = compile_prerequisite_dag(contract)
        self.assertIsNone(dag)
        self.assertIn("contradictory-prerequisite-state", {issue.code for issue in issues})

    def test_rejects_claimed_merge_authority_when_exact_identity_is_unavailable(self) -> None:
        status_by_id = {
            spec.node_id: (
                PrerequisiteStatus.ACCEPTED
                if spec.stage in {PrerequisiteStage.PREMERGE, PrerequisiteStage.MERGE}
                else PrerequisiteStatus.NOT_RUN
            )
            for spec in DEFAULT_PREREQUISITE_SPECS
        }
        contract = contract_for_specs(
            subject_kind=CandidateSubjectKind.PROSPECTIVE_MERGE,
            status_by_id=status_by_id,
        )
        dag, issues = compile_prerequisite_dag(contract)
        self.assertIsNone(dag)
        self.assertIn("unavailable-required-identity", {issue.code for issue in issues})

    def test_rejects_prerequisite_digest_drifting_from_required_identity_axes(self) -> None:
        contract = contract_for_specs()
        first = contract.subjects[0]
        mutated = replace(
            contract,
            subjects=(
                replace(first, identity_sha256=sha("f")),
                *contract.subjects[1:],
            ),
        )
        dag, issues = compile_prerequisite_dag(mutated)
        self.assertIsNone(dag)
        self.assertIn("required-identity-digest-mismatch", {issue.code for issue in issues})

    def test_dependency_receipt_movement_invalidates_downstream_identity(self) -> None:
        contract = contract_for_specs()
        task6 = next(
            subject
            for subject in contract.subjects
            if subject.subject_id == "task6-remediation-accepted"
        )
        mutated = replace(
            contract,
            subjects=tuple(
                replace(subject, receipt_sha256=sha("f"))
                if subject.subject_id == task6.subject_id
                else subject
                for subject in contract.subjects
            ),
        )
        dag, issues = compile_prerequisite_dag(mutated)
        self.assertIsNone(dag)
        self.assertIn(
            "required-identity-digest-mismatch",
            {issue.code for issue in issues},
        )

    def test_premerge_node_identity_survives_honest_postmerge_transition(self) -> None:
        premerge_status = {
            spec.node_id: (
                PrerequisiteStatus.ACCEPTED
                if spec.stage is PrerequisiteStage.PREMERGE
                else PrerequisiteStatus.NOT_RUN
            )
            for spec in DEFAULT_PREREQUISITE_SPECS
        }
        prospective = contract_for_specs(
            subject_kind=CandidateSubjectKind.PROSPECTIVE_MERGE,
            status_by_id=premerge_status,
        )
        postmerge = contract_for_specs(subject_kind=CandidateSubjectKind.POST_MERGE)
        prospective_by_id = {
            subject.subject_id: subject for subject in prospective.subjects
        }
        postmerge_by_id = {subject.subject_id: subject for subject in postmerge.subjects}
        for spec in DEFAULT_PREREQUISITE_SPECS:
            if spec.stage is PrerequisiteStage.PREMERGE:
                with self.subTest(spec.node_id):
                    self.assertEqual(
                        prospective_by_id[spec.node_id].identity_sha256,
                        postmerge_by_id[spec.node_id].identity_sha256,
                    )

    def test_postmerge_contract_rejects_tree_or_prospective_lineage_drift(self) -> None:
        contract = contract_for_specs()
        tree_drift = source_contract_to_mapping(contract)
        tree_drift["candidate_identity"]["accepted_postmerge_tree"] = git_object("f")
        parsed, issues = parse_source_contract(tree_drift)
        self.assertIsNone(parsed)
        self.assertIn("merge-tree-drift", {issue.code for issue in issues})

        lineage_drift = source_contract_to_mapping(contract)
        lineage_drift["prospective_candidate_identity"]["source"]["tree"] = git_object("f")
        parsed, issues = parse_source_contract(lineage_drift)
        self.assertIsNone(parsed)
        self.assertIn(
            "prospective-candidate-lineage-drift",
            {issue.code for issue in issues},
        )


if __name__ == "__main__":
    unittest.main()
