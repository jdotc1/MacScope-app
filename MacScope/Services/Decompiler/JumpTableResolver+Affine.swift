import Foundation

/// An affine hull of low-32-bit register values over Z/(2^32). The generator
/// module is an overapproximation: unknown writes introduce independent axes,
/// joins add generators, and no relation is inferred from a library or loop shape.
struct JumpTableAffineState {
    var point: [UInt32]
    private(set) var basis: [[UInt32]?]
    var count: Int { point.count }

    init(count: Int = 31, independent: Bool = true) {
        point = Array(repeating: 0, count: count)
        basis = Array(repeating: nil, count: count)
        if independent {
            for i in 0..<count {
                var row = point; row[i] = 1; basis[i] = row
            }
        }
    }

    /// Newton inverse exists only for odd values. Wrapping arithmetic is exact
    /// in the ring, not host signed arithmetic or a rational-field substitute.
    private static func inverseOdd(_ x: UInt32) -> UInt32 {
        precondition(x & 1 == 1)
        var result: UInt32 = 1
        for _ in 0..<5 { result = result &* (2 &- x &* result) }
        return result
    }

    /// Inserts a module generator. A pivot 2^v also generates its torsion row:
    /// 2^(32-v) times the row has zero pivot but may have nonzero later columns.
    /// Keeping that row is essential (e.g. [2,1] also generates [0,2^31]).
    @discardableResult
    mutating func insert(_ input: [UInt32]) -> Bool {
        precondition(input.count == count)
        var pending = [input], changed = false
        while let next = pending.popLast() {
            var row = next
            for column in 0..<count where row[column] != 0 {
                let valuation = row[column].trailingZeroBitCount
                if let pivot = basis[column], pivot[column].trailingZeroBitCount <= valuation {
                    let shift = pivot[column].trailingZeroBitCount
                    let multiple = (row[column] >> shift) &* Self.inverseOdd(pivot[column] >> shift)
                    for j in column..<count { row[j] = row[j] &- multiple &* pivot[j] }
                    continue
                }
                if let previous = basis[column] { pending.append(previous) }
                let inverse = Self.inverseOdd(row[column] >> valuation)
                for j in column..<count { row[j] = row[j] &* inverse }
                basis[column] = row; changed = true
                if valuation != 0 {
                    let multiplier = UInt32(1) << (32 - valuation)
                    pending.append(row.map { $0 &* multiplier })
                }
                break
            }
        }
        return changed
    }

    /// Exact affine scalar transfer. Coefficients and constants are modular;
    /// low32(X ADD/SUB) and W ADD/SUB share this transfer, not upper-bit facts.
    mutating func assign(_ destination: Int, terms: [(Int, UInt32)], constant: UInt32 = 0) {
        let oldPoint = point, oldBasis = basis.compactMap { $0 }
        point[destination] = terms.reduce(constant) { $0 &+ oldPoint[$1.0] &* $1.1 }
        basis = Array(repeating: nil, count: count)
        for var row in oldBasis {
            row[destination] = terms.reduce(UInt32(0)) { $0 &+ row[$1.0] &* $1.1 }
            insert(row)
        }
    }

    mutating func forget(_ destination: Int) {
        assign(destination, terms: [])
        var axis = Array(repeating: UInt32(0), count: count); axis[destination] = 1
        insert(axis)
    }

    @discardableResult
    mutating func join(_ other: Self) -> Bool {
        precondition(count == other.count)
        var changed = insert(zip(other.point, point).map { $0 &- $1 })
        for row in other.basis.compactMap({ $0 }) { if insert(row) { changed = true } }
        return changed
    }

    /// Returns a constant only when every generator annihilates the expression.
    func constant(terms: [(Int, UInt32)], offset: UInt32 = 0) -> UInt32? {
        for row in basis.compactMap({ $0 }) {
            guard terms.reduce(UInt32(0), { $0 &+ row[$1.0] &* $1.1 }) == 0 else { return nil }
        }
        return terms.reduce(offset) { $0 &+ point[$1.0] &* $1.1 }
    }
}
