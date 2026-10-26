import Foundation

/// Why a regional proof declined a function (A41 design note, DESIGN-NOTE-prove-classification).
/// `.inapplicable`: the function has a shape the proof does not model; absence of a model is no
/// evidence of anything. `.contradiction`: independent physical evidence disagrees with the
/// function's own call, branch or edge records.
enum RegionalRefusal: Error, Equatable {
    case inapplicable(guard: String)
    case contradiction(guard: String)

    var guardName: String {
        switch self {
        case let .inapplicable(name), let .contradiction(name): return name
        }
    }

    var isContradiction: Bool {
        if case .contradiction = self { return true }
        return false
    }
}

/// Collects the classification while the existing optional-returning proofs run, so their
/// success paths and call signatures stay as they are. Attempts combine as: success wins, then
/// any contradiction, then the first inapplicable guard.
final class RegionalRefusalRecorder: @unchecked Sendable {
    @TaskLocal static var current: RegionalRefusalRecorder?

    private(set) var contradiction: String?
    private(set) var inapplicable: String?

    /// Records a contradiction and returns for use in `else { return nil }` positions.
    static func contradict(_ name: String, file: StaticString = #fileID, line: UInt = #line) {
        // Observing a call is distinct from producing/recording a refusal case.
        if let sink = RejectedCFGDiagnostics.sink {
            sink(.guardObserved(kind: "contradiction", name: name,
                recorded: current != nil && current?.contradiction == nil,
                file: String(describing: file), line: Int(line)))
        }
        guard let recorder = current, recorder.contradiction == nil else { return }
        recorder.contradiction = name
    }

    static func inapplicable(_ name: String, file: StaticString = #fileID, line: UInt = #line) {
        if let sink = RejectedCFGDiagnostics.sink {
            sink(.guardObserved(kind: "inapplicable", name: name,
                recorded: current != nil && current?.inapplicable == nil,
                file: String(describing: file), line: Int(line)))
        }
        guard let recorder = current, recorder.inapplicable == nil else { return }
        recorder.inapplicable = name
    }

    static func classify<T>(file: StaticString = #fileID, line: UInt = #line,
                            _ body: () -> T?) -> Result<T, RegionalRefusal> {
        var diagnosticID: UUID? = nil
        if let sink = RejectedCFGDiagnostics.sink {
            let id = UUID()
            diagnosticID = id
            sink(.classificationBegin(id: id, file: String(describing: file), line: Int(line)))
        }
        let recorder = RegionalRefusalRecorder()
        let value = $current.withValue(recorder, operation: body)
        if let value {
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                sink(.classificationEnd(id: id, refusal: nil))
            }
            return .success(value)
        }
        if let name = recorder.contradiction {
            let refusal = RegionalRefusal.contradiction(guard: name)
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                sink(.classificationEnd(id: id, refusal: refusal))
            }
            return .failure(refusal)
        }
        let refusal = RegionalRefusal.inapplicable(guard: recorder.inapplicable ?? "unmodeled-shape")
        if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
            sink(.classificationEnd(id: id, refusal: refusal))
        }
        return .failure(refusal)
    }
}
