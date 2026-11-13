import Foundation
import RGBSDK

/// A minimal, readable integration of the UTEXO Swift SDK against a lightsdk
/// gateway (`rln-gateway`) deployment. Every SDK call the example makes is in this
/// file; `UTEXOExampleApp.swift` only lays out the screen.
///
/// It covers the lifecycle an app actually has to get right:
///
///   provision seed (once) -> create -> initialize -> unlock -> read / spend -> destroy
///
/// Spending (BTC sends, UTXO creation, RGB sends) is signed on the device. The
/// gateway prepares each transaction, the local signer checks it against the
/// request and a chain tip from a source the app trusts, signs, and only then
/// asks the gateway to broadcast.
///
/// Fill in the gateway URL and paste a bearer token, then press Connect. The
/// simulator shares the Mac's network, so a gateway on your own machine is
/// `http://127.0.0.1:<port>`.
@MainActor
final class ExampleWallet: ObservableObject {
    @Published var gatewayURL = Defaults.gatewayURL
    @Published var bearerToken = ""
    @Published var walletID = Defaults.walletID
    @Published var network = Defaults.network
    @Published var tipURL = Defaults.chainTipURL
    @Published var recipient = ""
    @Published var amount = ""
    @Published var assetID = ""
    @Published private(set) var log = ""

    private var wallet: UTEXOWallet?
    private var started = false

    static let networks: [Network] = [.signet, .regtest, .testnet, .mainnet]

    /// Every wallet action, by the name a scripted run uses for it.
    static let actionNames = [
        "address", "balance", "sync", "unspents", "utxos", "sendbtc",
        "assets", "transfers", "witnessinvoice", "blindinvoice", "rgbsend",
    ]

    /// Reads the launch configuration once, then runs a scripted session if
    /// one was requested. Scripted runs (`scripts/drive.py`) pass every field
    /// through the environment:
    ///
    ///     SIMCTL_CHILD_gatewayUrl=https://your-gateway.example \
    ///     SIMCTL_CHILD_bearerToken=utxg_… SIMCTL_CHILD_run=sync,balance \
    ///     xcrun simctl launch --console-pty booted org.utexo.UTEXOExample
    ///
    /// Keys: gatewayUrl, bearerToken, walletId, network, tipUrl, recipient,
    /// amount, assetId, provisionedMnemonic, autoConnect, run. `run` connects,
    /// then runs the named actions in order; see `actionNames`. The same keys
    /// also work as launch arguments (`-walletId example`) in an Xcode scheme.
    func start() async {
        guard !started else { return }
        started = true
        if let value = Self.launchValue("gatewayUrl") { gatewayURL = value }
        if let value = Self.launchValue("bearerToken") { bearerToken = value }
        if let value = Self.launchValue("walletId") { walletID = value }
        if let value = Self.launchValue("network") { network = Network(rawValue: value.lowercased()) ?? network }
        if let value = Self.launchValue("tipUrl") { tipURL = value }
        if let value = Self.launchValue("recipient") { recipient = value }
        if let value = Self.launchValue("amount") { amount = value }
        if let value = Self.launchValue("assetId") { assetID = value }
        line("Enter the gateway URL and a bearer token, then press Connect.")
        line("A token is minted by the operator: POST /v1/users with x-operator-token.")
        line("Connect generates a wallet on first run and reuses it afterwards.")
        if let script = Self.launchValue("run") {
            await runScript(script.split(separator: ",").map { $0.trimmed }.filter { !$0.isEmpty })
        } else if Self.launchValue("autoConnect") == "true" {
            await report("connect") { try await self.connect() }
        }
    }

    func connectTapped() {
        Task { await report("connect") { try await self.connect() } }
    }

    func runAction(_ name: String) {
        Task { await report(name) { try await self.perform(name) } }
    }

    // MARK: - Connect

    /// First run provisions a seed into the Keychain; later runs reuse it. The
    /// seed must exist *before* the wallet is created: `unlock()` loads it and
    /// fails with `wallet.key_access_failed` if it was never provisioned.
    private func connect() async throws {
        // A wallet's storage has one owner at a time, so the instance already
        // open (possibly for a different wallet ID) is destroyed first.
        if let previous = wallet {
            wallet = nil
            try await previous.destroy()
        }
        let walletID = try WalletID(self.walletID.trimmed)
        let network = self.network
        // Keychain items are keyed by wallet ID only, so the network goes into
        // the service name: the same ID on regtest and signet stays separate.
        let keychainService = "org.utexo.example.\(network.rawValue)"
        try await provisionSeed(
            KeychainSeedStore(service: keychainService, walletID: walletID), network: network
        )

        let token = bearerToken.trimmed
        guard !token.isEmpty else { throw ExampleError("paste a bearer token first") }
        // The provider is read for every request, so replacing the stored
        // credential takes effect without rebuilding the wallet.
        let credentials = try KeychainAPIKeyStore(service: keychainService, account: walletID.value)
        let apiKey = try WalletAPIKey(copyingUTF8: Array(token.utf8))
        defer { apiKey.close() }
        do {
            try await credentials.storeNew(apiKey: apiKey)
        } catch let failure as SDKError where failure.code == .invalidState {
            try await credentials.replace(apiKey: apiKey)
        }

        let gateway = try Self.url(gatewayURL, field: "gateway URL")
        let service = try WalletServiceConfiguration(
            baseURL: gateway,
            apiKeyProvider: credentials,
            // Loopback HTTP only; a real deployment is HTTPS.
            allowInsecureLocalDevelopment: gateway.scheme == "http",
            // The maximum, well above the 30s default. The first call against
            // a newly registered wallet also pays for the gateway building its
            // rgb-lib wallet and reaching the indexer. A longer timeout makes
            // the first-call `backend.unavailable` rarer but does not remove
            // it, so retry is still the contract.
            requestTimeout: 120,
            // Without it reads still work, but every new spend fails closed.
            chainContextProvider: HTTPChainTip(url: Self.url(tipURL, field: "chain tip URL"))
        )
        let storage = try WalletStorageConfiguration(
            directory: FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("UTEXOExample/\(network.rawValue)", isDirectory: true),
            keychainService: keychainService
        )
        let open = try await UTEXOWallet.create(
            configuration: WalletConfiguration(walletID: walletID, network: network),
            service: service,
            storage: storage
        )
        do {
            try await open.initialize() // starts the gateway session (idempotent)
            try await open.unlock()     // loads the seed and registers the watch-only xpubs
        } catch {
            try? await open.destroy()
            throw error
        }
        wallet = open
        line("connected as \(walletID.value): wallet registered and unlocked")
    }

    /// Provisioning is one-shot: the store refuses to overwrite an existing
    /// seed, and that refusal is how a later run discovers it already has one.
    /// Replacing a seed would silently orphan the funds held under the old one,
    /// so the example never forces it; `KeychainSeedStore.delete()` is the
    /// explicit destructive path.
    private func provisionSeed(_ store: KeychainSeedStore, network: Network) async throws {
        if let words = Self.launchValue("provisionedMnemonic") ?? Defaults.provisionedMnemonic {
            // drive.py's --restore-from also accepts the Kotlin example's
            // underscore-separated form.
            let phrase = words.replacingOccurrences(of: "_", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let mnemonic = try SecretMnemonic(copyingUTF8: Array(phrase.utf8))
            defer { mnemonic.close() }
            do {
                try await store.provisionNew(mnemonic: mnemonic)
            } catch let failure as SDKError where Self.isAlreadyProvisioned(failure) {
                line("seed already in the Keychain, reusing it")
                return
            }
            line("seed restored from the supplied mnemonic")
            return
        }
        // Nothing to restore from, so this is a new wallet.
        let keys = try generateKeys(network: network)
        defer { keys.close() }
        guard let mnemonic = keys.mnemonic else { throw ExampleError("generateKeys returned no mnemonic") }
        let seed = try deriveSeedFromMnemonic(mnemonic: mnemonic)
        defer { seed.close() }
        do {
            try await store.storeNew(seed: seed)
        } catch let failure as SDKError where Self.isAlreadyProvisioned(failure) {
            line("seed already in the Keychain, reusing it")
            return
        }
        line("new wallet generated and provisioned")
        // This is the user's ONLY backup. A real app shows it once behind a
        // confirmation and makes the user prove they recorded it; printing it
        // to a log view is acceptable for a signet demo and nowhere else.
        let words = try mnemonic.consume { String(decoding: $0, as: UTF8.self) }
        line("BACK THIS UP: \(words)")
    }

    /// Match the code and the operation, never the message: codes and details
    /// are the stable contract.
    private static func isAlreadyProvisioned(_ failure: SDKError) -> Bool {
        failure.code == .invalidState && failure.details["operation"] == "store seed"
    }

    // MARK: - Actions

    private func perform(_ name: String) async throws {
        guard let wallet else { throw ExampleError("press Connect first") }
        switch name {
        case "address": try await address(wallet)
        case "balance": try await balance(wallet)
        case "sync": try await sync(wallet)
        case "unspents": try await unspents(wallet)
        case "utxos": try await createUtxos(wallet)
        case "sendbtc": try await sendBtc(wallet)
        case "assets": try await assets(wallet)
        case "transfers": try await transfers(wallet)
        case "witnessinvoice": try await invoice(wallet, witness: true)
        case "blindinvoice": try await invoice(wallet, witness: false)
        case "rgbsend": try await rgbSend(wallet)
        default: throw ExampleError("unknown action \(name)")
        }
    }

    /// Each call allocates a fresh vanilla address. The SDK re-derives it from
    /// the local seed before returning it: the gateway holds the xpubs, so an
    /// address it hands back unchecked could be anyone's.
    private func address(_ wallet: UTEXOWallet) async throws {
        let address = try await wallet.getAddress()
        line("address: \(address.value)")
    }

    private func balance(_ wallet: UTEXOWallet) async throws {
        let btc = try await wallet.getBtcBalance()
        line("vanilla  settled=\(btc.vanilla.settled.value) spendable=\(btc.vanilla.spendable.value)")
        line("colored  settled=\(btc.colored.settled.value) spendable=\(btc.colored.spendable.value)")
    }

    /// One combined gateway call: Bitcoin wallet sync plus RGB refresh. An
    /// incoming RGB transfer only settles after the receiver refreshes.
    private func sync(_ wallet: UTEXOWallet) async throws {
        let result = try await wallet.syncWallet()
        line("synced at \(result.completedAt.rawValue) (tipHeight=\(result.tipHeight.map { "\($0)" } ?? "not reported"))")
    }

    private func unspents(_ wallet: UTEXOWallet) async throws {
        let unspents = try await wallet.listUnspents()
        line("\(unspents.count) unspent output(s)")
        for unspent in unspents {
            let utxo = unspent.utxo
            line(
                "  \(utxo.outpoint.txid.hex.prefix(12))…:\(utxo.outpoint.vout)  \(utxo.btcAmount.value) sat  "
                    + "colorable=\(utxo.colorable)  exists=\(utxo.exists.map { "\($0)" } ?? "unknown")  "
                    + "allocations=\(unspent.rgbAllocations.count)"
            )
        }
    }

    /// RGB allocations live on colored UTXOs, so a wallet needs some before it
    /// can receive to a blind invoice or send an asset. The gateway defaults to
    /// five 1,000-sat outputs.
    private func createUtxos(_ wallet: UTEXOWallet) async throws {
        let result = try await wallet.createUtxos(
            CreateUtxosRequest(feeRate: FeeRate(satsPerVByte: Defaults.feeRateSatsPerVByte))
        )
        line("created \(result.createdUtxoCount) colored UTXO(s) in \(result.txid.hex)")
    }

    /// A real app commits the request, idempotency key included, to its own
    /// database BEFORE this call, and retries with the same key after a crash
    /// or `operation.ambiguous`. The returned txid means accepted, not confirmed.
    private func sendBtc(_ wallet: UTEXOWallet) async throws {
        guard let sats = UInt64(amount.trimmed) else { throw ExampleError("amount must be a whole number of sats") }
        let request = try SendBtcRequest(
            address: BitcoinAddress(recipient.trimmed),
            amount: Satoshis(sats),
            feeRate: FeeRate(satsPerVByte: Defaults.feeRateSatsPerVByte)
        )
        line("sending \(request.amount.value) sat to \(request.address.value)")
        let txid = try await wallet.sendBtc(request)
        line("sent: txid \(txid.hex)")
    }

    private func assets(_ wallet: UTEXOWallet) async throws {
        let assets = try await wallet.listAssets()
        line("\(assets.nia.count + assets.cfa.count + assets.ifa.count + assets.uda.count + assets.bfa.count) asset(s)")
        func show(_ schema: String, _ id: AssetID, _ label: String, _ balance: AssetBalance) {
            line(
                "  \(schema) \(id.value)  \(label)  settled=\(balance.settled?.decimal ?? "-") "
                    + "spendable=\(balance.spendable?.decimal ?? "-") future=\(balance.future?.decimal ?? "-")"
            )
        }
        for asset in assets.nia { show("NIA", asset.assetID, asset.ticker, asset.balance) }
        for asset in assets.ifa { show("IFA", asset.assetID, asset.ticker, asset.balance) }
        for asset in assets.cfa { show("CFA", asset.assetID, asset.name, asset.balance) }
        for asset in assets.uda { show("UDA", asset.assetID, asset.ticker, asset.balance) }
        for asset in assets.bfa { show("BFA", asset.assetID, asset.ticker, asset.balance) }
    }

    private func transfers(_ wallet: UTEXOWallet) async throws {
        let filter = try assetID.trimmed.nonEmpty.map { try AssetID($0) }
        let transfers = try await wallet.listTransfers(assetID: filter)
        line("\(transfers.count) transfer(s)")
        for transfer in transfers {
            let amounts = transfer.assignments.map { $0.amount?.decimal ?? $0.type.rawValue }.joined(separator: ", ")
            line(
                "  #\(transfer.index) \(transfer.kind.rawValue) \(transfer.status.rawValue)  amounts=\(amounts)  "
                    + "asset=\(transfer.assetID?.value ?? "-")  txid=\(transfer.txid?.hex ?? "-")"
            )
        }
    }

    /// A witness invoice asks the sender to create the receiving output, so
    /// the receiver needs no colored UTXO; a blind invoice receives onto one of
    /// the receiver's own. Asset and amount are optional, and the SDK decodes
    /// the returned invoice locally to check the gateway encoded this request.
    private func invoice(_ wallet: UTEXOWallet, witness: Bool) async throws {
        let request = try OnchainReceiveRequest(
            amount: amount.trimmed.nonEmpty.map { try AssetAmount(parsing: $0) },
            assetID: assetID.trimmed.nonEmpty.map { try AssetID($0) },
            witness: witness
        )
        let received = try await wallet.onchainReceive(request)
        line("invoice: \(received.invoice.value)")
        line(
            "  recipientId=\(received.recipientID ?? "-") "
                + "batchTransferIdx=\(received.batchTransferIndex.map { "\($0)" } ?? "not reported")"
        )
    }

    /// The SDK decodes the invoice locally and the signer binds the prepared
    /// transaction to it; the gateway is never trusted for the recipient. A
    /// witness invoice needs the sats for the receiving output; rgb-lib
    /// identifies one by the `wvout:` in its recipient ID (`sb:wvout:…`).
    private func rgbSend(_ wallet: UTEXOWallet) async throws {
        let invoice = try RGBInvoice(recipient.trimmed)
        let decoded = try await wallet.decodeRGBInvoice(invoice)
        var witnessData: WitnessData?
        if decoded.recipientID.contains("wvout:") {
            witnessData = try WitnessData(amountSat: Satoshis(Defaults.witnessSats))
        }
        let request = try OnchainSendRequest(
            invoice: invoice,
            amount: AssetAmount(parsing: amount.trimmed),
            assetID: assetID.trimmed.nonEmpty.map { try AssetID($0) },
            witnessData: witnessData,
            feeRate: FeeRate(satsPerVByte: Defaults.feeRateSatsPerVByte)
        )
        let asset = request.assetID?.value ?? decoded.assetID?.value ?? "-"
        line("sending \(request.amount.decimal) of \(asset) to \(decoded.recipientID)")
        let sent = try await wallet.onchainSend(request)
        line("sent: txid \(sent.txid.hex) batchTransferIdx=\(sent.batchTransferIndex.map { "\($0)" } ?? "not reported")")
    }

    // MARK: - Plumbing

    /// Connects, then runs each named action in order; a failure does not stop the rest.
    private func runScript(_ names: [String]) async {
        if await report("connect", { try await self.connect() }) {
            for name in names {
                await report(name) { try await self.perform(name) }
            }
        }
        line("script done")
    }

    @discardableResult
    private func report(_ label: String, _ body: () async throws -> Void) async -> Bool {
        line("· \(label)…")
        do {
            try await body()
            return true
        } catch let failure as SDKError {
            // Messages, codes and details are documented as redacted and safe
            // to log. Always record the code and correlationID: the code is the
            // stable contract (never branch on the message), and the
            // correlationID is what the operator greps for.
            line("✗ \(label) failed: \(failure.code.rawValue): \(failure.message)")
            if let correlationID = failure.correlationID { line("   correlationId=\(correlationID)") }
            if !failure.details.isEmpty { line("   details=\(failure.details)") }
            return false
        } catch {
            line("✗ \(label) failed: \(error)")
            return false
        }
    }

    /// Appends to the on-screen log and writes to stdout, which a scripted run
    /// (`xcrun simctl launch --console-pty`) reads. Deliberately not the
    /// unified system log, which would persist the mnemonic line.
    private func line(_ text: String) {
        log += text + "\n"
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private static func launchValue(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key] ?? UserDefaults.standard.string(forKey: key)
        return value?.trimmed.nonEmpty
    }

    private static func url(_ text: String, field: String) throws -> URL {
        guard let url = URL(string: text.trimmed) else { throw ExampleError("\(field) is not a URL") }
        return url
    }
}

/// The signer bounds every prepared transaction against this tip, so it must
/// come from a source the app trusts *independently of the gateway*: here an
/// HTTP `/blocks/tip/height` for the selected network. Never copy
/// a height out of a PSBT, and never restamp an old observation: the SDK
/// rejects a tip older than 300 seconds.
struct HTTPChainTip: WalletChainContextProvider {
    let url: URL

    func loadChainContext(network: Network) async throws -> WalletChainContext {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self).trimmed
        guard (response as? HTTPURLResponse)?.statusCode == 200, let height = UInt32(text) else {
            throw ExampleError("the chain tip source returned no block height")
        }
        let observedAt = UnixSeconds(rawValue: UInt64(Date().timeIntervalSince1970))
        return try WalletChainContext(network: network, tipHeight: height, observedAt: observedAt)
    }
}

enum Defaults {
    /// Empty: enter the gateway URL UTEXO provisioned for you, or set the
    /// `gatewayUrl` launch argument. For a gateway on your own machine use
    /// `http://127.0.0.1:<port>`. The other defaults suit UTEXO's signet
    /// gateway, which runs on Bitcoin's public signet.
    static let gatewayURL = ""
    static let gatewayURLHint = "gateway base URL, e.g. https://your-gateway.example"
    static let network = Network.signet
    static let walletID = "example"

    /// An HTTP `/blocks/tip/height` for the chain the gateway runs on; it must
    /// not be the gateway. UTEXO's signet gateway runs on Bitcoin's public
    /// signet. A tip from another chain is far off the gateway's height, and the
    /// signer then refuses every transaction. On regtest, `scripts/tip.mjs`
    /// serves one.
    static let chainTipURL = "https://mempool.space/signet/api/blocks/tip/height"

    /// Explicit, because a gateway whose indexer has no fee data cannot estimate one.
    static let feeRateSatsPerVByte = 2

    /// Sats a sender puts on the output it creates for a witness invoice.
    static let witnessSats: UInt64 = 1_000

    /// Set to a 12-word mnemonic to restore an existing wallet on first run.
    /// Left nil, Connect generates a fresh wallet and prints the mnemonic once.
    /// A real app never hardcodes this; it is here so a scripted demo can
    /// reach a funded wallet.
    static let provisionedMnemonic: String? = nil
}

struct ExampleError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
