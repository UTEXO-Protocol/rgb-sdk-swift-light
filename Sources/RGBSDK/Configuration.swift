import Foundation

/// Logical SDK network. UTEXO intentionally uses Signet Bitcoin parameters.
public enum Network: String, Codable, CaseIterable, Sendable {
    case mainnet
    case testnet
    case testnet4
    case signet
    case regtest
    case utexo

    public var chainNetwork: String { self == .utexo ? Network.signet.rawValue : rawValue }
}

public enum RBFPolicy: String, Codable, Sendable {
    case required
    case allowed
    case forbidden
}

public enum AccountKind: String, Codable, Sendable {
    case vanilla
    case colored
}

public enum Keychain: String, Codable, Sendable {
    case external
    case change
}

public enum OperationKind: String, Codable, CaseIterable, Sendable {
    case sendBtc
    case createUtxos
    case onchainSend
    case inflate
}

/// App-owned safety ceilings. The backend cannot raise them.
public struct LocalSigningPolicy: Hashable, Sendable {
    public static let hardMaximumAbsoluteFee = Satoshis(unchecked: 1_000_000)
    public static let hardMaximumFeeRate = FeeRate(uncheckedMilliSatsPerVByte: 100_000)
    public static let hardMaximumPSBTBytes: UInt32 = 1_000_000
    public static let hardMaximumInputs: UInt32 = 128
    public static let hardMaximumOutputs: UInt32 = 256
    public static let hardMaximumChildIndex: UInt32 = 1_000_000

    public let maximumAbsoluteFee: Satoshis
    public let maximumFeeRate: FeeRate
    public let maximumPSBTBytes: UInt32
    public let maximumInputs: UInt32
    public let maximumOutputs: UInt32
    public let maximumChildIndex: UInt32
    public let rbf: RBFPolicy

    public init(
        maximumAbsoluteFee: Satoshis = hardMaximumAbsoluteFee,
        maximumFeeRate: FeeRate = hardMaximumFeeRate,
        maximumPSBTBytes: UInt32 = hardMaximumPSBTBytes,
        maximumInputs: UInt32 = hardMaximumInputs,
        maximumOutputs: UInt32 = hardMaximumOutputs,
        maximumChildIndex: UInt32 = hardMaximumChildIndex,
        rbf: RBFPolicy = .required
    ) throws {
        guard (100...Self.hardMaximumPSBTBytes).contains(maximumPSBTBytes) else {
            throw SDKError.invalidArgument(
                "maximumPSBTBytes",
                "must be between 100 and \(Self.hardMaximumPSBTBytes)"
            )
        }
        guard (1...Self.hardMaximumInputs).contains(maximumInputs) else {
            throw SDKError.invalidArgument("maximumInputs", "must be between 1 and \(Self.hardMaximumInputs)")
        }
        guard (1...Self.hardMaximumOutputs).contains(maximumOutputs) else {
            throw SDKError.invalidArgument("maximumOutputs", "must be between 1 and \(Self.hardMaximumOutputs)")
        }
        guard maximumChildIndex <= Self.hardMaximumChildIndex else {
            throw SDKError.invalidArgument(
                "maximumChildIndex",
                "must not exceed \(Self.hardMaximumChildIndex)"
            )
        }
        guard maximumAbsoluteFee <= Self.hardMaximumAbsoluteFee else {
            throw SDKError.invalidArgument(
                "maximumAbsoluteFee",
                "must not exceed the SDK hard limit"
            )
        }
        guard maximumFeeRate <= Self.hardMaximumFeeRate else {
            throw SDKError.invalidArgument(
                "maximumFeeRate",
                "must not exceed the SDK hard limit"
            )
        }
        guard rbf == .required else {
            throw SDKError.unsupported("non-RBF transaction profiles")
        }
        self.maximumAbsoluteFee = maximumAbsoluteFee
        self.maximumFeeRate = maximumFeeRate
        self.maximumPSBTBytes = maximumPSBTBytes
        self.maximumInputs = maximumInputs
        self.maximumOutputs = maximumOutputs
        self.maximumChildIndex = maximumChildIndex
        self.rbf = rbf
    }

    public static let `default` = Self(
        validatedMaximumAbsoluteFee: hardMaximumAbsoluteFee,
        maximumFeeRate: hardMaximumFeeRate,
        maximumPSBTBytes: hardMaximumPSBTBytes,
        maximumInputs: hardMaximumInputs,
        maximumOutputs: hardMaximumOutputs,
        maximumChildIndex: hardMaximumChildIndex,
        rbf: .required
    )

    private init(
        validatedMaximumAbsoluteFee maximumAbsoluteFee: Satoshis,
        maximumFeeRate: FeeRate,
        maximumPSBTBytes: UInt32,
        maximumInputs: UInt32,
        maximumOutputs: UInt32,
        maximumChildIndex: UInt32,
        rbf: RBFPolicy
    ) {
        self.maximumAbsoluteFee = maximumAbsoluteFee
        self.maximumFeeRate = maximumFeeRate
        self.maximumPSBTBytes = maximumPSBTBytes
        self.maximumInputs = maximumInputs
        self.maximumOutputs = maximumOutputs
        self.maximumChildIndex = maximumChildIndex
        self.rbf = rbf
    }
}

public struct WalletConfiguration: Hashable, Sendable {
    public let walletID: WalletID
    public let network: Network
    public let signingPolicy: LocalSigningPolicy
    public let minimumBackendAPIVersion: UInt32
    public let maximumBackendAPIVersion: UInt32

    public init(
        walletID: WalletID,
        network: Network,
        signingPolicy: LocalSigningPolicy = .default,
        minimumBackendAPIVersion: UInt32 = 1,
        maximumBackendAPIVersion: UInt32 = 1
    ) throws {
        guard minimumBackendAPIVersion > 0 else {
            throw SDKError.invalidArgument("minimumBackendAPIVersion", "must be positive")
        }
        guard maximumBackendAPIVersion >= minimumBackendAPIVersion else {
            throw SDKError.invalidArgument(
                "maximumBackendAPIVersion",
                "must not be lower than minimumBackendAPIVersion"
            )
        }
        self.walletID = walletID
        self.network = network
        self.signingPolicy = signingPolicy
        self.minimumBackendAPIVersion = minimumBackendAPIVersion
        self.maximumBackendAPIVersion = maximumBackendAPIVersion
    }
}

public struct WalletCapabilities: Hashable, Sendable {
    public static let derivationProfileV1 = "utexo.bip86.v1"
    public static let signingProfileV1 = "utexo.psbt.bip86.v1"

    public let localKeyDerivation: Bool
    public let localTransactionValidation: Bool
    public let localTransactionSigning: Bool
    /// Invoice syntax and caller-intent checks, not RGB state validation.
    public let localRGBInvoiceParsing: Bool
    public let localRGBValidation: Bool
    public let localSigningOperations: Set<OperationKind>
    public let derivationProfile: String
    public let signingProfile: String

    static let locked = Self(
        localKeyDerivation: false,
        localTransactionValidation: false,
        localTransactionSigning: false,
        localRGBInvoiceParsing: false,
        localRGBValidation: false,
        localSigningOperations: [],
        derivationProfile: derivationProfileV1,
        signingProfile: signingProfileV1
    )
}
