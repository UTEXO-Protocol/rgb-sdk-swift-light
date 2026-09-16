import Foundation
internal import UtexoLocalSignerBindings

public struct AccountXpubs: Hashable, Sendable {
    public let vanilla: String
    public let colored: String

    public init(vanilla: String, colored: String) {
        self.vanilla = vanilla
        self.colored = colored
    }
}

/// RN-shaped key result whose secret fields are redacting, closeable objects.
public final class GeneratedKeys: @unchecked Sendable, CustomStringConvertible {
    public let mnemonic: SecretMnemonic?
    public let xpub: String
    public let accountXpubVanilla: String
    public let accountXpubColored: String
    public let masterFingerprint: String
    public let xpriv: SecretExtendedPrivateKey

    public var accountXpubs: AccountXpubs {
        .init(vanilla: accountXpubVanilla, colored: accountXpubColored)
    }

    init(
        mnemonic: SecretMnemonic?,
        xpub: String,
        accountXpubVanilla: String,
        accountXpubColored: String,
        masterFingerprint: String,
        xpriv: SecretExtendedPrivateKey
    ) {
        self.mnemonic = mnemonic
        self.xpub = xpub
        self.accountXpubVanilla = accountXpubVanilla
        self.accountXpubColored = accountXpubColored
        self.masterFingerprint = masterFingerprint
        self.xpriv = xpriv
    }

    deinit { close() }

    public func close() {
        mnemonic?.close()
        xpriv.close()
    }

    public var description: String {
        "GeneratedKeys(mnemonic=[REDACTED], xpub=\(xpub), "
            + "accountXpubVanilla=\(accountXpubVanilla), "
            + "accountXpubColored=\(accountXpubColored), "
            + "masterFingerprint=\(masterFingerprint), xpriv=[REDACTED])"
    }
}

/// Generates a 12-word English BIP39 wallet using operating-system entropy.
public func generateKeys(network: Network) throws -> GeneratedKeys {
    do {
        return try UtexoLocalSignerBindings.generateKeys(network: network.ffi)
            .sdk(expectMnemonic: true)
    } catch let error as SDKError {
        throw error
    } catch {
        throw mapSignerError(error)
    }
}

/// RN compatibility alias for `generateKeys`.
public func createWallet(network: Network) throws -> GeneratedKeys {
    try generateKeys(network: network)
}

public func deriveKeysFromMnemonic(
    network: Network,
    mnemonic: SecretMnemonic,
    passphraseUTF8: [UInt8] = []
) throws -> GeneratedKeys {
    var passphrase = Array(passphraseUTF8)
    defer { wipe(&passphrase) }
    return try mnemonic.withCopy { mnemonicBytes in
        var mnemonicData = Data(mnemonicBytes)
        var passphraseData = Data(passphrase)
        defer {
            mnemonicData.resetBytes(in: mnemonicData.startIndex..<mnemonicData.endIndex)
            passphraseData.resetBytes(in: passphraseData.startIndex..<passphraseData.endIndex)
        }
        do {
            return try UtexoLocalSignerBindings.deriveKeysFromMnemonic(
                network: network.ffi,
                mnemonicUtf8: mnemonicData,
                passphraseUtf8: passphraseData
            ).sdk(expectMnemonic: true)
        } catch let error as SDKError {
            throw error
        } catch {
            throw mapSignerError(error)
        }
    }
}

public func deriveKeysFromSeed(network: Network, seed: SecretSeed) throws -> GeneratedKeys {
    try seed.withCopy { seedBytes in
        var data = Data(seedBytes)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        do {
            return try UtexoLocalSignerBindings.deriveKeysFromSeed(network: network.ffi, seed: data)
                .sdk(expectMnemonic: false)
        } catch let error as SDKError {
            throw error
        } catch {
            throw mapSignerError(error)
        }
    }
}

/// Derives the exact 64-byte BIP39 seed used by the local signer.
///
/// This is primarily for provisioning device-bound encrypted storage. The
/// returned object must be closed promptly after storage succeeds or fails.
public func deriveSeedFromMnemonic(
    mnemonic: SecretMnemonic,
    passphraseUTF8: [UInt8] = []
) throws -> SecretSeed {
    var passphrase = Array(passphraseUTF8)
    defer { wipe(&passphrase) }
    return try mnemonic.withCopy { mnemonicBytes in
        var mnemonicData = Data(mnemonicBytes)
        var passphraseData = Data(passphrase)
        defer {
            mnemonicData.resetBytes(in: mnemonicData.startIndex..<mnemonicData.endIndex)
            passphraseData.resetBytes(in: passphraseData.startIndex..<passphraseData.endIndex)
        }
        do {
            var result = try UtexoLocalSignerBindings.deriveSeedFromMnemonic(
                mnemonicUtf8: mnemonicData,
                passphraseUtf8: passphraseData
            )
            defer { result.resetBytes(in: result.startIndex..<result.endIndex) }
            guard result.count == SecretSeed.byteCount else {
                throw SDKError.invariant("native signer returned a seed with the wrong length")
            }
            var bytes = Array(result)
            defer { wipe(&bytes) }
            return try SecretSeed(copying: bytes)
        } catch let error as SDKError {
            throw error
        } catch {
            throw mapSignerError(error)
        }
    }
}

/// Exactly one source must be supplied.
public func deriveKeysFromMnemonicOrSeed(
    network: Network,
    mnemonic: SecretMnemonic? = nil,
    seed: SecretSeed? = nil,
    passphraseUTF8: [UInt8] = []
) throws -> GeneratedKeys {
    switch (mnemonic, seed) {
    case let (.some(mnemonic), .none):
        return try deriveKeysFromMnemonic(
            network: network,
            mnemonic: mnemonic,
            passphraseUTF8: passphraseUTF8
        )
    case let (.none, .some(seed)):
        guard passphraseUTF8.isEmpty else {
            throw SDKError.invalidArgument("passphrase", "can only be supplied with a mnemonic")
        }
        return try deriveKeysFromSeed(network: network, seed: seed)
    default:
        throw SDKError.invalidArgument("mnemonicOrSeed", "exactly one source must be supplied")
    }
}

/// RN compatibility alias for `deriveKeysFromMnemonicOrSeed`.
public func restoreKeys(
    network: Network,
    mnemonic: SecretMnemonic? = nil,
    seed: SecretSeed? = nil,
    passphraseUTF8: [UInt8] = []
) throws -> GeneratedKeys {
    try deriveKeysFromMnemonicOrSeed(
        network: network,
        mnemonic: mnemonic,
        seed: seed,
        passphraseUTF8: passphraseUTF8
    )
}

public func accountXpubsFromMnemonic(
    network: Network,
    mnemonic: SecretMnemonic,
    passphraseUTF8: [UInt8] = []
) throws -> AccountXpubs {
    let keys = try deriveKeysFromMnemonic(
        network: network,
        mnemonic: mnemonic,
        passphraseUTF8: passphraseUTF8
    )
    defer { keys.close() }
    return keys.accountXpubs
}

@available(*, deprecated, message: "Root xpriv export is dangerous; store an encrypted seed instead")
public func getXprivFromMnemonic(
    network: Network,
    mnemonic: SecretMnemonic,
    passphraseUTF8: [UInt8] = []
) throws -> SecretExtendedPrivateKey {
    let keys = try deriveKeysFromMnemonic(
        network: network,
        mnemonic: mnemonic,
        passphraseUTF8: passphraseUTF8
    )
    let result = try keys.xpriv.withStringCopy(ExtendedPrivateKey.init)
    keys.close()
    return result
}

public func getXpubFromXpriv(_ xpriv: SecretExtendedPrivateKey) throws -> String {
    try xpriv.withStringCopy { value in
        do { return try UtexoLocalSignerBindings.getXpubFromXpriv(xpriv: value) }
        catch { throw mapSignerError(error) }
    }
}

@available(*, deprecated, message: "Root xpriv import is dangerous; restore from an encrypted seed instead")
public func deriveKeysFromXpriv(
    network: Network,
    xpriv: SecretExtendedPrivateKey
) throws -> GeneratedKeys {
    try xpriv.withStringCopy { value in
        do {
            return try UtexoLocalSignerBindings.deriveKeysFromXpriv(network: network.ffi, xpriv: value)
                .sdk(expectMnemonic: false)
        } catch let error as SDKError {
            throw error
        } catch {
            throw mapSignerError(error)
        }
    }
}

private extension UtexoLocalSignerBindings.GeneratedKeys {
    func sdk(expectMnemonic: Bool) throws -> GeneratedKeys {
        try validatePublicKeyField(xpub, field: "xpub")
        try validatePublicKeyField(accountXpubVanilla, field: "accountXpubVanilla")
        try validatePublicKeyField(accountXpubColored, field: "accountXpubColored")
        guard isASCIIHex(masterFingerprint, exactByteCount: 8) else {
            throw SDKError.invariant("native signer returned an invalid fingerprint")
        }
        guard !xpriv.isEmpty, xpriv.utf8.count <= 256 else {
            throw SDKError.invariant("native signer returned an invalid xpriv")
        }
        guard expectMnemonic == !mnemonic.isEmpty else {
            throw SDKError.invariant("native signer returned an unexpected mnemonic shape")
        }
        return GeneratedKeys(
            mnemonic: mnemonic.isEmpty ? nil : RecoveryPhrase(mnemonic),
            xpub: xpub,
            accountXpubVanilla: accountXpubVanilla,
            accountXpubColored: accountXpubColored,
            masterFingerprint: masterFingerprint,
            xpriv: ExtendedPrivateKey(xpriv)
        )
    }
}

private func validatePublicKeyField(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 256 else {
        throw SDKError.invariant("native signer returned an invalid \(field)")
    }
}
