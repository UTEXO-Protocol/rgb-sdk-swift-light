import CryptoKit
import Foundation
import Testing
@testable @_spi(Backend) import RGBSDK

@Test func checkpointCodecMatchesCrossPlatformCreatedGolden() throws {
    let checkpoint = try OperationCheckpoint(
        walletID: WalletID("wallet-1"),
        idempotencyKey: IdempotencyKey("idempotency-1"),
        requestHash: RequestHash(validating: String(repeating: "d", count: 64)),
        operationKind: .sendBtc,
        phase: .created
    )
    let expectedBase64 = "VVRYT1BDSEsAAAABAAAACHdhbGxldC0xAAAADWlkZW1wb3RlbmN5LTEAAABAZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZAAAAAdzZW5kQnRjAAAAB2NyZWF0ZWQAAAAAc1KCjkjFxqbzAdbex02UCkGyvtsberBuwcR4gJro8Ug="

    let encoded = try OperationCheckpointCodec.encode(checkpoint)

    #expect(encoded.base64EncodedString() == expectedBase64)
    #expect(encoded.count == 167)
    #expect(try OperationCheckpointCodec.decode(encoded) == checkpoint)
}

@Test func checkpointCodecRoundTripsExactPreparedSignedAndTerminalState() throws {
    let fixture = try CodecFixture()
    let outcomes: [OperationTerminalOutcome] = [
        .succeeded(.sendBtc(operationID: fixture.operationID, txid: fixture.txid)),
        .rejected(
            operationID: fixture.operationID,
            safeMessage: "transaction rejected",
            retryable: false,
            backendCode: "policy_rejected",
            correlationID: "correlation-1"
        ),
        .expired(operationID: fixture.operationID),
    ]

    for outcome in outcomes {
        let checkpoint = try fixture.terminal(outcome: outcome)
        let encoded = try OperationCheckpointCodec.encode(checkpoint)
        let decoded = try OperationCheckpointCodec.decode(encoded)

        #expect(decoded == checkpoint)
        #expect(decoded.preparedTransaction?.psbtBase64 == "prepared-psbt")
        #expect(decoded.signedPsbtBase64 == "signed-psbt")
        #expect(try OperationCheckpointCodec.encode(decoded) == encoded)
    }
}

@Test func checkpointCodecRejectsTamperingWithRedactedStableError() throws {
    let fixture = try CodecFixture()
    let checkpoint = try fixture.terminal(
        outcome: .succeeded(.sendBtc(operationID: fixture.operationID, txid: fixture.txid))
    )
    var encoded = try OperationCheckpointCodec.encode(checkpoint)
    encoded[encoded.count / 2] ^= 1

    do {
        _ = try OperationCheckpointCodec.decode(encoded)
        Issue.record("expected tampered checkpoint rejection")
    } catch let error as SDKError {
        #expect(error.code == .operationJournalUnavailable)
        #expect(!error.message.lowercased().contains("psbt"))
    }
}

@Test func checkpointCodecAcceptsValidNonzeroIndexSlices() throws {
    let fixture = try CodecFixture()
    let checkpoint = try fixture.terminal(outcome: .expired(operationID: fixture.operationID))
    let encoded = try OperationCheckpointCodec.encode(checkpoint)
    for prefixCount in [1, 256, 4_096] {
        var prefixed = Data(repeating: 0, count: prefixCount)
        prefixed.append(encoded)
        let slice = prefixed.dropFirst(prefixCount)
        #expect(slice.startIndex == prefixCount)
        #expect(try OperationCheckpointCodec.decode(slice) == checkpoint)
    }
}

@Test func checkpointCodecRejectsMalformedNonzeroIndexSlicesWithoutTrapping() throws {
    let fixture = try CodecFixture()
    let checkpoint = try fixture.terminal(outcome: .expired(operationID: fixture.operationID))
    let encoded = try OperationCheckpointCodec.encode(checkpoint)
    for size in [0, 1, 44, encoded.count - 1, encoded.count] {
        var prefixed = Data(repeating: 0, count: 256)
        prefixed.append(encoded.prefix(size))
        if size == encoded.count { prefixed[prefixed.endIndex - 1] ^= 1 }
        do {
            _ = try OperationCheckpointCodec.decode(prefixed.dropFirst(256))
            Issue.record("expected invalid checkpoint rejection")
        } catch let error as SDKError {
            #expect(error.code == .operationJournalUnavailable)
        }
    }
}

@Test func terminalJournalCheckpointIsImmutable() async throws {
    let fixture = try CodecFixture()
    let journal = InMemoryOperationJournal()
    let success = try fixture.terminal(
        outcome: .succeeded(.sendBtc(operationID: fixture.operationID, txid: fixture.txid))
    )
    try await journal.save(success)
    try await journal.save(success)

    let replacement = try fixture.terminal(outcome: .expired(operationID: fixture.operationID))
    await #expect(throws: SDKError.self) { try await journal.save(replacement) }
    #expect(
        await journal.load(
            walletID: fixture.walletID,
            idempotencyKey: fixture.idempotencyKey
        ) == success
    )
}

@Test func compactTerminalReceiptsRetainReplayIdentityResultsAndValidation() throws {
    let fixture = try CodecFixture()
    let outcomes: [OperationTerminalOutcome] = [
        .succeeded(.sendBtc(operationID: fixture.operationID, txid: fixture.txid)),
        .rejected(operationID: fixture.operationID, safeMessage: "rejected", retryable: false,
                  backendCode: "POLICY", correlationID: "trace-1"),
        .expired(operationID: fixture.operationID),
    ]
    for outcome in outcomes {
        let full = try fixture.terminal(outcome: outcome)
        let compact = try full.compactTerminal
        let encoded = try OperationCheckpointCodec.encode(compact)
        #expect(Array(encoded[8..<12]) == [0, 0, 0, 2])
        #expect(try encoded.count < OperationCheckpointCodec.encode(full).count)
        #expect(compact.preparedTransaction == nil && compact.signedPsbtBase64 == nil)
        #expect(compact.requestHash == full.requestHash)
        #expect(compact.validation == full.validation)
        #expect(compact.terminalOutcome == full.terminalOutcome)
        #expect(try OperationCheckpointCodec.decode(encoded) == compact)
        #expect(try OperationCheckpointCodec.decode(encoded).compactTerminal == compact)
        try validateCheckpointTransition(from: compact, to: full)
    }
}

@Test func compactExpiredReceiptMatchesCrossPlatformV2Golden() throws {
    let fixture = try CodecFixture()
    let compact = try OperationCheckpoint(
        walletID: fixture.walletID, idempotencyKey: fixture.idempotencyKey,
        requestHash: fixture.requestHash, operationKind: .sendBtc, phase: .terminal,
        operationID: fixture.operationID, terminalOutcome: .expired(operationID: fixture.operationID)
    )
    let expected = "VVRYT1BDSEsAAAACAAAACHdhbGxldC0xAAAADWlkZW1wb3RlbmN5LTEAAABAZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZAAAAAdzZW5kQnRjAAAACHRlcm1pbmFsAAAAC29wZXJhdGlvbi0xAAMAAAALb3BlcmF0aW9uLTFSUNDMLn6hpZ09w6zr8hXk1Do4zIX1dfSNTTTvNeq6jQ=="
    let encoded = try OperationCheckpointCodec.encode(compact)
    #expect(encoded.count == 196)
    #expect(encoded.base64EncodedString() == expected)
    #expect(try OperationCheckpointCodec.decode(encoded) == compact)
}

@Test func compactionNeverRemovesNonterminalRecoveryEvidence() throws {
    let fixture = try CodecFixture()
    for phase in [OperationPhase.prepared, .signed, .submitting] {
        let checkpoint = try OperationCheckpoint(
            walletID: fixture.walletID, idempotencyKey: fixture.idempotencyKey,
            requestHash: fixture.requestHash, operationKind: .sendBtc, phase: phase,
            operationID: fixture.operationID, preparedTransaction: fixture.prepared,
            signedPsbtBase64: phase == .prepared ? nil : "signed-psbt",
            validation: phase == .prepared ? nil : fixture.validation
        )
        #expect(try checkpoint.compactTerminal == checkpoint)
        #expect(try OperationCheckpointCodec.decode(OperationCheckpointCodec.encode(checkpoint)) == checkpoint)
    }
}

@Test func successfulCompactReceiptRequiresMatchingLocalTransactionEvidence() throws {
    let fixture = try CodecFixture()
    #expect(throws: SDKError.self) {
        try OperationCheckpoint(
            walletID: fixture.walletID, idempotencyKey: fixture.idempotencyKey,
            requestHash: fixture.requestHash, operationKind: .sendBtc, phase: .terminal,
            operationID: fixture.operationID,
            terminalOutcome: .succeeded(.sendBtc(operationID: fixture.operationID, txid: fixture.txid))
        )
    }
    #expect(throws: SDKError.self) {
        try OperationCheckpoint(
            walletID: fixture.walletID, idempotencyKey: fixture.idempotencyKey,
            requestHash: fixture.requestHash, operationKind: .sendBtc, phase: .terminal,
            operationID: fixture.operationID, validation: fixture.validation,
            terminalOutcome: .succeeded(.sendBtc(
                operationID: fixture.operationID, txid: TransactionID(String(repeating: "f", count: 64))
            ))
        )
    }
}

@Test func rgbNullableBatchCompactReceiptCrossPlatformGolden() throws {
    let fixture = try CodecFixture()
    for batch: UInt64? in [nil, 42] {
        let checkpoint = try OperationCheckpoint(
            walletID: fixture.walletID, idempotencyKey: fixture.idempotencyKey,
            requestHash: fixture.requestHash, operationKind: .onchainSend, phase: .terminal,
            operationID: fixture.operationID, validation: fixture.validation,
            terminalOutcome: .succeeded(.onchainSend(operationID: fixture.operationID,
                result: .init(txid: fixture.txid, batchTransferIndex: batch))))
        let encoded = try OperationCheckpointCodec.encode(checkpoint)
        #expect(try OperationCheckpointCodec.decode(encoded) == checkpoint)
        let expected = batch == nil
            ? "VVRYT1BDSEsAAAACAAAACHdhbGxldC0xAAAADWlkZW1wb3RlbmN5LTEAAABAZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZAAAAAtvbmNoYWluU2VuZAAAAAh0ZXJtaW5hbAAAAAtvcGVyYXRpb24tMQEAAABAYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYgAAAEBjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjAAAAQGFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEAAAAAAABOIAAAAAAAAEo4AAAAAAAAA+gAAAAAAAAAyAAAAAAAABOIAAAAAAAAJxAAAAAAAAAjKAAAAAEAAAACAAAAAAEEAAAAC29wZXJhdGlvbi0xAAAAQGFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWGagJla0qZuVqvoR6VpKk/CXm9p5ymGGEOCuHkhlnPn2A=="
            : "VVRYT1BDSEsAAAACAAAACHdhbGxldC0xAAAADWlkZW1wb3RlbmN5LTEAAABAZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZAAAAAtvbmNoYWluU2VuZAAAAAh0ZXJtaW5hbAAAAAtvcGVyYXRpb24tMQEAAABAYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYgAAAEBjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjAAAAQGFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEAAAAAAABOIAAAAAAAAEo4AAAAAAAAA+gAAAAAAAAAyAAAAAAAABOIAAAAAAAAJxAAAAAAAAAjKAAAAAEAAAACAAAAAAEDAAAAC29wZXJhdGlvbi0xAAAAQGFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEAAAAAAAAAKjT+IIi8IAUBHN/sRLUZvDApVJe4Ke8hsmz0wturCGHl"
        #expect(encoded.base64EncodedString() == expected)
        #expect(try OperationCheckpointCodec.decode(Data(base64Encoded: expected)!) == checkpoint)
    }
}

private func codecEvidence() throws -> RGBSendEvidence {
    try RGBSendEvidence(
        fasciaBase64: "ZmFzY2lhLWJ5dGVzLWZvci10ZXN0cw==", mpcEntropy: .max,
        existingOutputProofs: [
            RGBExistingOutputProof(transactionHex: "02000000", vout: 1, derivationIndex: 7),
            RGBExistingOutputProof(transactionHex: "0300", vout: 0, derivationIndex: 0),
        ])
}

/// Replaces the big-endian schema version after the 8-byte magic and re-seals the digest.
private func reencoded(_ encoded: Data, schema: UInt8) -> Data {
    var body = Data(encoded.dropLast(32))
    body[body.startIndex + 11] = schema
    body.append(contentsOf: SHA256.hash(data: body))
    return body
}

private func schemaVersion(_ encoded: Data) -> UInt32 {
    encoded.dropFirst(8).prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
}

@Test func rgbSendEvidenceSurvivesARestartInSchemaV3WhileEvidenceFreePreparationsStayV1() throws {
    let fixture = try CodecFixture()
    let evidence = try codecEvidence()
    let encoded = try OperationCheckpointCodec.encode(fixture.preparedRGBSend(evidence))
    #expect(schemaVersion(encoded) == 3)
    let decoded = try OperationCheckpointCodec.decode(encoded)
    #expect(decoded.preparedTransaction?.rgbSendEvidence == evidence)
    #expect(try OperationCheckpointCodec.encode(decoded) == encoded)

    let blind = try OperationCheckpointCodec.encode(fixture.preparedRGBSend(nil))
    #expect(schemaVersion(blind) == 1)
    let decodedBlind = try OperationCheckpointCodec.decode(blind)
    #expect(decodedBlind.preparedTransaction != nil && decodedBlind.preparedTransaction?.rgbSendEvidence == nil)
    // Each record has one encoding: v3 is used exactly for RGB send evidence.
    for noncanonical in [reencoded(blind, schema: 3), reencoded(encoded, schema: 1)] {
        do {
            _ = try OperationCheckpointCodec.decode(noncanonical)
            Issue.record("expected a non-canonical schema version to be rejected")
        } catch let error as SDKError { #expect(error.code == .operationJournalUnavailable) }
    }
    // Evidence survives signing; a compact terminal receipt drops it with the preparation.
    let signed = try fixture.terminalRGBSend(evidence)
    let signedEncoded = try OperationCheckpointCodec.encode(signed)
    #expect(schemaVersion(signedEncoded) == 3)
    #expect(try OperationCheckpointCodec.decode(signedEncoded) == signed)
    #expect(try schemaVersion(OperationCheckpointCodec.encode(signed.compactTerminal)) == 2)
}

@Test func preparedRGBSendWithEvidenceMatchesCrossPlatformV3Golden() throws {
    let checkpoint = try CodecFixture().preparedRGBSend(codecEvidence())
    let expected = "VVRYT1BDSEsAAAADAAAACHdhbGxldC0xAAAADWlkZW1wb3RlbmN5LTEAAABAZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZAAAAAtvbmNoYWluU2VuZAAAAAhwcmVwYXJlZAEAAAALb3BlcmF0aW9uLTEBAAAAC29wZXJhdGlvbi0xAAAADWlkZW1wb3RlbmN5LTEAAABAZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZAAAAAZzaWduZXQAAAALb25jaGFpblNlbmQAAAANcHJlcGFyZWQtcHNidAAAAAAAAAfQAAEAAAANY29ycmVsYXRpb24tMQEAAAAgWm1GelkybGhMV0o1ZEdWekxXWnZjaTEwWlhOMGN3PT3//////////wAAAAIAAAAIMDIwMDAwMDAAAAABAAAABwAAAAQwMzAwAAAAAAAAAAAAALEF8Xqk/evs6Zx4PxchSET4Egk42GQc2hO4MH3lMBle"
    let encoded = try OperationCheckpointCodec.encode(checkpoint)
    #expect(encoded.base64EncodedString() == expected)
    #expect(try OperationCheckpointCodec.decode(#require(Data(base64Encoded: expected))) == checkpoint)
}

private struct CodecFixture {
    let walletID: WalletID
    let idempotencyKey: IdempotencyKey
    let operationID: OperationID
    let txid: TransactionID
    let requestHash: RequestHash
    let prepared: PreparedTransaction
    let validation: LocalValidationReport

    init() throws {
        walletID = try WalletID("wallet-1")
        idempotencyKey = try IdempotencyKey("idempotency-1")
        operationID = try OperationID("operation-1")
        txid = try TransactionID(String(repeating: "a", count: 64))
        requestHash = try RequestHash(validating: String(repeating: "d", count: 64))
        prepared = try PreparedTransaction(
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            requestHash: requestHash,
            network: .signet,
            operation: .sendBtc,
            psbtBase64: "prepared-psbt",
            expiresAt: .init(rawValue: 2_000)
        )
        validation = try LocalValidationReport(
            psbtSHA256: String(repeating: "b", count: 64),
            intentSHA256: String(repeating: "c", count: 64),
            unsignedTxid: txid,
            totalInput: Satoshis(20_000),
            totalOutput: Satoshis(19_000),
            fee: Satoshis(1_000),
            estimatedVbytes: 200,
            feeRate: FeeRate(satsPerVByte: 5.0),
            externalOutput: Satoshis(10_000),
            change: Satoshis(9_000),
            inputCount: 1,
            outputCount: 2,
            opReturnCount: 0
        )
    }

    private func rgbSendPreparation(_ evidence: RGBSendEvidence?) throws -> PreparedTransaction {
        try PreparedTransaction(
            operationID: operationID, idempotencyKey: idempotencyKey, requestHash: requestHash,
            network: .signet, operation: .onchainSend, psbtBase64: "prepared-psbt",
            expiresAt: .init(rawValue: 2_000), correlationID: "correlation-1", rgbSendEvidence: evidence)
    }

    func preparedRGBSend(_ evidence: RGBSendEvidence?) throws -> OperationCheckpoint {
        try OperationCheckpoint(
            walletID: walletID, idempotencyKey: idempotencyKey, requestHash: requestHash,
            operationKind: .onchainSend, phase: .prepared, operationID: operationID,
            preparedTransaction: rgbSendPreparation(evidence))
    }

    func terminalRGBSend(_ evidence: RGBSendEvidence?) throws -> OperationCheckpoint {
        try OperationCheckpoint(
            walletID: walletID, idempotencyKey: idempotencyKey, requestHash: requestHash,
            operationKind: .onchainSend, phase: .terminal, operationID: operationID,
            preparedTransaction: rgbSendPreparation(evidence), signedPsbtBase64: "signed-psbt",
            validation: validation,
            terminalOutcome: .succeeded(.onchainSend(operationID: operationID, result: .init(txid: txid))))
    }

    func terminal(outcome: OperationTerminalOutcome) throws -> OperationCheckpoint {
        try OperationCheckpoint(
            walletID: walletID,
            idempotencyKey: idempotencyKey,
            requestHash: requestHash,
            operationKind: .sendBtc,
            phase: .terminal,
            operationID: operationID,
            preparedTransaction: prepared,
            signedPsbtBase64: "signed-psbt",
            validation: validation,
            terminalOutcome: outcome
        )
    }
}
