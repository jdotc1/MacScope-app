import Foundation
public protocol Runner { func run() -> Int }
public struct Pair: Runner { public var x: Int; public var y: Int; public func run() -> Int { x + y } }
@objc public class Bridge: NSObject { @objc public func ping() -> Int { 7 } }
