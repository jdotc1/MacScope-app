public protocol Shape { var area: Double { get } }
public struct Point: Shape { public let x: Int; public let y: Double; public var area: Double { y } }
public struct Generic<T> { public let value: T }
public enum Color { case red, green }
print(Point(x: 1, y: 2).area, Color.red, Generic(value: 3))
