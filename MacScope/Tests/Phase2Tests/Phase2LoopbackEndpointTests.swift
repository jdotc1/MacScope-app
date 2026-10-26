import Foundation
import XCTest

@testable import MacScope

final class Phase2LoopbackEndpointTests: XCTestCase {
    func testAcceptsCanonicalLiteralLoopbackOriginsAtPortBounds() throws {
        let cases: [(rawValue: String, host: Phase2LoopbackEndpoint.Host, port: UInt16, origin: String)] = [
            ("http://127.0.0.1:1", .ipv4, 1, "http://127.0.0.1:1"),
            ("http://127.0.0.1:1234/", .ipv4, 1234, "http://127.0.0.1:1234"),
            ("http://127.0.0.1:65535", .ipv4, 65_535, "http://127.0.0.1:65535"),
            ("http://[::1]:1/", .ipv6, 1, "http://[::1]:1"),
            ("http://[::1]:1234", .ipv6, 1234, "http://[::1]:1234"),
            ("http://[::1]:65535/", .ipv6, 65_535, "http://[::1]:65535"),
        ]

        for item in cases {
            let endpoint = try Phase2LoopbackEndpoint(validating: item.rawValue)
            XCTAssertEqual(endpoint.host, item.host, item.rawValue)
            XCTAssertEqual(endpoint.port, item.port, item.rawValue)
            XCTAssertEqual(endpoint.origin.absoluteString, item.origin, item.rawValue)
        }
    }

    func testURLInitializerUsesTheSameValidationAndNormalization() throws {
        let endpoint = try Phase2LoopbackEndpoint(
            validating: XCTUnwrap(URL(string: "http://[::1]:1234/"))
        )

        XCTAssertEqual(endpoint.host, .ipv6)
        XCTAssertEqual(endpoint.port, 1234)
        XCTAssertEqual(endpoint.origin.absoluteString, "http://[::1]:1234")
    }

    func testRejectsMissingMalformedAndOutOfRangePorts() {
        assertRejected([
            "http://127.0.0.1",
            "http://[::1]",
            "http://127.0.0.1:0",
            "http://[::1]:0",
            "http://127.0.0.1:65536",
            "http://[::1]:65536",
            "http://127.0.0.1:-1",
            "http://127.0.0.1:abc",
            "http://127.0.0.1:",
        ])
    }

    func testRejectsNonHTTPEndpoints() {
        assertRejected([
            "https://127.0.0.1:1234",
            "https://[::1]:1234",
            "ftp://127.0.0.1:1234",
            "file://127.0.0.1:1234",
            "127.0.0.1:1234",
            "://127.0.0.1:1234",
        ])
    }

    func testRejectsHostnamesAndNonLoopbackAddresses() {
        assertRejected([
            "http://localhost:1234",
            "http://localhost.:1234",
            "http://example.com:1234",
            "http://0.0.0.0:1234",
            "http://192.168.1.2:1234",
            "http://10.0.0.2:1234",
            "http://8.8.8.8:1234",
            "http://[::]:1234",
            "http://[fe80::1]:1234",
            "http://[2001:db8::1]:1234",
        ])
    }

    func testRejectsAlternateIPv4AndIPv6Spellings() {
        assertRejected([
            "http://127.1:1234",
            "http://127.0.1:1234",
            "http://0177.0.0.1:1234",
            "http://0x7f000001:1234",
            "http://2130706433:1234",
            "http://[0:0:0:0:0:0:0:1]:1234",
            "http://[::ffff:127.0.0.1]:1234",
            "http://[::ffff:7f00:1]:1234",
        ])
    }

    func testRejectsCredentialsPathsQueriesAndFragments() {
        assertRejected([
            "http://user@127.0.0.1:1234",
            "http://user:password@127.0.0.1:1234",
            "http://127.0.0.1:1234/v1",
            "http://127.0.0.1:1234//",
            "http://127.0.0.1:1234/%2F",
            "http://127.0.0.1:1234?model=test",
            "http://127.0.0.1:1234?",
            "http://127.0.0.1:1234#fragment",
            "http://127.0.0.1:1234#",
        ])
    }

    func testRejectsNonCanonicalRepresentations() {
        assertRejected([
            "HTTP://127.0.0.1:1234",
            "http://127.0.0.1:01234",
            "http://[::1]:01234",
            "http://127.0.0.1:1234/.",
            "http://127.0.0.1:1234/%2e",
            " http://127.0.0.1:1234",
            "http://127.0.0.1:1234 ",
            "http://127%2e0%2e0%2e1:1234",
        ])
    }

    private func assertRejected(
        _ rawValues: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for rawValue in rawValues {
            XCTAssertThrowsError(
                try Phase2LoopbackEndpoint(validating: rawValue),
                "unexpectedly accepted \(rawValue)",
                file: file,
                line: line
            )
        }
    }
}
