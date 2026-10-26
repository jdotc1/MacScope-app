import Foundation

public struct ObjCSliceProof: Hashable, Codable, Sendable {
    public let selectedSliceSHA256: String
    public let image: AppKitImageKey
    /// E.g. "preferred-mach-o-vm"; both parsers must agree before diff.
    public let addressCoordinate: String

    public init(selectedSliceSHA256: String, image: AppKitImageKey,
                addressCoordinate: String) {
        self.selectedSliceSHA256 = selectedSliceSHA256
        self.image = image
        self.addressCoordinate = addressCoordinate
    }
}

public struct ObjCSourceSnapshot: Sendable {
    public let slice: ObjCSliceProof
    public let methods: [ObjCMethodFact]

    public init(slice: ObjCSliceProof, methods: [ObjCMethodFact]) {
        self.slice = slice
        self.methods = methods
    }
}

public struct ObjCDifferentialResult: Sendable {
    public let comparable: Bool
    public let refusal: String?
    public let onlyInMacScope: [ObjCMethodFact]
    public let onlyInDonor: [ObjCMethodFact]
    public let commonCount: Int
}

public enum ObjCMetadataDifferential {
    /// Deterministic, same-slice *observation* comparison. A delta is not a
    /// parser bug or a feature by itself: it needs a validated positive and
    /// negative case before any code port into MacScope.
    public static func compare(primary: ObjCSourceSnapshot,
                               donor: ObjCSourceSnapshot) -> ObjCDifferentialResult {
        guard primary.slice == donor.slice,
              primary.slice.selectedSliceSHA256.utf8.count == 64,
              primary.slice.selectedSliceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              primary.slice.image.hasValidIdentity,
              primary.slice.addressCoordinate == "preferred-mach-o-vm" else {
            return .init(comparable: false, refusal: "slice-or-coordinate-mismatch",
                         onlyInMacScope: [], onlyInDonor: [], commonCount: 0)
        }
        guard primary.methods.allSatisfy({ $0.image == primary.slice.image }),
              donor.methods.allSatisfy({ $0.image == donor.slice.image }) else {
            return .init(comparable: false, refusal: "fact-image-identity-mismatch",
                         onlyInMacScope: [], onlyInDonor: [], commonCount: 0)
        }
        let a = Set(primary.methods)
        let b = Set(donor.methods)
        func order(_ facts: Set<ObjCMethodFact>) -> [ObjCMethodFact] {
            facts.sorted {
                let left = "\($0.ownerClass)\u{0}\($0.selector)\u{0}\($0.isClassMethod)\u{0}\($0.ownerKind.rawValue)\u{0}\($0.implementationVMAddress ?? 0)"
                let right = "\($1.ownerClass)\u{0}\($1.selector)\u{0}\($1.isClassMethod)\u{0}\($1.ownerKind.rawValue)\u{0}\($1.implementationVMAddress ?? 0)"
                return left < right
            }
        }
        return .init(comparable: true, refusal: nil,
                     onlyInMacScope: order(a.subtracting(b)),
                     onlyInDonor: order(b.subtracting(a)),
                     commonCount: a.intersection(b).count)
    }
}
