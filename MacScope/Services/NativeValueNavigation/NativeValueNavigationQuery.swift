import Foundation

extension NativeValueNavigationIndex {
    /// Conservative, within-function dependency navigation. This is a traversal of
    /// recorded SSA incidences, not semantic equivalence, feasible-path analysis,
    /// taint analysis, or an interprocedural slice.
    func query(
        seedValueID: String,
        direction: NativeValueNavigationDirection,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> NativeValueNavigationReport {
        guard values[seedValueID] != nil else { throw NativeValueNavigationFailure.unknownValue }
        struct Pending { let id: String; let depth: Int }
        struct BoundaryKey: Hashable {
            let valueID: String
            let site: NativeValueNavigationSite?
            let kind: String
        }
        var pending = [Pending(id: seedValueID, depth: 0)]
        var head = 0
        var discovered: Set<String> = [seedValueID]
        var visited: [String] = []
        var rows: [NativeValueNavigationRow] = []
        var boundaries: [NativeValueNavigationBoundary] = []
        var boundaryKeys = Set<BoundaryKey>()
        var reached = Set<NativeValueNavigationLimit>()

        func boundary(
            _ valueID: String, _ site: NativeValueNavigationSite?,
            _ kind: NativeValueNavigationBoundaryKind, _ explanation: String
        ) {
            let key = BoundaryKey(valueID: valueID, site: site, kind: kind.rawValue)
            guard boundaryKeys.insert(key).inserted else { return }
            // At most one terminal boundary per visited value and one boundary
            // per admitted relationship; bounded by values + rows.
            boundaries.append(.init(
                id: boundaries.count, valueID: valueID, site: site,
                kind: kind, explanation: explanation
            ))
        }
        func enqueue(_ valueID: String, after depth: Int) {
            guard !discovered.contains(valueID) else { return }
            guard depth < limits.maximumDepth else { reached.insert(.depth); return }
            guard discovered.count < limits.maximumVisitedValues else {
                reached.insert(.visitedValues)
                return
            }
            discovered.insert(valueID)
            pending.append(.init(id: valueID, depth: depth + 1))
        }
        func append(
            site: NativeValueNavigationSite, valueID: String, relatedValueID: String?,
            relationship: NativeValueNavigationRelationship, depth: Int,
            operandIndex: Int? = nil, predecessorBlockID: String? = nil,
            incomingEdgeID: String? = nil
        ) throws -> Bool {
            if isCancelled() { throw CancellationError() }
            guard rows.count < limits.maximumRows else { reached.insert(.rows); return false }
            if hasOmittedSourceRanges(for: site) { reached.insert(.sourceRanges) }
            rows.append(.init(
                id: rows.count, site: site, siteLabel: siteLabel(site),
                valueID: valueID, relatedValueID: relatedValueID,
                relationship: relationship, depth: depth, operandIndex: operandIndex,
                predecessorBlockID: predecessorBlockID, incomingEdgeID: incomingEdgeID,
                sourceRanges: sourceRanges(for: site)
            ))
            return true
        }

        walk: while head < pending.count {
            if isCancelled() { throw CancellationError() }
            let item = pending[head]
            head += 1
            visited.append(item.id)
            guard let value = values[item.id] else {
                throw NativeValueNavigationFailure.missingReference("visited SSA value", item.id)
            }

            if direction == .uses {
                let uses = usesByValue[item.id] ?? []
                if uses.isEmpty {
                    boundary(item.id, nil, .noRecordedUse, "No further use is recorded in this function's admitted SSA graph.")
                }
                for use in uses {
                    guard try append(
                        site: use.site, valueID: item.id, relatedValueID: use.outputValueID,
                        relationship: use.site.isPhi ? .phiIncoming : .use, depth: item.depth,
                        operandIndex: use.inputIndex, predecessorBlockID: use.predecessorBlockID,
                        incomingEdgeID: use.incomingEdgeID
                    ) else { break walk }
                    if case let .operation(id) = use.site, let operation = operations[id],
                       let stop = self.boundary(for: operation) {
                        boundary(item.id, use.site, stop.0, stop.1)
                        continue
                    }
                    if let output = use.outputValueID {
                        enqueue(output, after: item.depth)
                    } else {
                        boundary(item.id, use.site, .terminalUse, "This recorded use has no output SSA value to follow.")
                    }
                }
                continue
            }

            switch value.kind {
            case .constant:
                boundary(item.id, nil, .constant, "The recorded value is a constant.")
            case .functionEntry:
                boundary(item.id, nil, .functionEntry, "The recorded value enters this function. Caller values are outside this query.")
            case .annotation:
                boundary(item.id, nil, .annotation, "The native record is an annotation, not a proven value-producing definition.")
            case .operationResult:
                guard let id = value.definingOperationID,
                      let operation = operations[id], let binding = bindings[id] else {
                    throw NativeValueNavigationFailure.invalidBinding(item.id)
                }
                let site = NativeValueNavigationSite.operation(id)
                if let stop = self.boundary(for: operation) {
                    guard try append(site: site, valueID: item.id, relatedValueID: nil,
                                     relationship: .definition, depth: item.depth) else { break walk }
                    boundary(item.id, site, stop.0, stop.1)
                    continue
                }
                if binding.inputSSAValueIDs.isEmpty {
                    guard try append(site: site, valueID: item.id, relatedValueID: nil,
                                     relationship: .definition, depth: item.depth) else { break walk }
                }
                for (offset, inputID) in binding.inputSSAValueIDs.enumerated() {
                    guard try append(site: site, valueID: item.id, relatedValueID: inputID,
                                     relationship: .input, depth: item.depth,
                                     operandIndex: offset) else { break walk }
                    enqueue(inputID, after: item.depth)
                }
            case .phiResult:
                guard let id = value.definingPhiID, let phi = phis[id] else {
                    throw NativeValueNavigationFailure.invalidBinding(item.id)
                }
                for (offset, incoming) in phi.incoming.enumerated() {
                    guard try append(
                        site: .phi(id), valueID: item.id, relatedValueID: incoming.ssaValueID,
                        relationship: .phiIncoming, depth: item.depth, operandIndex: offset,
                        predecessorBlockID: incoming.sourceBlockID, incomingEdgeID: incoming.edgeID
                    ) else { break walk }
                    // Every incoming edge remains visible. These are alternatives,
                    // not a proof that every branch executes or can execute together.
                    enqueue(incoming.ssaValueID, after: item.depth)
                }
            }
        }
        return .init(
            requestID: requestID, requestSHA256: requestSHA256, imageID: image.imageID,
            functionID: function.functionID, seedValueID: seedValueID, direction: direction,
            rows: rows, boundaries: boundaries, visitedValueIDs: visited,
            limitsReached: reached
        )
    }
}

private extension NativeValueNavigationSite {
    var isPhi: Bool {
        if case .phi = self { return true }
        return false
    }
}
