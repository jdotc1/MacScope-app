import Foundation

public struct Point {
    public var x: Int
    public var y: Int
    public func distance(to o: Point) -> Int { abs(x - o.x) + abs(y - o.y) }
}

public final class Counter {
    public private(set) var n = 0
    public func bump(_ by: Int) { n += by }
    public func reset() { n = 0 }
}

public enum Shape {
    case circle(Int)
    case square(Int)
    public func area() -> Int {
        switch self {
        case .circle(let r): return 3 * r * r
        case .square(let s): return s * s
        }
    }
}

public protocol Greeter { func greet(_ name: String) -> String }

public struct Hello: Greeter {
    public func greet(_ name: String) -> String { "Hello, \(name)" }
}

public func sum(_ xs: [Int]) -> Int { xs.reduce(0, +) }
public func mapDouble(_ xs: [Int]) -> [Int] { xs.map { $0 * 2 } }
public func makeDict(_ keys: [String], _ vals: [Int]) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: zip(keys, vals))
}
public func maxOf<T: Comparable>(_ a: T, _ b: T) -> T { a < b ? b : a }
public func withClosure(_ f: (Int) -> Int) -> Int { f(21) }
