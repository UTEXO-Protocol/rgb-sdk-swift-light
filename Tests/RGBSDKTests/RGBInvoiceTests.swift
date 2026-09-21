import Foundation
import Testing
@testable @_spi(Backend) import RGBSDK

// Beneficiary/contract vectors from rgb-invoicing 0.11.1-rc.11 parse tests.
// The network, expiry and transport are public synthetic test data, not a wallet.
let invoiceTestBlindPayload = "4vm1CX2Z-K8hMo59-e7dgGBS-Jka7mYn-Xe~yP85-yUiHHxr-aVlYa"
let invoiceTestWitnessPayload = "A8cJ7Ww3-NIzADo3-Tzp_5aD-7CTBWmA-AAAAAAA-AAAAAAA-ALSQkcw"
let invoiceTestAsset = "eIbQx5Am-XRDjj01-RM~5eo7-rv2nluD-OnBJRAy-S9~Yfts"
let invoiceTestNiaSchema = "RWhwUfTMpuP2Zfx1~j4nswCANGeJrYOqDcKelaMV4zU"

func invoiceTestString(
    network: String = "bcrt", witness: Bool = false, asset: String = "~", schema: String = "~",
    assignment: String = "~", expiry: UInt64? = 87_400,
    endpoints: String? = "rpc://proxy.example", assignmentName: String? = nil
) -> String {
    let recipient = "\(network):\(witness ? "wvout" : "utxob"):\(witness ? invoiceTestWitnessPayload : invoiceTestBlindPayload)"
    var query: [String] = []
    if let assignmentName { query.append("assignment_name=\(assignmentName)") }
    if let expiry { query.append("expiry=\(expiry)") }
    if let endpoints { query.append("endpoints=\(endpoints)") }
    return "rgb:\(asset)/\(schema)/\(assignment)/\(recipient)" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
}

@Test func outgoingInvoiceChecksLiteralEncodedAmountRatherThanLossyPublicAssignment() throws {
    let asset = try AssetID("rgb:\(invoiceTestAsset)")
    let amountInvoice = try RGBInvoice(invoiceTestString(assignment: "BF"))
    // With no schema/name, RN projects this literal amount to Any. It is
    // nevertheless an explicit 100-unit invoice and cannot authorize 101.
    #expect(try decodeRGBInvoiceLocally(amountInvoice).assignment.type == .any)
    let matched = try OnchainSendRequest(invoice: amountInvoice, amount: AssetAmount(100), assetID: asset)
    #expect(try validateOutgoingRGBInvoice(matched, network: .regtest, now: 1_000).invoice == amountInvoice)
    let changed = try OnchainSendRequest(invoice: amountInvoice, amount: AssetAmount(101), assetID: asset)
    #expect(throws: SDKError.self) { try validateOutgoingRGBInvoice(changed, network: .regtest, now: 1_000) }

    // A genuinely omitted amount permits the caller's explicit amount, even
    // when RN's schema projection would show Fungible(0).
    let open = try OnchainSendRequest(
        invoice: RGBInvoice(invoiceTestString(asset: invoiceTestAsset, schema: invoiceTestNiaSchema)),
        amount: AssetAmount(101)
    )
    #expect(try validateOutgoingRGBInvoice(open, network: .regtest, now: 1_000).assetID == asset)
}

@Test func outgoingInvoiceRejectsConflictsExpiryRightsAndWitnessInstructionMismatch() throws {
    let asset = try AssetID("rgb:\(invoiceTestAsset)")
    let witness = try WitnessData(amountSat: Satoshis(1_000))
    let valid = try OnchainSendRequest(
        invoice: RGBInvoice(invoiceTestString(witness: true, asset: invoiceTestAsset, assignment: "BF", assignmentName: "assetOwner")),
        amount: AssetAmount(100), witnessData: witness
    )
    #expect(try validateOutgoingRGBInvoice(valid, network: .regtest, now: 1_000).assetID == asset)
    for request in try [
        OnchainSendRequest(invoice: RGBInvoice(invoiceTestString()), amount: AssetAmount(100)),
        OnchainSendRequest(invoice: RGBInvoice(invoiceTestString(asset: invoiceTestAsset)), amount: AssetAmount(100), assetID: AssetID("rgb:different")),
        OnchainSendRequest(invoice: RGBInvoice(invoiceTestString(expiry: 1_000)), amount: AssetAmount(100), assetID: asset),
        OnchainSendRequest(invoice: RGBInvoice(invoiceTestString(endpoints: nil)), amount: AssetAmount(100), assetID: asset),
        OnchainSendRequest(invoice: RGBInvoice(invoiceTestString(witness: true)), amount: AssetAmount(100), assetID: asset),
        OnchainSendRequest(invoice: RGBInvoice(invoiceTestString()), amount: AssetAmount(100), assetID: asset, witnessData: witness),
        OnchainSendRequest(invoice: RGBInvoice(invoiceTestString(assignment: "BF", assignmentName: "inflationAllowance")), amount: AssetAmount(100), assetID: asset),
    ] {
        #expect(throws: SDKError.self) { try validateOutgoingRGBInvoice(request, network: .regtest, now: 1_000) }
    }
    #expect(throws: SDKError.self) { try validateOutgoingRGBInvoice(valid, network: .mainnet, now: 1_000) }
}

@Test func localRGBInvoiceDecodePreservesExactPublicFields() throws {
    for witness in [false, true] {
        let invoice = try RGBInvoice(invoiceTestString(witness: witness))
        let decoded = try decodeRGBInvoiceLocally(invoice)
        #expect(decoded.invoice == invoice)
        #expect(decoded.network == .regtest)
        #expect(decoded.assetID == nil && decoded.assetSchema == nil)
        #expect(decoded.assignment == Assignment(type: .any))
        #expect(decoded.expirationTimestamp?.rawValue == 87_400)
        #expect(decoded.transportEndpoints == ["rpc://proxy.example"])
        #expect(decoded.recipientID.contains(witness ? ":wvout:" : ":utxob:"))
    }
    let decoded = try decodeRGBInvoiceLocally(RGBInvoice(invoiceTestString(
        asset: invoiceTestAsset, assignment: "BF", assignmentName: "assetOwner"
    )))
    #expect(decoded.assetID?.value == "rgb:\(invoiceTestAsset)")
    #expect(decoded.assignment == Assignment(type: .fungible, amount: AssetAmount(100)))
}

@Test func localRGBInvoiceMalformedInputsNeverExposeInvoiceDetails() throws {
    for input in [
        "rgb:private-recipient", invoiceTestString().replacingOccurrences(of: "aVlYa", with: "aVlYb"),
        invoiceTestString() + "&expiry=1", invoiceTestString() + "&unreviewed=private-data",
        invoiceTestString().replacingOccurrences(of: "expiry=87400", with: "expiry=-1"),
    ] {
        do { _ = try decodeRGBInvoiceLocally(RGBInvoice(input)); Issue.record("invalid invoice must fail") }
        catch let error as SDKError {
            #expect(error.code == .invalidArgument)
            #expect(!error.message.contains("private") && !error.message.contains("proxy.example"))
        }
    }
}

@Test func receiveValidationBindsEveryLocallyCheckableIntentField() throws {
    let request = try OnchainReceiveRequest(witness: false)
    let valid = try decodeRGBInvoiceLocally(RGBInvoice(invoiceTestString()))
    let response = try OnchainReceiveResponse(
        invoice: valid.invoice, recipientID: valid.recipientID, expirationTimestamp: valid.expirationTimestamp
    )
    try validateReceivedRGBInvoice(response, request: request, network: .regtest, startedAt: 1_000, completedAt: 1_001, duration: 86_400)
    // The gateway envelope explicitly permits null; the invoice itself must
    // still contain a bounded expiry. Do not invent a public envelope value.
    let nullableEnvelope = try OnchainReceiveResponse(invoice: valid.invoice, recipientID: valid.recipientID)
    try validateReceivedRGBInvoice(nullableEnvelope, request: request, network: .regtest, startedAt: 1_000, completedAt: 1_001, duration: 86_400)
    let changedInvoices = [
        invoiceTestString(network: "bc"), invoiceTestString(witness: true),
        invoiceTestString(asset: invoiceTestAsset), invoiceTestString(assignment: "BF"),
        invoiceTestString(expiry: 87_399), invoiceTestString(expiry: 87_402),
        invoiceTestString(expiry: nil), invoiceTestString(endpoints: nil),
    ]
    for value in changedInvoices {
        let data = try decodeRGBInvoiceLocally(RGBInvoice(value))
        let bad = try OnchainReceiveResponse(invoice: data.invoice, recipientID: data.recipientID, expirationTimestamp: data.expirationTimestamp)
        #expect(throws: SDKError.self) {
            try validateReceivedRGBInvoice(bad, request: request, network: .regtest, startedAt: 1_000, completedAt: 1_001, duration: 86_400)
        }
    }
    for bad in [
        try OnchainReceiveResponse(invoice: valid.invoice, recipientID: "other-recipient", expirationTimestamp: valid.expirationTimestamp),
        try OnchainReceiveResponse(invoice: valid.invoice, recipientID: valid.recipientID, expirationTimestamp: .init(rawValue: 87_401)),
    ] {
        #expect(throws: SDKError.self) {
            try validateReceivedRGBInvoice(bad, request: request, network: .regtest, startedAt: 1_000, completedAt: 1_001, duration: 86_400)
        }
    }
}

@Test func receiveValidationChecksClockOverflowAndExpiredInvoices() throws {
    let data = try decodeRGBInvoiceLocally(RGBInvoice(invoiceTestString()))
    let response = try OnchainReceiveResponse(invoice: data.invoice, recipientID: data.recipientID, expirationTimestamp: data.expirationTimestamp)
    let cases: [(UInt64, UInt64, UInt64)] = [
        (1_001, 1_000, 86_400), (UInt64.max, UInt64.max, 86_400),
        (1_000, 87_400, 86_400), (1_000, 1_000, 0),
    ]
    for (start, end, duration) in cases {
        #expect(throws: SDKError.self) {
            try validateReceivedRGBInvoice(response, request: OnchainReceiveRequest(witness: false), network: .regtest, startedAt: start, completedAt: end, duration: duration)
        }
    }
}

@Test func receiveValidationAcceptsOnlyTheDocumentedUtexoSignetAlias() throws {
    let data = try decodeRGBInvoiceLocally(RGBInvoice(invoiceTestString(network: "sb")))
    #expect(data.network == .signet)
    let response = try OnchainReceiveResponse(invoice: data.invoice, recipientID: data.recipientID, expirationTimestamp: data.expirationTimestamp)
    let request = try OnchainReceiveRequest(witness: false)
    for network in [Network.signet, .utexo] {
        try validateReceivedRGBInvoice(response, request: request, network: network, startedAt: 1_000, completedAt: 1_001, duration: 86_400)
    }
    for network in [Network.mainnet, .testnet, .testnet4, .regtest] {
        #expect(throws: SDKError.self) {
            try validateReceivedRGBInvoice(response, request: request, network: network, startedAt: 1_000, completedAt: 1_001, duration: 86_400)
        }
    }
}

@Test func receiveValidationDistinguishesEncodedAmountFromPublicProjection() throws {
    let assetID = try AssetID("rgb:\(invoiceTestAsset)")
    let unspecified = try OnchainReceiveRequest(assetID: assetID, witness: false)
    let exactAmount = try OnchainReceiveRequest(amount: AssetAmount(100), assetID: assetID, witness: false)
    let cases: [(String, OnchainReceiveRequest, Bool)] = [
        // Both omitted and explicitly encoded zero project to Fungible(0), but
        // only omitted state preserves a caller's unspecified amount.
        (invoiceTestString(asset: invoiceTestAsset, schema: invoiceTestNiaSchema), unspecified, true),
        (invoiceTestString(asset: invoiceTestAsset, schema: invoiceTestNiaSchema, assignment: "aa"), unspecified, false),
        (invoiceTestString(asset: invoiceTestAsset, schema: invoiceTestNiaSchema, assignment: "BF"), exactAmount, true),
        (invoiceTestString(asset: invoiceTestAsset, schema: invoiceTestNiaSchema), exactAmount, false),
        (invoiceTestString(asset: invoiceTestAsset, assignment: "BF", assignmentName: "assetOwner"), exactAmount, true),
        (invoiceTestString(asset: invoiceTestAsset, assignment: "BF"), exactAmount, false),
        (invoiceTestString(asset: invoiceTestAsset, assignment: "BF", assignmentName: "inflationAllowance"), exactAmount, false),
        (invoiceTestString(schema: invoiceTestNiaSchema), try OnchainReceiveRequest(witness: false), false),
    ]
    for (value, request, accepted) in cases {
        let data = try decodeRGBInvoiceLocally(RGBInvoice(value))
        let response = try OnchainReceiveResponse(invoice: data.invoice, recipientID: data.recipientID, expirationTimestamp: data.expirationTimestamp)
        if accepted {
            try validateReceivedRGBInvoice(response, request: request, network: .regtest, startedAt: 1_000, completedAt: 1_001, duration: 86_400)
        } else {
            #expect(throws: SDKError.self) {
                try validateReceivedRGBInvoice(response, request: request, network: .regtest, startedAt: 1_000, completedAt: 1_001, duration: 86_400)
            }
        }
    }
    #expect(throws: SDKError.self) { try OnchainReceiveRequest(amount: AssetAmount(0)) }
    #expect(throws: SDKError.self) { try InvoiceRequest(amount: AssetAmount(0)) }
}

@Test func publicReceiveMethodsValidateInjectedBackendResults() async throws {
    for tampered in [false, true] {
        let backend = InvoiceTestBackend(tampered: tampered)
        let wallet = UTEXOWallet(
            configuration: try WalletConfiguration(walletID: WalletID("receive-tests-\(tampered)"), network: .regtest),
            backend: backend, keyProvider: InvoiceTestKeys(), operationJournal: InMemoryOperationJournal()
        )
        try await wallet.initialize()
        try await wallet.unlock()
        if tampered {
            await #expect(throws: SDKError.self) { _ = try await wallet.onchainReceive(OnchainReceiveRequest()) }
            await #expect(throws: SDKError.self) { _ = try await wallet.blindReceive(InvoiceRequest()) }
            await #expect(throws: SDKError.self) { _ = try await wallet.witnessReceive(InvoiceRequest()) }
        } else {
            let onchain = try await wallet.onchainReceive(OnchainReceiveRequest())
            #expect(onchain.batchTransferIndex == 17)
            let blind = try await wallet.blindReceive(InvoiceRequest())
            #expect(blind.batchTransferIndex == 17 && blind.recipientID.contains(":utxob:"))
            let witness = try await wallet.witnessReceive(InvoiceRequest())
            #expect(witness.batchTransferIndex == 17 && witness.recipientID.contains(":wvout:"))
        }
        #expect(await backend.calls == 5)
        try await wallet.destroy()
    }
}

@Test func publicInvoiceDecodeIsLocalAndLifecycleAware() async throws {
    let backend = InvoiceTestBackend()
    let wallet = UTEXOWallet(
        configuration: try WalletConfiguration(walletID: WalletID("invoice-tests"), network: .regtest),
        backend: backend, keyProvider: InvoiceTestKeys(), operationJournal: InMemoryOperationJournal()
    )
    let invoice = try RGBInvoice(invoiceTestString())
    await #expect(throws: SDKError.self) { _ = try await wallet.decodeRGBInvoice(invoice) }
    try await wallet.initialize()
    try await wallet.unlock()
    #expect(await wallet.capabilities.localRGBInvoiceParsing)
    let first = try await wallet.decodeRGBInvoice(invoice)
    #expect(try await wallet.decodeRgbInvoice(invoice) == first)
    #expect(await backend.calls == 2) // initialize and watch-only registration only
    try await wallet.destroy()
    await #expect(throws: SDKError.self) { _ = try await wallet.decodeRGBInvoice(invoice) }
}

@Test func publicReceiveHonorsCancellationEvenWhenAnInjectedBackendReturns() async throws {
    let backend = InvoiceTestBackend(cancelReceive: true)
    let wallet = UTEXOWallet(
        configuration: try WalletConfiguration(walletID: WalletID("receive-cancel"), network: .regtest),
        backend: backend, keyProvider: InvoiceTestKeys(), operationJournal: InMemoryOperationJournal()
    )
    try await wallet.initialize()
    try await wallet.unlock()
    let onchain = Task { try await wallet.onchainReceive(OnchainReceiveRequest()) }
    await #expect(throws: CancellationError.self) { _ = try await onchain.value }
    let blind = Task { try await wallet.blindReceive(InvoiceRequest()) }
    await #expect(throws: CancellationError.self) { _ = try await blind.value }
    let witness = Task { try await wallet.witnessReceive(InvoiceRequest()) }
    await #expect(throws: CancellationError.self) { _ = try await witness.value }
    #expect(await backend.calls == 5)
    try await wallet.destroy()
}

private struct InvoiceTestKeys: WalletKeyProvider {
    func loadSeed(parameters: WalletUnlockParameters) async throws -> SecretSeed {
        try SecretSeed(copying: Array(repeating: UInt8(7), count: 64))
    }
}

private actor InvoiceTestBackend: WalletBackend {
    var calls = 0
    let tampered: Bool
    let cancelReceive: Bool
    init(tampered: Bool = false, cancelReceive: Bool = false) {
        self.tampered = tampered
        self.cancelReceive = cancelReceive
    }
    func preflightOperation(_ operation: OperationKind) async throws {
        throw SDKError.unsupported("invoice test backend cannot move funds")
    }
    func initialize(_ request: BackendInitializeRequest) async throws -> BackendSession {
        calls += 1
        return try BackendSession(id: "invoice-test-session", apiVersion: 1, network: request.network)
    }
    func registerWallet(_ request: RegisterWalletRequest) async throws { calls += 1 }
    func shutdown(session: BackendSession) async throws { calls += 1 }
    func onchainReceive(context: BackendContext, request: OnchainReceiveRequest) async throws -> OnchainReceiveResponse {
        let result = try receive(witness: request.witness)
        return try OnchainReceiveResponse(invoice: result.invoice, recipientID: result.recipientID, expirationTimestamp: result.expirationTimestamp, batchTransferIndex: result.batchTransferIndex)
    }
    func blindReceive(context: BackendContext, request: InvoiceRequest) async throws -> InvoiceReceiveData {
        try receive(witness: false)
    }
    func witnessReceive(context: BackendContext, request: InvoiceRequest) async throws -> InvoiceReceiveData {
        try receive(witness: true)
    }
    private func receive(witness: Bool) throws -> InvoiceReceiveData {
        calls += 1
        if cancelReceive { withUnsafeCurrentTask { $0?.cancel() } }
        let expiry = UInt64(Date().timeIntervalSince1970) + 86_400
        let data = try decodeRGBInvoiceLocally(RGBInvoice(invoiceTestString(
            witness: witness, assignment: tampered ? "BF" : "~", expiry: expiry
        )))
        return try InvoiceReceiveData(invoice: data.invoice, recipientID: data.recipientID, expirationTimestamp: data.expirationTimestamp, batchTransferIndex: 17)
    }
}
