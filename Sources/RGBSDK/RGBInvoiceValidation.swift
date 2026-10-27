import Foundation
internal import UtexoLocalSignerBindings

/// Local syntax/checksum decoding, not proof of RGB state or recipient ownership.
func decodeRGBInvoiceLocally(_ invoice: RGBInvoice) throws -> InvoiceData {
    try decodeNativeRGBInvoice(invoice).data
}

/// Caller-intent validation for the currently supported fungible send domain.
/// This is independent of a server preparation and does not validate RGB state.
/// Crucially, use the encoded state rather than RN's lossy public projection.
func validateOutgoingRGBInvoice(
    _ request: OnchainSendRequest,
    network: Network,
    now: UInt64
) throws -> InvoiceData {
    let decoded = try decodeNativeRGBInvoice(request.invoice)
    let data = decoded.data
    guard data.network == network || (network == .utexo && data.network == .signet) else {
        throw SDKError.invalidArgument("invoice", "uses a different Bitcoin network")
    }
    guard data.assignmentName == nil || data.assignmentName == "assetOwner",
          data.assignment.type == .fungible || data.assignment.type == .any else {
        throw SDKError.invalidArgument("invoice", "is not a fungible owner assignment")
    }
    switch decoded.encodedState.kind {
    case .omitted:
        guard decoded.encodedState.amount == nil else {
            throw SDKError.invalidArgument("invoice", "has an inconsistent encoded assignment")
        }
    case .amount:
        guard decoded.encodedState.amount.map(AssetAmount.init) == request.amount else {
            throw SDKError.invalidArgument("amount", "does not match the encoded invoice amount")
        }
    case .nonFungible:
        throw SDKError.invalidArgument("invoice", "non-fungible sends are outside this profile")
    }
    if let invoiceAsset = data.assetID, let requestedAsset = request.assetID,
       invoiceAsset != requestedAsset {
        throw SDKError.invalidArgument("assetID", "does not match the invoice asset")
    }
    guard data.assetID != nil || request.assetID != nil else {
        throw SDKError.invalidArgument("assetID", "is required when the invoice omits the asset")
    }
    guard data.expirationTimestamp.map({ $0.rawValue > now }) ?? true else {
        throw SDKError.invalidArgument("invoice", "has expired")
    }
    guard !data.transportEndpoints.isEmpty,
          Set(data.transportEndpoints).count == data.transportEndpoints.count else {
        throw SDKError.invalidArgument("invoice", "requires unique supported transport endpoints")
    }
    // A witness recipient requires an explicit BTC output authorization. A
    // blind recipient must not silently discard supplied witness instructions.
    guard decoded.witness == (request.witnessData != nil) else {
        throw SDKError.invalidArgument("witnessData", "must be present exactly for a witness recipient")
    }
    return data
}

private func decodeNativeRGBInvoice(
    _ invoice: RGBInvoice
) throws -> (
    data: InvoiceData, witness: Bool,
    encodedState: UtexoLocalSignerBindings.RgbInvoiceEncodedState
) {
    do {
        let decoded = try UtexoLocalSignerBindings.decodeRgbInvoice(invoice: invoice.value)
        let type: AssignmentType
        switch decoded.assignment.kind {
        case .fungible: type = .fungible
        case .nonFungible: type = .nonFungible
        case .inflationRight: type = .inflationRight
        case .any: type = .any
        }
        let expiration: UnixSeconds?
        if let timestamp = decoded.expirationTimestamp {
            guard let unsigned = UInt64(exactly: timestamp) else {
                throw SDKError.invalidArgument("invoice", "expiration precedes the supported Unix time domain")
            }
            expiration = .init(rawValue: unsigned)
        } else {
            expiration = nil
        }
        return (
            try InvoiceData(
                invoice: invoice, recipientID: decoded.recipientId,
                assetSchema: decoded.assetSchema, assetID: decoded.assetId.map(AssetID.init),
                network: Network(ffi: decoded.network),
                assignment: Assignment(type: type, amount: decoded.assignment.amount.map(AssetAmount.init)),
                assignmentName: decoded.assignmentName, expirationTimestamp: expiration,
                transportEndpoints: decoded.transportEndpoints
            ),
            decoded.recipientType == .witness,
            decoded.encodedState
        )
    } catch let error as SDKError {
        throw error
    } catch {
        // No attacker-controlled invoice, endpoint or parser detail is exposed.
        throw SDKError.invalidArgument("invoice", "is invalid or outside the supported RGB invoice profile")
    }
}

/// The gateway stamps a receive invoice's expiry from its own clock, so the
/// expiry is checked against the requested duration with this much disagreement
/// allowed between the device and gateway clocks. An invoice already expired by
/// the device clock is still rejected.
let maximumInvoiceClockSkewSeconds: UInt64 = 300

/// Verify the untrusted invoice represents this exact receive request. The
/// gateway remains trusted for the server-held blinded seal/watch-only receive
/// state: this check does not prove key ownership or validate a consignment.
func validateReceivedRGBInvoice(
    _ response: OnchainReceiveResponse,
    request: OnchainReceiveRequest,
    network: Network,
    startedAt: UInt64,
    completedAt: UInt64,
    duration: UInt64
) throws {
    do {
        let decoded = try decodeNativeRGBInvoice(response.invoice)
        let data = decoded.data
        // RN-shaped public assignment data is intentionally a lossy projection:
        // a missing known-schema amount can look like Fungible(0), and an
        // unnamed no-schema encoded amount can look like Any. Authorization
        // must inspect what is literally encoded, never that projection alone.
        let stateMatches: Bool
        if let requestedAmount = request.amount {
            stateMatches = decoded.encodedState.kind == .amount
                && decoded.encodedState.amount.map(AssetAmount.init) == requestedAmount
                && data.assignment == Assignment(type: .fungible, amount: requestedAmount)
        } else {
            stateMatches = decoded.encodedState.kind == .omitted
                && decoded.encodedState.amount == nil
        }
        let earliestExpiry = startedAt.addingReportingOverflow(duration)
        let latestExpiry = completedAt.addingReportingOverflow(duration)
        let minimumExpiry = earliestExpiry.partialValue.subtractingReportingOverflow(maximumInvoiceClockSkewSeconds)
        let maximumExpiry = latestExpiry.partialValue.addingReportingOverflow(maximumInvoiceClockSkewSeconds)
        // UTEXO is a logical Signet configuration; invoices carry only the
        // underlying chain marker. Preserve decoded Signet in public data.
        let networkMatches = data.network == network || (network == .utexo && data.network == .signet)
        guard completedAt >= startedAt, duration > 0,
              !earliestExpiry.overflow, !latestExpiry.overflow,
              !minimumExpiry.overflow, !maximumExpiry.overflow,
              networkMatches, decoded.witness == request.witness,
              data.assetID == request.assetID,
              request.assetID != nil || data.assetSchema == nil,
              stateMatches,
              data.assignmentName == nil || data.assignmentName == "assetOwner",
              response.recipientID == data.recipientID,
              let expiry = data.expirationTimestamp,
              response.expirationTimestamp == nil || response.expirationTimestamp == expiry,
              expiry.rawValue > completedAt,
              (minimumExpiry.partialValue...maximumExpiry.partialValue).contains(expiry.rawValue),
              !data.transportEndpoints.isEmpty,
              Set(data.transportEndpoints).count == data.transportEndpoints.count else {
            throw SDKError.backendProtocolMismatch("gateway receive invoice does not match local intent")
        }
    } catch {
        throw SDKError.backendProtocolMismatch("gateway receive invoice does not match local intent")
    }
}
