import Foundation
import XCTest
@testable import MacScope

final class AnalystFindingRevisionTests: XCTestCase {
    /// Test-only fields: the production mechanism does not define or interpret these concepts.
    private struct Content: Equatable, Sendable {
        let text: String
        let metadata: [String: String]
        let originalBytes: Data
        let authoredKind: String
        let evidenceBasis: String
        let dependencies: [String]
        let freshness: String
    }
    private typealias State = AnalystFindingRevisionState<Content, String>
    private let identity = AnalystFindingRevisionIdentity(findingID: UUID(), workspaceID: UUID(), documentID: UUID())

    private func content(_ text: String) -> Content {
        .init(text: text, metadata: ["format": "test-rich-text", "annotation": "α\nβ"],
              originalBytes: Data([0, 255, 13, 10]), authoredKind: "interpretation",
              evidenceBasis: "caller-reference", dependencies: ["original-evidence-1", "facet-2"],
              freshness: "stale")
    }

    func testContentEditPreservesOpaquePayloadAndInvalidatesReviewWithoutErasingBinding() throws {
        let initial = State(identity: identity, content: content("Original"))
        let unreviewedEdit = try AnalystFindingRevision.applyContentEdit(current: initial, identity: identity,
            expected: .init(content: 1, review: 0), replacement: content("Unreviewed edit")).after
        XCTAssertEqual(unreviewedEdit.revisions, .init(content: 2, review: 0))
        XCTAssertNil(unreviewedEdit.review)
        XCTAssertFalse(unreviewedEdit.isReviewCurrent)
        let reviewed = try AnalystFindingRevision.applyReview(current: initial, identity: identity,
            expected: .init(content: 1, review: 0), decision: "caller decision").after
        let replacement = content(String(repeating: "Long canonical content\n", count: 2048) + "End Ω")
        let transition = try AnalystFindingRevision.applyContentEdit(current: reviewed, identity: identity,
            expected: .init(content: 1, review: 1), replacement: replacement)
        XCTAssertEqual(transition.before, reviewed)
        XCTAssertEqual(transition.after.identity, identity)
        XCTAssertEqual(transition.after.content, replacement)
        XCTAssertEqual(transition.after.revisions, .init(content: 2, review: 1))
        XCTAssertEqual(transition.after.review, reviewed.review)
        XCTAssertFalse(transition.after.isReviewCurrent)
        XCTAssertTrue(reviewed.isReviewCurrent)
        XCTAssertEqual(reviewed.content, content("Original"))
    }

    func testIdentityOrEitherStaleRevisionRefusesWholeTransition() throws {
        let original = State(identity: identity, content: content("Original"))
        let replacements = [
            AnalystFindingRevisionIdentity(findingID: UUID(), workspaceID: identity.workspaceID, documentID: identity.documentID),
            AnalystFindingRevisionIdentity(findingID: identity.findingID, workspaceID: UUID(), documentID: identity.documentID),
            AnalystFindingRevisionIdentity(findingID: identity.findingID, workspaceID: identity.workspaceID, documentID: UUID())
        ]
        for wrongIdentity in replacements {
            XCTAssertThrowsError(try AnalystFindingRevision.applyContentEdit(current: original,
                identity: wrongIdentity, expected: .init(content: 0, review: 0), replacement: content("New"))) {
                XCTAssertEqual($0 as? AnalystFindingRevisionError, .identityMismatch)
            }
            XCTAssertThrowsError(try AnalystFindingRevision.applyReview(current: original,
                identity: wrongIdentity, expected: .init(content: 1, review: 0), decision: "new")) {
                XCTAssertEqual($0 as? AnalystFindingRevisionError, .identityMismatch)
            }
        }
        for expected in [AnalystFindingRevisionVector(content: 0, review: 0), .init(content: 1, review: 1)] {
            XCTAssertThrowsError(try AnalystFindingRevision.applyContentEdit(current: original,
                identity: identity, expected: expected, replacement: content("New"))) {
                XCTAssertEqual($0 as? AnalystFindingRevisionError,
                    .staleRevision(expected: expected, actual: .init(content: 1, review: 0)))
            }
            XCTAssertThrowsError(try AnalystFindingRevision.applyReview(current: original,
                identity: identity, expected: expected, decision: "new")) {
                XCTAssertEqual($0 as? AnalystFindingRevisionError,
                    .staleRevision(expected: expected, actual: .init(content: 1, review: 0)))
            }
        }
        XCTAssertEqual(original.revisions, .init(content: 1, review: 0))
        XCTAssertEqual(original.content, content("Original"))
        XCTAssertNil(original.review)
    }

    func testReviewBindsExactContentAndPreservesBothDecisionsInTransition() throws {
        let initial = State(identity: identity, content: content("Original"))
        let first = try AnalystFindingRevision.applyReview(current: initial, identity: identity,
            expected: .init(content: 1, review: 0), decision: "first")
        XCTAssertEqual(first.after.review, .init(decision: "first", contentRevision: 1,
            reviewRevision: 1, previousReviewRevision: nil))
        let edited = try AnalystFindingRevision.applyContentEdit(current: first.after, identity: identity,
            expected: .init(content: 1, review: 1), replacement: content("Edited")).after
        let second = try AnalystFindingRevision.applyReview(current: edited, identity: identity,
            expected: .init(content: 2, review: 1), decision: "second")
        XCTAssertEqual(second.before, edited)
        XCTAssertEqual(second.before.review?.decision, "first")
        XCTAssertEqual(second.after.review, .init(decision: "second", contentRevision: 2,
            reviewRevision: 2, previousReviewRevision: 1))
        XCTAssertEqual(second.after.content, content("Edited"))
        XCTAssertEqual(second.after.identity, identity)
        XCTAssertEqual(second.after.revisions, .init(content: 2, review: 2))
        XCTAssertTrue(second.after.isReviewCurrent)
        let repeated = try AnalystFindingRevision.applyReview(current: second.after, identity: identity,
            expected: .init(content: 2, review: 2), decision: "second")
        XCTAssertEqual(repeated.after.revisions, .init(content: 2, review: 3))
        XCTAssertEqual(repeated.before.review?.decision, "second")
        XCTAssertEqual(repeated.after.review?.previousReviewRevision, 2)
    }

    func testValidatingStateRejectsBrokenBindingAndLineage() throws {
        typealias Binding = AnalystFindingReviewBinding<String>
        let invalid: [(AnalystFindingRevisionVector, Binding?)] = [
            (.init(content: 0, review: 0), nil),
            (.init(content: 1, review: 1), nil),
            (.init(content: 1, review: 0), .init(decision: "x", contentRevision: 1, reviewRevision: 0, previousReviewRevision: nil)),
            (.init(content: 1, review: 2), .init(decision: "x", contentRevision: 1, reviewRevision: 1, previousReviewRevision: nil)),
            (.init(content: 1, review: 1), .init(decision: "x", contentRevision: 0, reviewRevision: 1, previousReviewRevision: nil)),
            (.init(content: 1, review: 1), .init(decision: "x", contentRevision: 2, reviewRevision: 1, previousReviewRevision: nil)),
            (.init(content: 1, review: 1), .init(decision: "x", contentRevision: 1, reviewRevision: 1, previousReviewRevision: 0)),
            (.init(content: 1, review: 2), .init(decision: "x", contentRevision: 1, reviewRevision: 2, previousReviewRevision: nil)),
            (.init(content: 1, review: 2), .init(decision: "x", contentRevision: 1, reviewRevision: 2, previousReviewRevision: 2))
        ]
        for (revisions, review) in invalid {
            XCTAssertThrowsError(try State(identity: identity, content: content("Full"), revisions: revisions, review: review)) {
                XCTAssertEqual($0 as? AnalystFindingRevisionError, .invalidState)
            }
        }
        let unreviewed = try State(identity: identity, content: content("Edited"),
            revisions: .init(content: 9, review: 0), review: nil)
        XCTAssertFalse(unreviewed.isReviewCurrent)
        let historical = try State(identity: identity, content: content("Edited"),
            revisions: .init(content: 9, review: 2),
            review: .init(decision: "prior", contentRevision: 3, reviewRevision: 2, previousReviewRevision: 1))
        XCTAssertFalse(historical.isReviewCurrent)
        XCTAssertEqual(historical.review?.decision, "prior")
    }

    func testExhaustionAndUnchangedEditRefuseWithoutWrapping() throws {
        let nearlyMax = try State(identity: identity, content: content("Original"),
            revisions: .init(content: UInt64.max - 1, review: UInt64.max - 1),
            review: .init(decision: "near limit", contentRevision: UInt64.max - 1,
                reviewRevision: UInt64.max - 1, previousReviewRevision: UInt64.max - 2))
        let lastEdit = try AnalystFindingRevision.applyContentEdit(current: nearlyMax, identity: identity,
            expected: nearlyMax.revisions, replacement: content("Last edit")).after
        XCTAssertEqual(lastEdit.revisions, .init(content: .max, review: UInt64.max - 1))
        let lastReview = try AnalystFindingRevision.applyReview(current: lastEdit, identity: identity,
            expected: .init(content: .max, review: UInt64.max - 1), decision: "last review").after
        XCTAssertEqual(lastReview.revisions, .init(content: .max, review: .max))
        XCTAssertEqual(lastReview.review?.previousReviewRevision, UInt64.max - 1)
        XCTAssertTrue(lastReview.isReviewCurrent)
        let contentMax = try State(identity: identity, content: content("Original"),
            revisions: .init(content: .max, review: 0), review: nil)
        XCTAssertThrowsError(try AnalystFindingRevision.applyContentEdit(current: contentMax, identity: identity,
            expected: .init(content: .max, review: 0), replacement: content("New"))) {
            XCTAssertEqual($0 as? AnalystFindingRevisionError, .contentRevisionExhausted)
        }
        let reviewMax = try State(identity: identity, content: content("Original"),
            revisions: .init(content: 1, review: .max),
            review: .init(decision: "last", contentRevision: 1, reviewRevision: .max, previousReviewRevision: UInt64.max - 1))
        XCTAssertThrowsError(try AnalystFindingRevision.applyReview(current: reviewMax, identity: identity,
            expected: .init(content: 1, review: .max), decision: "next")) {
            XCTAssertEqual($0 as? AnalystFindingRevisionError, .reviewRevisionExhausted)
        }
        XCTAssertThrowsError(try AnalystFindingRevision.applyContentEdit(current: contentMax, identity: identity,
            expected: .init(content: .max, review: 0), replacement: contentMax.content)) {
            XCTAssertEqual($0 as? AnalystFindingRevisionError, .unchangedContent)
        }
        let reviewAtMaxContent = try AnalystFindingRevision.applyReview(current: contentMax, identity: identity,
            expected: .init(content: .max, review: 0), decision: "allowed").after
        XCTAssertEqual(reviewAtMaxContent.revisions, .init(content: .max, review: 1))
        XCTAssertTrue(reviewAtMaxContent.isReviewCurrent)
        let editAtMaxReview = try AnalystFindingRevision.applyContentEdit(current: reviewMax, identity: identity,
            expected: .init(content: 1, review: .max), replacement: content("New")).after
        XCTAssertEqual(editAtMaxReview.revisions, .init(content: 2, review: .max))
        XCTAssertEqual(editAtMaxReview.review, reviewMax.review)
        XCTAssertFalse(editAtMaxReview.isReviewCurrent)
        XCTAssertEqual(contentMax.revisions, .init(content: .max, review: 0))
        XCTAssertEqual(reviewMax.revisions, .init(content: 1, review: .max))
    }

    func testReviewDoesNotReclassifyCallerContentAndOldVectorCannotReplay() throws {
        let original = State(identity: identity, content: content("Interpretation"))
        let reviewed = try AnalystFindingRevision.applyReview(current: original, identity: identity,
            expected: .init(content: 1, review: 0), decision: "opaque rejected decision").after
        XCTAssertEqual(reviewed.content, content("Interpretation"))
        // Current means revision-bound, not endorsement, evidence acceptance or freshness.
        XCTAssertTrue(reviewed.isReviewCurrent)
        let edited = try AnalystFindingRevision.applyContentEdit(current: reviewed, identity: identity,
            expected: .init(content: 1, review: 1), replacement: content("New interpretation")).after
        for old in [original.revisions, reviewed.revisions] {
            XCTAssertThrowsError(try AnalystFindingRevision.applyReview(current: edited, identity: identity,
                expected: old, decision: "replay")) {
                XCTAssertEqual($0 as? AnalystFindingRevisionError,
                    .staleRevision(expected: old, actual: .init(content: 2, review: 1)))
            }
            XCTAssertThrowsError(try AnalystFindingRevision.applyContentEdit(current: edited, identity: identity,
                expected: old, replacement: content("Replay"))) {
                XCTAssertEqual($0 as? AnalystFindingRevisionError,
                    .staleRevision(expected: old, actual: .init(content: 2, review: 1)))
            }
        }
        XCTAssertEqual(edited.content.freshness, "stale")
        XCTAssertEqual(edited.content.authoredKind, "interpretation")
        XCTAssertEqual(edited.content.evidenceBasis, "caller-reference")
        XCTAssertEqual(edited.content.dependencies, ["original-evidence-1", "facet-2"])
    }
}
