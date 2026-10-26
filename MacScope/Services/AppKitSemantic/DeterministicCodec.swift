import Foundation

public enum AppKitDeterministicCodec {
    public static func claimsJSON(_ claims: [AppKitSemanticClaim]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Deterministic evidence order by stable claim key. Caller remains
        // responsible for exact input identity and versioned envelope.
        return try encoder.encode(claims.sorted(by: { $0.claimID < $1.claimID }))
    }
}
