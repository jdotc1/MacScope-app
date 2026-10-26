// Bounded Swift 6.4 follow-up samples; no system binaries or runtime execution.
public class LegacyBridge { public init() {} }
public class Parent { public class Child { public init() {} }; public init() {} }
public struct Leaf { public let tag: Int }
public struct Container { public let one: Leaf; public let many: [Leaf]; public let optional: Leaf? }
public struct Box<T> { public let value: T }
public struct Concrete { public let boxed: Box<Leaf> }
public func repeats(_ a: Leaf, _ b: Leaf, _ c: Leaf) -> Leaf { a }
public func words(_ a: Container, _ b: Container) -> Container { a }
public struct Item01 { public init() {} }
public struct Item02 { public init() {} }
public struct Item03 { public init() {} }
public struct Item04 { public init() {} }
public struct Item05 { public init() {} }
public struct Item06 { public init() {} }
public struct Item07 { public init() {} }
public struct Item08 { public init() {} }
public struct Item09 { public init() {} }
public struct Item10 { public init() {} }
public struct Item11 { public init() {} }
public struct Item12 { public init() {} }
public struct Item13 { public init() {} }
public struct Item14 { public init() {} }
public struct Item15 { public init() {} }
public struct Item16 { public init() {} }
public func wide(_ p1: Item01, _ p2: Item02, _ p3: Item03, _ p4: Item04, _ p5: Item05, _ p6: Item06, _ p7: Item07, _ p8: Item08, _ p9: Item09, _ p10: Item10, _ p11: Item11, _ p12: Item12, _ p13: Item13, _ p14: Item14, _ p15: Item15, _ p16: Item16, _ again: Item16) -> Item16 { again }
public func extended(_ p1: Item01, _ p2: Item02, _ p3: Item03, _ p4: Item04, _ p5: Item05, _ p6: Item06, _ p7: Item07, _ p8: Item08, _ p9: Item09, _ p10: Item10, _ p11: Item11, _ p12: Item12, _ p13: Item13, _ p14: Item14, _ p15: Item15, _ p16: Item16, _ repeated: Item16, _ earlier: Item13) {}
