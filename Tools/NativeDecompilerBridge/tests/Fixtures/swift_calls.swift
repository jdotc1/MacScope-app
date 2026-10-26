public typealias MacScopeFixtureUnary = @convention(c) (Int64) -> Int64

@_cdecl("macscope_fixture_swift_direct_target")
@inline(never)
public func macscopeFixtureSwiftDirectTarget(_ value: Int64) -> Int64 {
    return (value &* 5) ^ 0x44
}
@_cdecl("macscope_fixture_swift_direct_call")
@inline(never)
public func macscopeFixtureSwiftDirectCall(_ value: Int64) -> Int64 {
    let result = macscopeFixtureSwiftDirectTarget(value)
    return result &+ 3
}

@_cdecl("macscope_fixture_swift_indirect_call")
@inline(never)
public func macscopeFixtureSwiftIndirectCall(
    _ function: MacScopeFixtureUnary,
    _ value: Int64
) -> Int64 {
    return function(value) ^ 0x99
}

@_cdecl("macscope_fixture_swift_branch")
@inline(never)
public func macscopeFixtureSwiftBranch(_ selector: Int32, _ value: Int64) -> Int64 {
    if selector < 0 {
        return macscopeFixtureSwiftDirectCall(value) &+ 1
    }
    return macscopeFixtureSwiftIndirectCall(macscopeFixtureSwiftDirectTarget, value) &+ 2
}
