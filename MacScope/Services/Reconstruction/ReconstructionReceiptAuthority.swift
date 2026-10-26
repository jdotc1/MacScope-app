import CryptoKit
import Foundation

/// The single canonical authority for durable reconstruction receipt identities.
///
/// Receipt IDs are handles, not authenticity claims. Authenticity comes from recomputing the
/// canonical digest over every durable semantic field and comparing it with the stored digest.
enum ReconstructionReceiptAuthority {
    static func makeToolReceipt(
        receiptID: UUID,
        jobID: UUID,
        taskID: UUID,
        checkpointRevision: UInt64,
        requestIdentitySHA256: String,
        producer: ReconstructionProducerIdentity,
        terminalState: ReconstructionReceiptTerminalState,
        outputEvidenceIDs: [UUID],
        diagnostic: ReconstructionDiagnostic?,
        evidenceReadAuthority: ReconstructionEvidenceReadAuthority? = nil
    ) throws -> ReconstructionToolReceipt {
        let provisional = try ReconstructionToolReceipt(
            receiptID: receiptID,
            jobID: jobID,
            taskID: taskID,
            checkpointRevision: checkpointRevision,
            requestIdentitySHA256: requestIdentitySHA256,
            producer: producer,
            terminalState: terminalState,
            outputEvidenceIDs: outputEvidenceIDs,
            diagnostic: diagnostic,
            canonicalSHA256: String(repeating: "0", count: 64),
            evidenceReadAuthority: evidenceReadAuthority
        )
        return try ReconstructionToolReceipt(
            receiptID: provisional.receiptID,
            jobID: provisional.jobID,
            taskID: provisional.taskID,
            checkpointRevision: provisional.checkpointRevision,
            requestIdentitySHA256: provisional.requestIdentitySHA256,
            producer: provisional.producer,
            terminalState: provisional.terminalState,
            outputEvidenceIDs: provisional.outputEvidenceIDs,
            diagnostic: provisional.diagnostic,
            canonicalSHA256: canonicalToolReceiptSHA256(provisional),
            evidenceReadAuthority: provisional.evidenceReadAuthority
        )
    }

    static func canonicalToolReceiptSHA256(
        _ receipt: ReconstructionToolReceipt
    ) throws -> String {
        try Task.checkCancellation()
        let legacy = ReconstructionToolReceiptPreimage(
            schemaVersion: ReconstructionToolReceipt.schemaVersion,
            receiptID: receipt.receiptID,
            jobID: receipt.jobID,
            taskID: receipt.taskID,
            checkpointRevision: receipt.checkpointRevision,
            requestIdentitySHA256: receipt.requestIdentitySHA256,
            producer: receipt.producer,
            terminalState: receipt.terminalState,
            outputEvidenceIDs: receipt.outputEvidenceIDs,
            diagnostic: receipt.diagnostic
        )
        guard let read = receipt.evidenceReadAuthority else {
            return try ReconstructionCanonicalJSON.sha256(of: legacy)
        }
        try read.validate(receipt: receipt)
        return try ReconstructionCanonicalJSON.sha256(of: ReconstructionReadToolReceiptPreimage(
            legacy: legacy, evidenceReadAuthority: read))
    }

    static func toolReceiptHasCanonicalIdentity(
        _ receipt: ReconstructionToolReceipt
    ) throws -> Bool {
        guard isCanonicalSHA256(receipt.canonicalSHA256) else {
            return false
        }
        return try canonicalToolReceiptSHA256(receipt) == receipt.canonicalSHA256
    }

    static func makeModelReceipt(
        receiptID: UUID,
        jobID: UUID,
        taskID: UUID,
        checkpointRevision: UInt64,
        requestIdentitySHA256: String,
        producer: ReconstructionProducerIdentity,
        terminalState: ReconstructionReceiptTerminalState,
        selectedHandleIDs: [String],
        acceptedEvidenceIDs: [UUID],
        diagnostic: ReconstructionDiagnostic?,
        finalResultCommitment: ReconstructionFinalResultCommitment? = nil
    ) throws -> ReconstructionModelReceipt {
        let provisional = try ReconstructionModelReceipt(
            receiptID: receiptID,
            jobID: jobID,
            taskID: taskID,
            checkpointRevision: checkpointRevision,
            requestIdentitySHA256: requestIdentitySHA256,
            producer: producer,
            terminalState: terminalState,
            selectedHandleIDs: selectedHandleIDs,
            acceptedEvidenceIDs: acceptedEvidenceIDs,
            diagnostic: diagnostic,
            finalResultCommitment: finalResultCommitment,
            canonicalSHA256: String(repeating: "0", count: 64)
        )
        return try ReconstructionModelReceipt(
            receiptID: provisional.receiptID,
            jobID: provisional.jobID,
            taskID: provisional.taskID,
            checkpointRevision: provisional.checkpointRevision,
            requestIdentitySHA256: provisional.requestIdentitySHA256,
            producer: provisional.producer,
            terminalState: provisional.terminalState,
            selectedHandleIDs: provisional.selectedHandleIDs,
            acceptedEvidenceIDs: provisional.acceptedEvidenceIDs,
            diagnostic: provisional.diagnostic,
            finalResultCommitment: provisional.finalResultCommitment,
            canonicalSHA256: canonicalModelReceiptSHA256(provisional)
        )
    }

    static func canonicalModelReceiptSHA256(
        _ receipt: ReconstructionModelReceipt
    ) throws -> String {
        try Task.checkCancellation()
        let legacy = ReconstructionModelReceiptPreimage(
                schemaVersion: ReconstructionModelReceipt.schemaVersion,
                receiptID: receipt.receiptID,
                jobID: receipt.jobID,
                taskID: receipt.taskID,
                checkpointRevision: receipt.checkpointRevision,
                requestIdentitySHA256: receipt.requestIdentitySHA256,
                producer: receipt.producer,
                terminalState: receipt.terminalState,
                selectedHandleIDs: receipt.selectedHandleIDs,
                acceptedEvidenceIDs: receipt.acceptedEvidenceIDs,
                diagnostic: receipt.diagnostic
            )
        guard let commitment = receipt.finalResultCommitment else {
            // Preserve the exact schema-v1 digest for every historical non-final receipt.
            return try ReconstructionCanonicalJSON.sha256(of: legacy)
        }
        return try ReconstructionCanonicalJSON.sha256(
            of: ReconstructionFinalModelReceiptPreimage(
                legacy: legacy,
                finalResultCommitment: commitment
            )
        )
    }

    static func modelReceiptHasCanonicalIdentity(
        _ receipt: ReconstructionModelReceipt
    ) throws -> Bool {
        guard isCanonicalSHA256(receipt.canonicalSHA256) else {
            return false
        }
        return try canonicalModelReceiptSHA256(receipt) == receipt.canonicalSHA256
    }

    static func makeFinalResult(
        resultID: UUID,
        jobID: UUID,
        taskID: UUID,
        checkpointID: UUID,
        checkpointRevision: UInt64,
        requestID: UUID,
        requestIdentitySHA256: String,
        kind: ReconstructionFinalSynthesisKind,
        payloadUTF8: Data,
        citedEvidenceIDs: [UUID],
        producer: ReconstructionProducerIdentity,
        modelReceiptID: UUID
    ) throws -> ReconstructionFinalResultRecord {
        let payloadSHA256 = rawSHA256(payloadUTF8)
        let provisional = try ReconstructionFinalResultRecord(
            resultID: resultID,
            jobID: jobID,
            taskID: taskID,
            checkpointID: checkpointID,
            checkpointRevision: checkpointRevision,
            requestID: requestID,
            requestIdentitySHA256: requestIdentitySHA256,
            kind: kind,
            payloadUTF8: payloadUTF8,
            payloadByteCount: UInt64(payloadUTF8.count),
            payloadSHA256: payloadSHA256,
            citedEvidenceIDs: citedEvidenceIDs,
            producer: producer,
            modelReceiptID: modelReceiptID,
            canonicalSHA256: String(repeating: "0", count: 64)
        )
        return try ReconstructionFinalResultRecord(
            resultID: provisional.resultID,
            schemaVersion: provisional.schemaVersion,
            jobID: provisional.jobID,
            taskID: provisional.taskID,
            checkpointID: provisional.checkpointID,
            checkpointRevision: provisional.checkpointRevision,
            requestID: provisional.requestID,
            requestIdentitySHA256: provisional.requestIdentitySHA256,
            kind: provisional.kind,
            payloadUTF8: provisional.payloadUTF8,
            payloadByteCount: provisional.payloadByteCount,
            payloadSHA256: provisional.payloadSHA256,
            citedEvidenceIDs: provisional.citedEvidenceIDs,
            producer: provisional.producer,
            modelReceiptID: provisional.modelReceiptID,
            canonicalSHA256: try canonicalFinalResultSHA256(provisional)
        )
    }

    static func canonicalFinalResultSHA256(
        _ result: ReconstructionFinalResultRecord
    ) throws -> String {
        try ReconstructionCanonicalJSON.sha256(
            of: ReconstructionFinalResultPreimage(result)
        )
    }

    static func finalResultHasCanonicalIdentity(
        _ result: ReconstructionFinalResultRecord
    ) throws -> Bool {
        guard isCanonicalSHA256(result.canonicalSHA256),
              result.payloadByteCount == UInt64(result.payloadUTF8.count),
              result.payloadSHA256 == rawSHA256(result.payloadUTF8) else {
            return false
        }
        return try canonicalFinalResultSHA256(result) == result.canonicalSHA256
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func rawSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ReconstructionToolReceiptPreimage: Encodable {
    let schemaVersion: Int
    let receiptID: UUID
    let jobID: UUID
    let taskID: UUID
    let checkpointRevision: UInt64
    let requestIdentitySHA256: String
    let producer: ReconstructionProducerIdentity
    let terminalState: ReconstructionReceiptTerminalState
    let outputEvidenceIDs: [UUID]
    let diagnostic: ReconstructionDiagnostic?
}

private struct ReconstructionReadToolReceiptPreimage: Encodable {
    let legacy: ReconstructionToolReceiptPreimage
    let evidenceReadAuthority: ReconstructionEvidenceReadAuthority
}

private struct ReconstructionModelReceiptPreimage: Encodable {
    let schemaVersion: Int
    let receiptID: UUID
    let jobID: UUID
    let taskID: UUID
    let checkpointRevision: UInt64
    let requestIdentitySHA256: String
    let producer: ReconstructionProducerIdentity
    let terminalState: ReconstructionReceiptTerminalState
    let selectedHandleIDs: [String]
    let acceptedEvidenceIDs: [UUID]
    let diagnostic: ReconstructionDiagnostic?
}

private struct ReconstructionFinalModelReceiptPreimage: Encodable {
    let legacy: ReconstructionModelReceiptPreimage
    let finalResultCommitment: ReconstructionFinalResultCommitment
}

private struct ReconstructionFinalResultPreimage: Encodable {
    let resultID: UUID
    let schemaVersion: Int
    let jobID: UUID
    let taskID: UUID
    let checkpointID: UUID
    let checkpointRevision: UInt64
    let requestID: UUID
    let requestIdentitySHA256: String
    let kind: ReconstructionFinalSynthesisKind
    let payloadUTF8: Data
    let payloadByteCount: UInt64
    let payloadSHA256: String
    let citedEvidenceIDs: [UUID]
    let producer: ReconstructionProducerIdentity
    let modelReceiptID: UUID

    init(_ result: ReconstructionFinalResultRecord) {
        resultID = result.resultID
        schemaVersion = result.schemaVersion
        jobID = result.jobID
        taskID = result.taskID
        checkpointID = result.checkpointID
        checkpointRevision = result.checkpointRevision
        requestID = result.requestID
        requestIdentitySHA256 = result.requestIdentitySHA256
        kind = result.kind
        payloadUTF8 = result.payloadUTF8
        payloadByteCount = result.payloadByteCount
        payloadSHA256 = result.payloadSHA256
        citedEvidenceIDs = result.citedEvidenceIDs
        producer = result.producer
        modelReceiptID = result.modelReceiptID
    }
}
