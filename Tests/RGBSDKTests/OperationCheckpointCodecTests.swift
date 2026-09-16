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
