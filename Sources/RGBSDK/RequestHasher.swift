import CryptoKit
import Foundation

enum RequestHasher {
    static func createUtxos(network: Network, request: CreateUtxosRequest) throws -> RequestHash {
        try digest([
            "operation", "createUtxos", "network", network.rawValue,
            "upTo", String(request.upTo), "num", request.num.map(String.init) ?? "null",
            "sizeSats", request.size.map { String($0.value) } ?? "null",
            "feeRateMsatPerVbyte", String(request.feeRate.milliSatsPerVByte),
            "skipSync", String(request.skipSync),
        ])
    }

    static func onchainSend(network: Network, request: OnchainSendRequest) throws -> RequestHash {
        try digest([
            "operation", "onchainSend", "network", network.rawValue,
            "invoice", request.invoice.value, "assetId", request.assetID?.value ?? "null",
            "amount", request.amount.decimal,
            "witnessAmountSats", request.witnessData.map { String($0.amountSat.value) } ?? "null",
            "witnessBlinding", request.witnessData?.blinding.map(String.init) ?? "null",
            "donation", String(request.donation),
            "feeRateMsatPerVbyte", String(request.feeRate.milliSatsPerVByte),
            "minConfirmations", String(request.minConfirmations.rawValue),
            "skipSync", String(request.skipSync),
        ])
    }

    private static func digest(_ fields: [String]) throws -> RequestHash {
        var encoder = CanonicalHashEncoder()
        try encoder.append("utexo.wallet.operation-intent.v1")
        for field in fields { try encoder.append(field) }
        return RequestHash(trustedSHA256Hex: encoder.finalizeHex())
    }

    static func sendBtc(network: Network, request: SendBtcRequest) throws -> RequestHash {
        var encoder = CanonicalHashEncoder()
        for value in [
            "utexo.wallet.operation-intent.v1",
            "operation", "sendBtc",
            "network", network.rawValue,
            "address", request.address.value,
            "amountSats", String(request.amount.value),
            "feeRateMsatPerVbyte", String(request.feeRate.milliSatsPerVByte),
            "skipSync", request.skipSync ? "true" : "false",
        ] {
            try encoder.append(value)
        }
        return RequestHash(trustedSHA256Hex: encoder.finalizeHex())
    }
}

private struct CanonicalHashEncoder {
    private var hasher = SHA256()

    mutating func append(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard let length = UInt32(exactly: bytes.count) else {
            throw SDKError.invalidArgument("requestHashField", "must fit in an unsigned 32-bit length")
        }
        append(length)
        hasher.update(data: Data(bytes))
    }

    private mutating func append(_ value: UInt32) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { hasher.update(bufferPointer: $0) }
    }

    mutating func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
