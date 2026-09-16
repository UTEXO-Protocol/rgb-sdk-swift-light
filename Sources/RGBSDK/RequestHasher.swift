import CryptoKit
import Foundation

enum RequestHasher {
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
