import XCTest
import LumenUI
@testable import MacScope

final class DSScaleTests: XCTestCase {
    func testThereIsOneRadiusScale() {
        XCTAssertEqual([Lumen.Radius.xs, Lumen.Radius.sm, Lumen.Radius.md, Lumen.Radius.lg],
                       [Lumen.Radius.xs, Lumen.Radius.sm, Lumen.Radius.md, Lumen.Radius.lg], "AppRadius forwards to DS.Radius")
        XCTAssertEqual([Lumen.Radius.xs, Lumen.Radius.sm, Lumen.Radius.md, Lumen.Radius.lg], [4, 6, 8, 10],
                       "Feature views keep the radii they shipped with")
    }

    func testThereIsOneMotionSystem() {
        XCTAssertEqual(Lumen.Motion.fast, 0.14, "The duration feature views shipped with")
        XCTAssertEqual(Lumen.Motion.standard, 0.22)
        XCTAssertNil(Lumen.Motion.animation(Lumen.Motion.standardCurve, reduceMotion: true), "Reduce Motion: change at once")
        XCTAssertNotNil(Lumen.Motion.animation(Lumen.Motion.standardCurve, reduceMotion: false))
        XCTAssertNil(Lumen.Motion.animation(Lumen.Motion.fastCurve, reduceMotion: true), "AppMotion follows the same rule")
    }

    func testRadiiSitOnTheTwoPointGridAndIncrease() {
        let scale = [Lumen.Radius.xs, Lumen.Radius.sm, Lumen.Radius.md, Lumen.Radius.lg, Lumen.Radius.xl]
        XCTAssertEqual(scale, scale.sorted())
        XCTAssertEqual(Set(scale).count, scale.count)
        XCTAssertTrue(scale.allSatisfy { $0.truncatingRemainder(dividingBy: 2) == 0 }, "\(scale)")
    }
}
