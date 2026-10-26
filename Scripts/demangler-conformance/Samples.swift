import Foundation
import Observation
import Distributed

public protocol Source<Element> { associatedtype Element; func read() -> Element }
public struct Box<T>: Source {
    public var value: T
    public init(_ value: T) { self.value = value }
    public func read() -> T { value }
    public func map<U>(_ transform: (T) throws -> U) rethrows -> Box<U> { Box<U>(try transform(value)) }
}
public func read<S: Source>(_ source: S) -> S.Element { source.read() }
public func existential(_ source: any Source<Int>) -> Int { source.read() }
public func opaque(_ value: Int) -> some Source<Int> { Box(value) }
public func closure(_ offset: Int) -> (Int) -> Int { { offset + $0 } }
public enum Failure: Error { case failed }
public func typed(_ value: Int) throws(Failure) -> Int { if value < 0 { throw .failed }; return value }
public func asynchronous(_ action: @Sendable () async throws -> Int) async throws -> Int { try await action() }
@propertyWrapper public struct Wrapped<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
public struct Settings { @Wrapped public var count = 7; public init() {} }
@resultBuilder public enum Numbers {
    public static func buildBlock(_ values: Int...) -> [Int] { values }
}
public func build(@Numbers _ body: () -> [Int]) -> [Int] { body() }
public func built() -> [Int] { build { 1; 2; 3 } }
public func pack<each T>(_ values: repeat each T) -> (repeat each T) { (repeat each values) }
public actor Counter {
    public var value = 0
    public init() {}
    public func next() -> Int { value += 1; return value }
}
public distributed actor Remote {
    public typealias ActorSystem = LocalTestingDistributedActorSystem
    public distributed func echo(_ value: String) -> String { value }
}
@objc public class Bridge: NSObject {
    @objc public func echo(_ value: NSString) -> NSString { value }
}
@Observable public final class Model { public var value = 1; public init() {} }
@_weakLinked public func optionalFeature() {}
public func hasFeature() -> Bool { if #_hasSymbol(optionalFeature) { return true }; return false }
