import RGBSDK
import SwiftUI

@main
struct UTEXOExampleApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// One screen, no architecture: the fields every action reads, a button per
/// action, and the log. All SDK calls live in `ExampleWallet`.
struct ContentView: View {
    @StateObject private var model = ExampleWallet()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                field(Defaults.gatewayURLHint, text: $model.gatewayURL)
                SecureField("bearer token (utxg_…)", text: $model.bearerToken)
                    .textFieldStyle(.roundedBorder)
                field("wallet ID", text: $model.walletID)
                Picker("network", selection: $model.network) {
                    ForEach(ExampleWallet.networks, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                field("trusted chain tip URL", text: $model.tipURL)
                field("recipient: BTC address or RGB invoice", text: $model.recipient)
                field("amount: sats for BTC, asset units for RGB", text: $model.amount)
                field("asset ID (optional)", text: $model.assetID)
                ScrollView(.horizontal) {
                    HStack {
                        Button("Connect") { model.connectTapped() }
                        ForEach(ExampleWallet.actionNames, id: \.self) { name in
                            Button(name) { model.runAction(name) }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Text(model.log)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .task { await model.start() }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
    }
}
