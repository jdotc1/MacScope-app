import Foundation

/// A canonical HTTP origin that can address only the local loopback interface.
///
/// This type intentionally accepts literal addresses only. In particular, it does not perform
/// DNS resolution and therefore cannot turn a mutable hostname into local transport authority.
struct Phase2LoopbackEndpoint: Equatable, Hashable, Sendable {
    enum Host: String, Equatable, Hashable, Sendable {
        case ipv4 = "127.0.0.1"
        case ipv6 = "::1"

        fileprivate var serialized: String {
            switch self {
            case .ipv4: rawValue
            case .ipv6: "[\(rawValue)]"
            }
        }
    }

    enum ValidationError: Error, Equatable, Sendable {
        case malformedURL
        case unsupportedScheme
        case nonLoopbackHost
        case missingOrInvalidPort
        case credentialsNotAllowed
        case nonRootPath
        case queryNotAllowed
        case fragmentNotAllowed
        case nonCanonicalURL
    }

    let host: Host
    let port: UInt16

    /// The normalized origin has no path, query, fragment, or credentials.
    var origin: URL {
        // Construction is infallible because validation freezes every interpolated component.
        URL(string: "http://\(host.serialized):\(port)")!
    }

    init(validating rawValue: String) throws {
        guard let components = URLComponents(string: rawValue), components.url != nil else {
            throw ValidationError.malformedURL
        }
        guard components.scheme == "http" else {
            throw ValidationError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw ValidationError.credentialsNotAllowed
        }

        let host: Host
        switch components.percentEncodedHost {
        case Host.ipv4.rawValue:
            host = .ipv4
        case "[\(Host.ipv6.rawValue)]":
            host = .ipv6
        default:
            throw ValidationError.nonLoopbackHost
        }

        guard let parsedPort = components.port,
              (1...Int(UInt16.max)).contains(parsedPort)
        else {
            throw ValidationError.missingOrInvalidPort
        }
        guard components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else {
            throw ValidationError.nonRootPath
        }
        guard components.percentEncodedQuery == nil else {
            throw ValidationError.queryNotAllowed
        }
        guard components.percentEncodedFragment == nil else {
            throw ValidationError.fragmentNotAllowed
        }

        let port = UInt16(parsedPort)
        let canonicalOrigin = "http://\(host.serialized):\(port)"
        guard rawValue == canonicalOrigin || rawValue == canonicalOrigin + "/" else {
            throw ValidationError.nonCanonicalURL
        }

        self.host = host
        self.port = port
    }

    init(validating url: URL) throws {
        try self.init(validating: url.absoluteString)
    }
}
