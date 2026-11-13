# `example-app`: a reference integration

A single-screen iOS app that exercises the UTEXO Swift SDK against a lightsdk
gateway (`rln-gateway`) deployment. It exists to be read: every SDK call lives in one
file, [`ExampleWallet.swift`](UTEXOExample/ExampleWallet.swift), with no
architecture in the way. [`UTEXOExampleApp.swift`](UTEXOExample/UTEXOExampleApp.swift)
only lays out the screen.

It is not a shipping wallet. It prints a mnemonic to the screen and allows
cleartext HTTP to the Mac's loopback address. Both are fine for signet and
neither is acceptable in production.

## Run it

You need macOS with Xcode 27.0, the toolchain the bundled `RGBSDK.xcframework`
is built with. Open [`UTEXOExample.xcodeproj`](UTEXOExample.xcodeproj) and run
the `UTEXOExample` scheme on a simulator, or build and install from the command
line onto a booted simulator:

```sh
xcrun simctl boot "iPhone 16"        # any available iPhone simulator
example-app/scripts/install.sh
```

The project links the `RGBSDK` product of this repository's root package, so
it builds against the committed binary facade. For a physical device, set your
development team on the target first.

Launch the app, paste the gateway URL UTEXO gave you and a bearer token, and
press **Connect**. The other defaults suit UTEXO's signet gateway, which runs on
Bitcoin's public signet: `Network.signet`, with the trusted chain tip read from
`https://mempool.space/signet/api/blocks/tip/height`.

A token is minted once per user by the operator:

```sh
curl -X POST https://your-gateway.example/v1/users \
     -H "x-operator-token: $GATEWAY_OPERATOR_TOKEN"
# 201 {"userId":"u_…","token":"utxg_…","createdAt":…}
```

The simulator shares the Mac's network, so a gateway on your own machine is
`http://127.0.0.1:<port>`. Against the lightsdk-gateway regtest stack (`regtest/`
in the gateway repository), also select `regtest`, start
[`scripts/tip.mjs`](scripts/tip.mjs), and use
`http://127.0.0.1:3003/blocks/tip/height` as the tip URL.
[PAYMENT_TESTING.md](PAYMENT_TESTING.md) walks through a full local run.

For scripted runs, every field can be set at launch, and `run` connects and
then runs the named actions in order. `simctl` passes `SIMCTL_CHILD_<name>`
environment variables to the app as `<name>`, and the app writes each result
line to stdout:

```sh
SIMCTL_CHILD_gatewayUrl=https://your-gateway.example \
SIMCTL_CHILD_bearerToken=utxg_… \
SIMCTL_CHILD_walletId=example \
SIMCTL_CHILD_recipient=tb1p… SIMCTL_CHILD_amount=50000 \
SIMCTL_CHILD_run=sync,balance,sendbtc \
xcrun simctl launch --console-pty --terminate-running-process booted org.utexo.UTEXOExample
```

The keys are `gatewayUrl`, `bearerToken`, `walletId`, `network`, `tipUrl`,
`recipient`, `amount`, `assetId`, `provisionedMnemonic` (restore instead of
generate), `autoConnect` and `run`. They also work as launch arguments in an
Xcode scheme, such as `-walletId example`. [`scripts/drive.py`](scripts/drive.py)
wraps all of this; [PAYMENT_TESTING.md](PAYMENT_TESTING.md) uses it throughout.

## What the actions show

| Action           | What it demonstrates                                                         |
| ---------------- | ---------------------------------------------------------------------------- |
| **Connect**      | first-run seed generation (or restore) → `create` → `initialize` → `unlock`  |
| `address`        | `getAddress()`: a fresh vanilla address, re-derived locally before use       |
| `balance`        | `getBtcBalance()`, split vanilla / colored, settled / spendable              |
| `sync`           | `syncWallet()`: Bitcoin sync plus RGB refresh; settles incoming RGB          |
| `unspents`       | `listUnspents()`, with `exists` reported by the gateway or unknown           |
| `utxos`          | `createUtxos()`: colored UTXOs to hold RGB allocations                       |
| `sendbtc`        | `sendBtc()` to *recipient* for *amount* sats, signed on the device           |
| `assets`         | `listAssets()` with settled / spendable / future balances                    |
| `transfers`      | `listTransfers()` for every asset, or only for *asset ID*                    |
| `witnessinvoice` | `onchainReceive(witness: true)`: the sender creates the receiving output     |
| `blindinvoice`   | `onchainReceive(witness: false)`: receives onto one of this wallet's colored UTXOs |
| `rgbsend`        | `onchainSend()` of *amount* to the RGB invoice in *recipient*                |

## Three things the example is really here to teach

**Provisioning is one-shot.** The seed must be in the Keychain *before* the
wallet is created; `unlock()` fails with `wallet.key_access_failed` if it was
never provisioned. The store also refuses to overwrite an existing seed, and
that refusal is how a later run discovers it already has one. Replacing a seed
would silently orphan the funds held under the old one. Keychain items outlive
an uninstall, so a reinstalled app finds the same seed for the same wallet ID;
use a new wallet ID, or `xcrun simctl keychain booted reset`, to start over.

**The first call against a new wallet may fail, and that is not an outage.**
Immediately after `initialize()`/`unlock()` on a freshly registered wallet, the
gateway is still building its rgb-lib wallet and reaching the indexer. The
first call can fail with a retryable `backend.unavailable`, and the next
identical call succeeds; the Android example sees this regularly. The example
uses the longest request timeout the SDK allows, 120 seconds, which makes it
rarer without removing it. Treat `backend.unavailable` as what it says it is,
retryable, and retry it.

**Branch on `code`, never on the message.** `SDKErrorCode` is the stable
contract. Messages, codes and `details` are all documented as redacted and safe
to log, so the example logs the code, the `correlationID` an operator can grep
for, and `details`, and nothing else.

## Before testing a payment

**Spending needs a trusted chain tip.** `chainContextProvider` must read the tip
height from an indexer for the chain the gateway runs on, never from the gateway.
UTEXO's signet gateway runs on Bitcoin's public signet. A tip from another chain
is far off the gateway's height, and the signer rejects every spend.

**RGB payments take three turns.** The receiver syncs to fetch, validate and
ACK the consignment. The sender then syncs to see the ACK and broadcast. After a
confirmation, the receiver's next sync settles the transfer.

**RGB needs colored UTXOs.** A sender funds the fee and any witness output from
colored UTXOs, not its vanilla balance (`rgbsend` adds 1,000 sats for a `wvout:`
recipient). A blind invoice receives onto a free colored UTXO. Run `utxos` first.

[PAYMENT_TESTING.md](PAYMENT_TESTING.md) walks through complete BTC and RGB
payment runs, locally on regtest and against a deployed gateway.
