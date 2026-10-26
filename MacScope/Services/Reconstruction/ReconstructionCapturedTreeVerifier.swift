import Foundation

/// Pure accounting and traversal planning for a filesystem tree whose facts have already been
/// captured. Live descriptor reads remain the importer's responsibility.
struct ReconstructionCapturedTreeVerifier {
    enum NodeKind: Sendable, Equatable {
        case directory
        case regularFile
        case symbolicLink
    }

    struct Limits: Sendable, Equatable {
        static let importerDefault = Limits(
            maximumExpandedPathUTF8Bytes: 64 * 1_024 * 1_024,
            maximumExpandedComponentWork: 1_000_000
        )

        let maximumExpandedPathUTF8Bytes: Int
        let maximumExpandedComponentWork: Int

        init(
            maximumExpandedPathUTF8Bytes: Int,
            maximumExpandedComponentWork: Int
        ) {
            self.maximumExpandedPathUTF8Bytes = maximumExpandedPathUTF8Bytes
            self.maximumExpandedComponentWork = maximumExpandedComponentWork
        }
    }

    enum VerificationError: Error, Equatable {
        case invalidLimits
        case invalidTree
        case invalidComponent
        case expandedPathUTF8ByteLimitExceeded
        case expandedComponentWorkLimitExceeded
    }

    struct Plan: Sendable, Equatable {
        struct Node: Sendable, Equatable {
            let parentIndex: Int?
            let firstChildIndex: Int?
            let nextSiblingIndex: Int?
            let rawComponent: String?
            let normalizedComponent: String?
            let kind: NodeKind
            let depth: Int
            let relativePathUTF8ByteCount: Int
        }

        let nodes: [Node]
        let expandedPathUTF8ByteCount: Int
        let expandedComponentWork: Int
    }

    /// Observes descriptor-relative edges only after the importer has actually verified them.
    /// This is execution telemetry, unlike a value inferred from the planned node count.
    struct VerificationObserver: Sendable {
        private let didVerifyEdge: @Sendable (_ parentNodeIndex: Int, _ childNodeIndex: Int) -> Void

        init(
            didVerifyEdge: @escaping @Sendable (
                _ parentNodeIndex: Int,
                _ childNodeIndex: Int
            ) -> Void
        ) {
            self.didVerifyEdge = didVerifyEdge
        }

        func recordVerifiedEdge(parentNodeIndex: Int, childNodeIndex: Int) {
            didVerifyEdge(parentNodeIndex, childNodeIndex)
        }
    }

    /// Actor-confined capture state. The importer owns its lifetime and calls `append` before it
    /// materializes any joined path for the admitted node.
    final class Capture {
        private struct MutableNode {
            let parentIndex: Int?
            var firstChildIndex: Int?
            var nextSiblingIndex: Int?
            let rawComponent: String?
            let normalizedComponent: String?
            let kind: NodeKind
            let depth: Int
            let relativePathUTF8ByteCount: Int
        }

        private let limits: Limits
        private let rootIdentityUTF8ByteCount: Int
        private let identityComponentDepthOffset: Int
        private let attemptedWorkObserver: ((_ pathBytes: Int, _ componentWork: Int) throws -> Void)?
        private var nodes: [MutableNode]
        private var lastChildIndices: [Int?]
        private var expandedPathUTF8ByteCount: Int
        private var expandedComponentWork: Int

        init(
            limits: Limits,
            normalizedRootIdentityComponent: String? = nil,
            attemptedWorkObserver: ((
                _ pathBytes: Int,
                _ componentWork: Int
            ) throws -> Void)? = nil
        ) throws {
            guard limits.maximumExpandedPathUTF8Bytes > 0,
                  limits.maximumExpandedComponentWork > 0 else {
                throw VerificationError.invalidLimits
            }
            let rootIdentityUTF8ByteCount: Int
            let identityComponentDepthOffset: Int
            if let normalizedRootIdentityComponent {
                guard Self.isValid(
                    rawComponent: normalizedRootIdentityComponent,
                    normalizedComponent: normalizedRootIdentityComponent
                ) else {
                    throw VerificationError.invalidComponent
                }
                rootIdentityUTF8ByteCount = normalizedRootIdentityComponent.utf8.count
                identityComponentDepthOffset = 1
            } else {
                rootIdentityUTF8ByteCount = 0
                identityComponentDepthOffset = 0
            }
            guard rootIdentityUTF8ByteCount <= limits.maximumExpandedPathUTF8Bytes,
                  identityComponentDepthOffset <= limits.maximumExpandedComponentWork else {
                if rootIdentityUTF8ByteCount > limits.maximumExpandedPathUTF8Bytes {
                    throw VerificationError.expandedPathUTF8ByteLimitExceeded
                }
                throw VerificationError.expandedComponentWorkLimitExceeded
            }
            if identityComponentDepthOffset != 0 {
                try attemptedWorkObserver?(
                    rootIdentityUTF8ByteCount,
                    identityComponentDepthOffset
                )
            }
            self.limits = limits
            self.rootIdentityUTF8ByteCount = rootIdentityUTF8ByteCount
            self.identityComponentDepthOffset = identityComponentDepthOffset
            self.attemptedWorkObserver = attemptedWorkObserver
            nodes = [MutableNode(
                parentIndex: nil,
                firstChildIndex: nil,
                nextSiblingIndex: nil,
                rawComponent: nil,
                normalizedComponent: nil,
                kind: .directory,
                depth: 0,
                relativePathUTF8ByteCount: 0
            )]
            lastChildIndices = [nil]
            expandedPathUTF8ByteCount = rootIdentityUTF8ByteCount
            expandedComponentWork = identityComponentDepthOffset
        }

        @discardableResult
        func append(
            parentIndex: Int,
            rawComponent: String,
            normalizedComponent: String,
            kind: NodeKind,
            cancellation: ReconstructionCancellation
        ) throws -> Int {
            try cancellation.check()
            guard nodes.indices.contains(parentIndex),
                  nodes[parentIndex].kind == .directory else {
                throw VerificationError.invalidTree
            }
            guard Self.isValid(
                rawComponent: rawComponent,
                normalizedComponent: normalizedComponent
            ) else {
                throw VerificationError.invalidComponent
            }

            let parent = nodes[parentIndex]
            let depth = try checkedSum(
                parent.depth,
                1,
                overflowError: .expandedComponentWorkLimitExceeded
            )
            let separatorByteCount = parent.parentIndex == nil ? 0 : 1
            let parentAndSeparatorByteCount = try checkedSum(
                parent.relativePathUTF8ByteCount,
                separatorByteCount,
                overflowError: .expandedPathUTF8ByteLimitExceeded
            )
            let relativePathUTF8ByteCount = try checkedSum(
                parentAndSeparatorByteCount,
                normalizedComponent.utf8.count,
                overflowError: .expandedPathUTF8ByteLimitExceeded
            )
            let identityPathUTF8ByteCount: Int
            if identityComponentDepthOffset == 0 {
                identityPathUTF8ByteCount = relativePathUTF8ByteCount
            } else {
                let rootAndSeparatorByteCount = try checkedSum(
                    rootIdentityUTF8ByteCount,
                    1,
                    overflowError: .expandedPathUTF8ByteLimitExceeded
                )
                identityPathUTF8ByteCount = try checkedSum(
                    rootAndSeparatorByteCount,
                    relativePathUTF8ByteCount,
                    overflowError: .expandedPathUTF8ByteLimitExceeded
                )
            }
            let identityComponentWork = try checkedSum(
                depth,
                identityComponentDepthOffset,
                overflowError: .expandedComponentWorkLimitExceeded
            )
            let nextExpandedPathUTF8ByteCount = try checkedSum(
                expandedPathUTF8ByteCount,
                identityPathUTF8ByteCount,
                overflowError: .expandedPathUTF8ByteLimitExceeded
            )
            guard nextExpandedPathUTF8ByteCount <= limits.maximumExpandedPathUTF8Bytes else {
                throw VerificationError.expandedPathUTF8ByteLimitExceeded
            }
            let nextExpandedComponentWork = try checkedSum(
                expandedComponentWork,
                identityComponentWork,
                overflowError: .expandedComponentWorkLimitExceeded
            )
            guard nextExpandedComponentWork <= limits.maximumExpandedComponentWork else {
                throw VerificationError.expandedComponentWorkLimitExceeded
            }

            // Attempted work is deliberately non-refundable. Charge it before path materialization
            // and before the capture tree mutation that authorizes that work.
            try attemptedWorkObserver?(
                identityPathUTF8ByteCount,
                identityComponentWork
            )

            // This second poll is the commit fence: cancellation cannot leave a partially linked
            // node after all potentially expensive accounting has completed.
            try cancellation.check()
            let nodeIndex = nodes.count
            let previousLastChildIndex = lastChildIndices[parentIndex]
            nodes.append(MutableNode(
                parentIndex: parentIndex,
                firstChildIndex: nil,
                nextSiblingIndex: nil,
                rawComponent: rawComponent,
                normalizedComponent: normalizedComponent,
                kind: kind,
                depth: depth,
                relativePathUTF8ByteCount: relativePathUTF8ByteCount
            ))
            lastChildIndices.append(nil)
            if let previousLastChildIndex {
                nodes[previousLastChildIndex].nextSiblingIndex = nodeIndex
            } else {
                nodes[parentIndex].firstChildIndex = nodeIndex
            }
            lastChildIndices[parentIndex] = nodeIndex
            expandedPathUTF8ByteCount = nextExpandedPathUTF8ByteCount
            expandedComponentWork = nextExpandedComponentWork
            return nodeIndex
        }

        /// Materializes only an already-admitted path. Its worst-case bytes and component visits
        /// were both reserved by `append` before this method can be called.
        func materializeNormalizedRelativePath(
            to nodeIndex: Int,
            cancellation: ReconstructionCancellation
        ) throws -> String {
            try cancellation.check()
            guard nodes.indices.contains(nodeIndex), nodeIndex != 0 else {
                throw VerificationError.invalidTree
            }
            let node = nodes[nodeIndex]
            var components: [String] = []
            components.reserveCapacity(node.depth)
            var cursor = nodeIndex
            while cursor != 0 {
                try cancellation.check()
                let current = nodes[cursor]
                guard let component = current.normalizedComponent,
                      let parentIndex = current.parentIndex,
                      nodes.indices.contains(parentIndex),
                      parentIndex < cursor else {
                    throw VerificationError.invalidTree
                }
                components.append(component)
                cursor = parentIndex
            }
            try cancellation.check()
            let relativePath = components.reversed().joined(separator: "/")
            guard relativePath.utf8.count == node.relativePathUTF8ByteCount else {
                throw VerificationError.invalidTree
            }
            try cancellation.check()
            return relativePath
        }

        func makeVerificationPlan(
            cancellation: ReconstructionCancellation
        ) throws -> Plan {
            try cancellation.check()
            var immutableNodes: [Plan.Node] = []
            immutableNodes.reserveCapacity(nodes.count)
            for node in nodes {
                try cancellation.check()
                immutableNodes.append(Plan.Node(
                    parentIndex: node.parentIndex,
                    firstChildIndex: node.firstChildIndex,
                    nextSiblingIndex: node.nextSiblingIndex,
                    rawComponent: node.rawComponent,
                    normalizedComponent: node.normalizedComponent,
                    kind: node.kind,
                    depth: node.depth,
                    relativePathUTF8ByteCount: node.relativePathUTF8ByteCount
                ))
            }
            try cancellation.check()
            return Plan(
                nodes: immutableNodes,
                expandedPathUTF8ByteCount: expandedPathUTF8ByteCount,
                expandedComponentWork: expandedComponentWork
            )
        }

        private static func isValid(
            rawComponent: String,
            normalizedComponent: String
        ) -> Bool {
            guard !rawComponent.isEmpty,
                  rawComponent != ".",
                  rawComponent != "..",
                  !rawComponent.contains("/"),
                  !normalizedComponent.isEmpty,
                  normalizedComponent != ".",
                  normalizedComponent != "..",
                  !normalizedComponent.contains("/"),
                  rawComponent.precomposedStringWithCanonicalMapping == normalizedComponent else {
                return false
            }
            return !normalizedComponent.unicodeScalars.contains { scalar in
                scalar.value == 0 || scalar.value < 0x20 || scalar.value == 0x7f
            }
        }

        private func checkedSum(
            _ lhs: Int,
            _ rhs: Int,
            overflowError: VerificationError
        ) throws -> Int {
            let result = lhs.addingReportingOverflow(rhs)
            guard !result.overflow else { throw overflowError }
            return result.partialValue
        }
    }
}
