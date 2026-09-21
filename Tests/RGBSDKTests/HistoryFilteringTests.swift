import Foundation
import Testing

@testable @_spi(Backend) import RGBSDK

@Test func transactionFilteringUsesCompleteSnapshotWithoutChangingOrderOrFields() async throws {
    let context = try historyContext()
    let selected = try TransactionID(String(repeating: "1", count: 64))
    let other = try TransactionID(String(repeating: "2", count: 64))
    let records = try [
        historyTransaction(selected, fee: 11), historyTransaction(other, fee: 12),
        historyTransaction(selected, fee: 13),
    ]
    let backend = CompleteHistoryBackend(transactions: records, transfers: [])
    let result = try await backend.listTransactions(context: context, txid: selected, skipSync: false)
    #expect(result == [records[0], records[2]])
    #expect(await backend.transactionCalls == 1)
    #expect(
        try await backend.listTransactions(
            context: context, txid: TransactionID(String(repeating: "3", count: 64)), skipSync: false
        ).isEmpty)
}

@Test func defaultTransactionFilterDoesNotSilentlyIgnoreSkipSync() async throws {
    let backend = CompleteHistoryBackend(transactions: [], transfers: [])
    do {
        _ = try await backend.listTransactions(
            context: historyContext(), txid: TransactionID(String(repeating: "1", count: 64)), skipSync: true
        )
        Issue.record("expected a missing unsynchronized history primitive")
    } catch let error as SDKError { #expect(error.code == .unsupported) }
    #expect(await backend.transactionCalls == 0)
}

@Test func transferFilteringUsesAllAssetsAndPreservesNativeMetadata() async throws {
    let context = try historyContext()
    let selected = try TransactionID(String(repeating: "1", count: 64))
    let other = try TransactionID(String(repeating: "2", count: 64))
    let records = [
        historyTransfer(selected, index: 4), historyTransfer(nil, index: 5), historyTransfer(other, index: 6),
        historyTransfer(selected, index: 7),
    ]
    let backend = CompleteHistoryBackend(transactions: [], transfers: records)
    let result = try await backend.listTransfers(context: context, txid: selected)
    #expect(result == [records[0], records[3]])
    #expect(await backend.transferCalls == 1)
    #expect(await backend.lastAssetID == nil)
}

@Test func historyFiltersPropagateBaseFailureInsteadOfInventingEmptyHistory() async throws {
    let backend = CompleteHistoryBackend(transactions: [], transfers: [], fail: true)
    let context = try historyContext()
    let txid = try TransactionID(String(repeating: "1", count: 64))
    for transfers in [false, true] {
        do {
            if transfers {
                _ = try await backend.listTransfers(context: context, txid: txid)
            } else {
                _ = try await backend.listTransactions(context: context, txid: txid, skipSync: false)
            }
            Issue.record("expected complete-history failure")
        } catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
    }
}

private func historyContext() throws -> BackendContext {
    try .init(
        session: BackendSession(id: "history-session", apiVersion: 1, network: .regtest),
        walletID: WalletID("history-wallet"), network: .regtest)
}

private func historyTransaction(_ txid: TransactionID, fee: UInt64) throws -> Transaction {
    try .init(
        transactionType: .sendBtc, txid: txid, received: Satoshis(1), sent: Satoshis(2), fee: Satoshis(fee),
        confirmationTime: .init(height: 3, timestamp: .init(rawValue: 4)))
}

private func historyTransfer(_ txid: TransactionID?, index: UInt64) -> Transfer {
    .init(
        index: index, batchTransferIndex: index + 20, createdAt: .init(rawValue: 10),
        updatedAt: .init(rawValue: 11), status: .waitingConfirmations, requestedAssignment: .init(type: .any),
        assignments: [.init(type: .nonFungible)], kind: .receiveWitness, txid: txid, recipientID: "recipient",
        expiration: .init(rawValue: 50))
}

private actor CompleteHistoryBackend: WalletBackend {
    let transactions: [Transaction]
    let transfers: [Transfer]
    let fail: Bool
    var transactionCalls = 0
    var transferCalls = 0
    var lastAssetID: AssetID?

    init(transactions: [Transaction], transfers: [Transfer], fail: Bool = false) {
        self.transactions = transactions
        self.transfers = transfers
        self.fail = fail
    }

    func preflightOperation(_ operation: OperationKind) async throws {
        throw SDKError.unsupported("history-only backend")
    }
    func initialize(_ request: BackendInitializeRequest) async throws -> BackendSession {
        throw SDKError.unsupported("history-only backend")
    }
    func registerWallet(_ request: RegisterWalletRequest) async throws {
        throw SDKError.unsupported("history-only backend")
    }
    func shutdown(session: BackendSession) async throws {}

    func listTransactions(context: BackendContext) async throws -> [Transaction] {
        transactionCalls += 1
        if fail { throw SDKError.backendProtocolMismatch("incomplete history") }
        return transactions
    }

    func listTransfers(context: BackendContext, assetID: AssetID?) async throws -> [Transfer] {
        transferCalls += 1
        lastAssetID = assetID
        if fail { throw SDKError.backendProtocolMismatch("incomplete history") }
        return transfers
    }
}
